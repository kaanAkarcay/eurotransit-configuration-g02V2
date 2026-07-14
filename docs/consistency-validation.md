# Consistency validation — Inventory & Payments

Validates the consistency guarantees of the two services on the money path
against contract §3.1 (Inventory consistency) and §3.2 (idempotency levels 1–3).
Every claim below is backed by a test that fails if the guarantee regresses.

Scope: Inventory and Payments. The Orders service owns the saga, the outbox and
its own deduplication; those are referenced here only where they affect these two
services.

---

## 1. Inventory — "never oversell" (PACELC: PC/EC)

**Guarantee.** The seat counter is strongly consistent. A reservation is a single
atomic conditional UPDATE against a single-primary PostgreSQL (CloudNativePG),
never a read-then-write:

```sql
UPDATE seats SET available = available - :quantity
WHERE train_id = :trainId AND seat_class = :seatClass
  AND :quantity > 0 AND available >= :quantity
```

The predicate and the decrement are evaluated in one statement, so concurrent
requests serialise on the row lock and the loser sees the already-decremented
value. 0 rows affected → 409 `INSUFFICIENT_SEATS`.

**PACELC.** Under a partition (P) we choose **C**: writes go to the primary and
are refused rather than risk overselling. In normal operation (E) we again
choose **C**: always hit the primary and accept the extra latency, because
showing wrong availability costs more than a few milliseconds. This is PC/EC.

**Second net.** `seats.available` carries `CHECK (available >= 0)`. If the
conditional UPDATE were ever wrong, the write would fail loudly rather than
silently oversell.

**Evidence** (`InventoryReserveTest`):

| Test | What it pins down |
|---|---|
| `10 concurrent reserves on 5 seats never oversell` | Exactly 5×200 and 5×409; `available` ends at 0; 5 reservation rows. |
| `50 concurrent reserves of mixed quantities on 20 seats never oversell` | Under 50-way concurrency with quantities 1–3, `available` never goes negative and reservation rows reconcile *exactly* with the seats taken off the counter. |
| `reserve with a non-positive quantity never increases availability` | The `:quantity > 0` guard stops a negative quantity inverting the decrement. |

Both concurrency tests drive real `POST /reserve` calls over HTTP against the
running server, so the WebFlux stack, the R2DBC pool and the transaction
boundaries are all exercised — not an in-process call to the service bean.

---

## 2. Idempotency level 2 — internal synchronous calls (contract §3.2)

Orders wraps `POST /reserve` and `POST /authorize` in a bounded retry with
backoff and jitter. A retry is indistinguishable from a duplicate when the
original response was lost but the write committed. Both services now dedup on
the `idempotency_key` Orders sends, which is the `order_id`.

### Inventory

The claim on `processed_requests` is taken **before** the seat decrement. This
ordering is what makes it race-free rather than merely usually-right: the loser's
`INSERT ... ON CONFLICT DO NOTHING` blocks on the winner's row lock until that
transaction commits or aborts, so a 0 means the winner is *already committed* and
its `reservation_id` is readable. Claim, decrement and reservation row commit in
one transaction.

An insufficient-seats failure rolls the claim back with the rest of the
transaction. This is deliberate: a 409 must **not** be memoised, because
compensation can free seats and a later retry has to re-evaluate availability.

### Payments

`authorize()` is deliberately **not** transactional as a whole — a transaction
must never be held open across the remote gateway call. Instead:

1. A recorded decision for the key is replayed before the gateway is touched.
2. The gateway is called.
3. Only then does `DecisionRecorder` open a transaction around the two writes
   that must agree: the `transactions` row and the idempotency claim. If a
   concurrent duplicate won the claim, ours is discarded and theirs replayed.

Net effect: **exactly one `transactions` row per order**, however the retry
overlaps.

**`circuit_breaker_open` is deliberately not memoised.** It means the gateway
never returned a decision — the breaker was open, or the call failed or timed
out. There is nothing to deduplicate, and the outcome of a timed-out call is
*unknown*. Memoising it would pin a transient outage onto the order permanently:
a later retry would replay the decline instead of ever reaching the recovered
gateway. The `transactions` row is still written so declines stay visible on
dashboards (contract §2.4), but no claim is taken.

**Evidence:**

| Test | What it pins down |
|---|---|
| `InventoryReserveTest` › `duplicate reserve … replays the reservation` | The retry returns the *original* `reservation_id`; seats decremented once. |
| `InventoryReserveTest` › `10 concurrent reserves with the same idempotency key reserve exactly once` | The claim-first ordering holds under a concurrent retry: one reservation row, one identical `reservation_id` for all 10 callers. |
| `InventoryReserveTest` › `an insufficient-seats failure is not memoised…` | A 409 leaves no claim behind; a retry after seats free up succeeds. |
| `PaymentsIdempotencyTest` › `a retried authorize replays the original decision without calling the gateway again` | Gateway called exactly **once**; one `transactions` row; same `transaction_id`. |
| `PaymentsIdempotencyTest` › `10 concurrent duplicate authorizes record exactly one transaction` | Exactly one `transactions` row and one `transaction_id` handed to every caller. |
| `PaymentsIdempotencyTest` › `a circuit_breaker_open decline is not memoised…` | An undecided call takes no claim; the retry reaches the recovered gateway. |

---

## 3. Idempotency level 3 — Kafka consumer dedup (contract §3.2)

Kafka is at-least-once, so `eurotransit.order-failed` can be delivered twice.
Inventory's consumer now inserts `event_id` into `processed_events` **in the same
transaction** as the compensation it guards, so a redelivery arriving before the
first one commits cannot slip past.

**An honest note on what this actually buys.** Compensation was *already*
idempotent without it. `markReleased()` is a conditional
`UPDATE … WHERE status = 'RESERVED'` returning 0 on redelivery, and a concurrent
duplicate blocks on the row lock and then re-evaluates the predicate under READ
COMMITTED. The RESERVED→RELEASED transition alone prevents a double release.
`processed_events` is therefore **contract compliance plus defence in depth** —
it decouples dedup from this handler *happening* to be naturally idempotent, and
would still hold if the handler grew a side effect that isn't — not a fix for a
live double-release bug.

This was verified, not assumed: with the `processed_events` gate disabled, the
redelivery test still passes (the status guard covers it) while
`a replayed event_id is skipped before the handler runs` fails. That test exists
precisely to isolate the event_id gate from the status guard, so a regression in
either layer is caught.

**Evidence** (`OrderFailedConsumerDedupTest` — drives the real `@KafkaListener`
against a real broker; the previous suite disabled the listener entirely, so the
consumer had never been exercised):

| Test | What it pins down |
|---|---|
| `a redelivered order-failed event releases the seats only once` | Same `event_id` twice → seats released once, one `processed_events` row. |
| `a replayed event_id is skipped before the handler runs` | Isolates the event_id gate: a replayed `event_id` carrying a *different, still-RESERVED* reservation is skipped, which only a working gate can do. |
| `two distinct event_ids for the same reservation still release the seats only once` | Isolates the status guard: distinct `event_id`s sail past `processed_events`, and RESERVED→RELEASED stops the second release. |
| `an order-failed event without a reservation_id is consumed and changes nothing` | Stage 1's no-seats path is a clean no-op. |

**Level 3 is complete for Inventory only.** Orders' four stage consumers do hold
a `processed_events` table and the dedup code, but it does not work — see §4. The
DoD's level-3 box therefore stays unticked, since it requires dedup in *every*
Kafka consumer.

---

## 4. Residual risks and open gaps

**Compensation does not fire end-to-end today — Orders-side, blocking.** Inventory's
consumer is correct and tested, but no contract-shaped event ever reaches it:

- Orders' stage consumers write outbox rows with **bare topic names**
  (`"order-failed"`, `"inventory-reserved"`, …), missing the `eurotransit.`
  prefix, and `OutboxProcessor` publishes `entry.topic` verbatim. Inventory
  listens on `eurotransit.order-failed`.
- Orders' `order-failed` payload carries **no `reservation_id` and no
  `event_id`**. `compensate()` returns early on a null `reservation_id`, so the
  release never happens and the dedup key is absent.

Until both are fixed, reserved seats are never released on payment failure. This
is why the DoD's "Compensation path" box stays unticked.

**Orders' level-3 dedup does not work — blocking, and why the level-3 box stays
unticked.** All four stage consumers call
`processedEventRepo.save(ProcessedEvent(eventId))`, but that write never lands.
`ProcessedEvent` has a **non-null `String` `@Id`**, so Spring Data R2DBC treats
the entity as "not new" and issues an **UPDATE**, which matches 0 rows on an
empty table and — verified empirically on this stack, against a real Postgres via
Testcontainers — **completes silently**: no exception, no row.

`processed_events` in `orders-db` therefore never receives a row, `existsById`
is always false, and **every stage reprocesses every redelivered event in full**.
This is the "non-idempotent handler" failure class the capstone names. The same
defect applies to Orders' `Order` and `ProcessedRequest` entities (level 1), so
orders are never persisted either — tracked in `ai-mistake-log.md`.

Inventory and Payments are unaffected: they never `save()` a String-keyed entity,
using `INSERT ... ON CONFLICT DO NOTHING` with an affected-row count instead.

**OPEN DECISION — a replayed `/reserve` for a compensated order reports a
reservation that no longer exists.** Inventory's `processed_requests` maps
`order_id → reservation_id` permanently. If an order is reserved, then fails
payment, then is compensated (seats returned, reservation `RELEASED`), a
subsequent `/reserve` with the *same* `order_id` replays the stored
`reservation_id` with `status: "RESERVED"` — even though that reservation is
released and the seats are back on sale. Inventory would be telling Orders
something untrue.

**Not reachable in the saga as designed**, which is why it is being left as-is
for now: Stage 1 runs exactly once per order (deduplicated on `event_id`), and
Orders' bounded retries all happen *inside* that single execution, before any
compensation can exist. It becomes reachable only if Stage 1 is ever re-entered
for an already-compensated order — a manual replay, a redelivery with a fresh
`event_id`, or a future saga change that retries a failed order.

Contract §1.4 does not define this case: it says only *"if already reserved,
returns the existing reservation_id"*, and is silent on "already released". The
options, none of which should be chosen unilaterally:

- **(a) Leave as-is + document** — current choice. Zero code risk, but a latent
  trap for whoever next touches the saga's retry policy.
- **(b) Check status on replay** — if the stored reservation is `RELEASED`, treat
  the request as new and reserve again. Restores truthfulness, but means an
  `idempotency_key` can legitimately yield two different `reservation_id`s over
  its lifetime, which weakens what "idempotent" means here.
- **(c) Amend the contract** to define the released-replay outcome explicitly
  (e.g. a distinct status, or an explicit statement that re-reserving is
  correct).

Owner: Data & Consistency. Needs a decision before the saga's retry/replay
policy changes, or before chaos experiments start replaying events by hand.

**Payments writes after it charges.** `authorize()` calls the gateway before it
persists anything, so a pod death between the charge and the write leaves the
money taken with no local row. Orders' retry then re-calls the gateway, where the
gateway's `Idempotency-Key: order_id` to Stripe returns the *same* PaymentIntent
rather than charging again — so the ledger self-heals on retry. It does **not**
self-heal if the retry budget is exhausted first. Closing this fully requires
claiming the key before the charge, plus a reaper for abandoned claims; that is a
larger change than §3.2 Level 2 asks for and needs a design decision.

**Orders' own dedup has a TOCTOU race.** Orders' `processed_requests` (level 1)
and `processed_events` (level 3) both use check-then-`save()` inside a
transaction. Under READ COMMITTED two concurrent identical requests can both pass
the check, and the only backstop is an uncaught primary-key violation. Inventory
and Payments use `INSERT … ON CONFLICT DO NOTHING` and report the affected-row
count instead, which is race-free. Recommend Orders adopt the same pattern.

**Not yet demonstrated under chaos.** The invariants above are proven under
concurrent load in the test suite, not yet under pod kills or a Kafka partition
(DoD Pillar B's last box, chaos experiments 2 and 4).

---

## How to reproduce

The tests live in the **application repo** (`eurotransit-application-g02`), not
here — run these from its root. Docker must be running: Testcontainers starts
PostgreSQL, and the consumer test additionally starts an embedded Kafka broker.

```bash
cd backend/inventory && ./gradlew test
cd backend/payments  && ./gradlew test
```

Test counts are deliberately not quoted here, since they drift. What must hold is
the set of named tests in the tables above: if any of them disappears, the
guarantee it backs is no longer validated.
