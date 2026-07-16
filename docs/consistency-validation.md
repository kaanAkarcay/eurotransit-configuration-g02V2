# Consistency & idempotency validation — the money path

Documents and validates the consistency model (contract §3.1) and the three-level
idempotency scheme (contract §3.2) across the money path. Every claim below is
backed by a named test that fails if the guarantee regresses; claims that are not
backed by a test say so.

Scope: Orders, Inventory and Payments — the three services that hold state on the
money path. Catalog appears in §1 because what sits *outside* the consistency
boundary is what gives the boundary its meaning. Notifications appears in §3.3:
it owns no database, but it does produce an externally visible, non-idempotent
side effect — and having no state is precisely why nothing stops it repeating.

---

## 1. The consistency model (CAP / PACELC)

### 1.1 What is *not* strongly consistent, and why that is the point

The system as a whole is **eventually consistent**. The money path is a saga, not
a distributed transaction: an order moves PENDING → RESERVED → CONFIRMED across
four Kafka-driven stages, and the client polls `GET /api/v1/orders/{id}` until it
converges. There is no global ACID boundary and none is wanted — it would mean
holding a lock across three services and an external payment gateway for the
duration of a card authorization.

Strong consistency is therefore **deliberately confined to a single row**:
`seats.available` in `inventory-db`. That is the only place in EuroTransit where
correctness and availability genuinely conflict, because it is the only resource
two customers can contend for at the same instant. Everything else — order
status, transaction records, notifications — converges, and nothing breaks if it
converges a second late.

Stating the boundary matters more than stating the choice: "we chose PC/EC" reads
as if it were the only option. "We chose PC/EC **for one row**, and left the
catalogue that displays it outside the boundary entirely, because only that row
has the conflict" is the actual design.

### 1.2 The contended resource: Inventory (PACELC: PC/EC)

A reservation is a single atomic conditional UPDATE against a single-primary
PostgreSQL (CloudNativePG), never a read-then-write:

```sql
UPDATE seats SET available = available - :quantity
WHERE train_id = :trainId AND seat_class = :seatClass
  AND :quantity > 0 AND available >= :quantity
```

The predicate and the decrement are evaluated in one statement, so concurrent
requests serialise on the row lock and the loser sees the already-decremented
value. 0 rows affected → 409 `INSUFFICIENT_SEATS`.

**Under a partition (P) we choose C — and here is what that costs, concretely.**
Seats live in a single-primary cluster. If that primary is unreachable — network
partition, node failure, or a failover in progress — reservations are **not**
served from a replica and are **not** queued for later. The write fails,
Inventory answers 5xx or times out, Orders' `inventory-client` circuit breaker
records the failure, Stage 1 publishes `order-failed`, and the order ends FAILED
with nothing reserved.

So the thing sacrificed under partition is **checkout availability**: while the
primary is unreachable, customers cannot buy. What is protected is the invariant:
we never sell a seat we cannot prove we still had. A customer who cannot buy for
30 seconds retries. A customer sold a seat that does not exist needs a refund, an
apology, and a seat on another train.

**Else (E) we choose C.** There is no read replica for the counter: every
reservation reads and writes the primary and pays the round trip, even with no
partition in sight. We accept that latency because a stale read here is not a
display glitch — it is an oversell.

**Second net.** `seats.available` carries `CHECK (available >= 0)`. If the
conditional UPDATE were ever wrong, the write would fail loudly rather than
silently oversell.

### 1.3 What sits outside the boundary: Catalog's display-only availability

Catalog owns its own `catalog-db` with its own `available` column. That column is
a **deliberately stale, display-only projection outside the authoritative
consistency boundary**. Inventory remains the sole authority for reservable seats.

It is worth being blunt about how far the staleness goes: Catalog has no Kafka
dependency, no write path, and only read methods on its repositories. Its
`available` comes from `data.sql` at startup and **never changes** — not when
seats are reserved, not when they are released. It is a poster, not a ledger.

**This is not a CAP/PACELC choice, and calling it one would be a category error.**
CAP and PACELC describe how a replicated datum behaves *under a partition* (P), or
what it trades between latency and consistency *otherwise* (E). Catalog's figure
does neither: it is wrong with zero partitions, a perfect network and no latency
trade-off anywhere, because nothing ever tries to reconcile it. There is no
replication protocol here to choose A over C. As it happens, Catalog with respect
to its *own* data is PC/EC like everything else — a single primary it reads
through and cannot serve without.

So the distinction is not "Inventory chose C, Catalog chose A". It is **what is
inside the consistency boundary and what is outside it**, and that boundary holds
because nothing trusts what is outside it. The money path never reads Catalog's
number: Inventory's conditional UPDATE is the only authority on whether a seat
exists. A customer who sees "42 available" and gets a 409 has read a stale poster
and retries. A customer who receives a `reservation_id` has a seat, whatever the
poster said.

Showing a wrong number costs a retry. Selling the same seat twice costs a refund
and a stranded passenger. That asymmetry is why one of the two is guarded by a
single-primary conditional UPDATE and the other is not guarded at all.

### 1.4 Evidence (`InventoryReserveTest`)

| Test | What it pins down |
|---|---|
| `10 concurrent reserves on 5 seats never oversell` | Exactly 5×200 and 5×409; `available` ends at 0; 5 reservation rows. |
| `50 concurrent reserves of mixed quantities on 20 seats never oversell` | Under 50-way concurrency with quantities 1–3, `available` never goes negative and reservation rows reconcile *exactly* with the seats taken off the counter. |
| `reserve with a non-positive quantity never increases availability` | The `:quantity > 0` guard stops a negative quantity inverting the decrement. |

Both concurrency tests drive real `POST /reserve` calls over HTTP against the
running server, so the WebFlux stack, the R2DBC pool and the transaction
boundaries are all exercised — not an in-process call to the service bean.

The PC half of PC/EC is **not** covered by these tests: refusing writes under a
real partition is chaos experiment 5's job (DoD Pillar B, last box), not the unit
suite's. See §4.

---

## 2. Idempotency levels 1 and 2 — synchronous requests (contract §3.2)

Levels 1 and 2 are the same pattern one hop apart. Level 1 protects Orders from a
user clicking "Buy" twice; level 2 protects Inventory and Payments from Orders'
own retries, where a retry is indistinguishable from a duplicate when the original
response was lost but the write committed.

All three services use the same race-free primitive: `INSERT ... ON CONFLICT DO
NOTHING`, deciding on the **affected-row count** rather than on a prior read. A
check-then-write would let two concurrent copies of the same request both pass the
check under READ COMMITTED, leaving an uncaught primary-key violation as the only
backstop.

### 2.1 Orders — level 1, keyed on the client's `idempotency_key`

`POST /api/v1/orders` claims the key in `processed_requests` **before** it writes
the order. A 0 means someone else already claimed it, and the existing order is
read back and returned (contract §1.2). The claim, the order row and the
`order-placed` outbox row commit in one transaction, so a double click can never
produce two orders or two `order-placed` events.

This depends on a persistence detail worth naming, because it was wrong once and
silently: Orders writes the order through an explicit `insertNew` query rather
than `save()`. Spring Data R2DBC treats a non-null `String` `@Id` as "not new" and
issues an UPDATE, which matches 0 rows on an empty table and completes without an
exception — the order is simply never persisted. That failure mode is recorded in
`ai-mistake-log.md`; the first test below is what stops it coming back.

### 2.2 Inventory — level 2, keyed on `order_id`

The claim on `processed_requests` is taken **before** the seat decrement. This
ordering is what makes it race-free rather than merely usually-right: the loser's
`INSERT ... ON CONFLICT DO NOTHING` blocks on the winner's row lock until that
transaction commits or aborts, so a 0 means the winner is *already committed* and
its `reservation_id` is readable. Claim, decrement and reservation row commit in
one transaction.

An insufficient-seats failure rolls the claim back with the rest of the
transaction. This is deliberate: a 409 must **not** be memoised, because
compensation can free seats and a later retry has to re-evaluate availability.

### 2.3 Payments — level 2, keyed on `order_id`

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

### 2.4 Evidence

| Test | What it pins down |
|---|---|
| `OrdersRepositoryPostgresTest` › `insertNew inserts a String keyed order and rejects duplicate ids` | The order is really written, and a duplicate `order_id` is rejected by the primary key rather than silently swallowed by an UPDATE. |
| `OrdersRepositoryPostgresTest` › `processed request insertIfAbsent returns one insert and one duplicate` | The claim reports 1 on first use and 0 on replay: the affected-row count decides, not a prior read. |
| `OrdersRepositoryPostgresTest` › `concurrent processed request inserts allow exactly one winner` | Two concurrent identical requests against a real Postgres: exactly one claim wins. This is the level-1 race, closed. |
| `SagaIntegrationTest` › `create order successfully saves to database and publishes to outbox` | The order row and the `order-placed` outbox row land together, in one transaction. |
| `InventoryReserveTest` › `duplicate reserve … replays the reservation` | The retry returns the *original* `reservation_id`; seats decremented once. |
| `InventoryReserveTest` › `10 concurrent reserves with the same idempotency key reserve exactly once` | The claim-first ordering holds under a concurrent retry: one reservation row, one identical `reservation_id` for all 10 callers. |
| `InventoryReserveTest` › `an insufficient-seats failure is not memoised…` | A 409 leaves no claim behind; a retry after seats free up succeeds. |
| `PaymentsIdempotencyTest` › `a retried authorize replays the original decision without calling the gateway again` | Gateway called exactly **once**; one `transactions` row; same `transaction_id`. |
| `PaymentsIdempotencyTest` › `10 concurrent duplicate authorizes record exactly one transaction` | Exactly one `transactions` row and one `transaction_id` handed to every caller. |
| `PaymentsIdempotencyTest` › `a circuit_breaker_open decline is not memoised…` | An undecided call takes no claim; the retry reaches the recovered gateway. |

---

## 3. Idempotency level 3 — Kafka consumer dedup (contract §3.2)

Kafka is at-least-once, so every event on the money path can be delivered twice.
Level 3 covers the **state-changing consumers on the money path**: Orders' four
stage consumers, which consume the events Orders itself publishes, and
Inventory's `order-failed` consumer, which performs compensation.

Each of those claims the `event_id` in its own `processed_events` table **in the
same transaction** as the business work it guards, so a redelivery arriving before
the first one commits cannot slip past. Both use the same
`INSERT ... ON CONFLICT DO NOTHING` primitive as §2.

It does **not** cover every Kafka consumer in the system. Notifications consumes
two of these topics and has no deduplication at all — see §3.3, which states what
that costs and why the architecture chose it.

### 3.1 Orders — the four stage consumers

Each stage claims `event_id`, does its business write (e.g. marking the order
RESERVED) and inserts the next event into `outbox` — all in one transaction. If
any part fails, the claim rolls back with it and the redelivery reprocesses the
event properly, rather than finding a claim from a run that never completed and
skipping the work.

The outgoing `event_id` of each stage is **deterministic** (`evt-<order_id>-stageN`)
and `outbox.event_id` is `UNIQUE`. That pairing is what makes a re-executed stage
safe: a rolled-back stage leaves no row, and a committed one cannot be duplicated.

### 3.2 Inventory — the compensation consumer

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

### 3.3 Notifications — deliberately at-least-once, and what that costs

`NotificationConsumer` holds two `@KafkaListener`s, on `eurotransit.order-confirmed`
and `eurotransit.order-failed`. Both send a real email through `JavaMailSender`.
Neither stores or checks `event_id`, and Notifications has no database in which to
store one. **A Kafka redelivery therefore sends the same email twice.**

This is the architecture's decision, not an oversight:

> Notifications needs no durable dedup, so it doesn't get a CNPG cluster.
> — `architecture-design.md` §2

Contract §3.2 scopes level 3 the same way: it enumerates Orders' four stages and
Inventory's compensation consumer, then requires a `processed_events` table for
"every one of **these** consumers". Notifications is not among them.

**Why the exclusion holds.** Level 3 exists to stop a redelivery re-running a side
effect that must happen once. Rank the side effects by what a duplicate costs:

| Consumer | Duplicate delivery would… | Cost |
|---|---|---|
| Orders' stages | re-reserve, re-charge, re-confirm | money and seats |
| Inventory's compensation | release the same seats twice | oversell, inverted |
| Notifications | send a second identical email | a confused customer |

A duplicate confirmation email is annoying. It is not a correctness failure, it
is not recoverable-by-refund, and it is the price of the property the brief
actually asks Notifications to have: *"Notifications must be able to fail entirely
without failing checkout."* Giving it a database to dedup against would give it a
new way to fail and a new thing to keep available — for an email.

**What would change this.** The exclusion is safe only while the side effect stays
idempotent-enough-in-practice. If Notifications ever gains an effect a duplicate
genuinely breaks — charging for something, issuing a ticket or a voucher, calling
a third party that counts — the architecture decision must be revisited before
that lands, not after. It is recorded in §4 as an accepted risk rather than as a
property.

### 3.4 Evidence

`OrderFailedConsumerDedupTest` drives the real `@KafkaListener` against a real
broker; the Orders tests below run against a real Postgres via Testcontainers.

| Test | What it pins down |
|---|---|
| `OrdersRepositoryPostgresTest` › `processed event insertIfAbsent returns one insert and one duplicate` | The event claim reports 1 then 0, so a redelivered `event_id` is detectable at all. |
| `OrdersRepositoryPostgresTest` › `concurrent processed event inserts allow exactly one winner` | Two concurrent deliveries of the same `event_id`: exactly one wins. The level-3 race, closed. |
| `OrdersStage2RollbackPostgresTest` › `stage2 rolls back processed marker and order status when outbox write fails` | The claim, the status write and the outbox row are genuinely one transaction: a failed outbox write rolls the claim back, so the redelivery reprocesses instead of being skipped as already-done. |
| `OrdersCompensationPathTest` › `payment decline propagates reservation id and reason to final order-failed event` | Stage 4 emits `order-failed` **with** `reservation_id`, which is what tells Inventory there is something to compensate. |
| `Stage2ConsumerTest` › `should propagate reservation id and decline reason to payment-failed outbox` | The `reservation_id` survives the Stage 2 → Stage 4 hop rather than being dropped mid-saga. |
| `SagaRecoveryTest` › `should process and publish pending messages from outbox` | The relay picks up un-sent outbox rows and publishes them, so a write that committed is eventually seen downstream. |
| `OrderFailedConsumerDedupTest` › `a redelivered order-failed event releases the seats only once` | Same `event_id` twice → seats released once, one `processed_events` row. |
| `OrderFailedConsumerDedupTest` › `a replayed event_id is skipped before the handler runs` | Isolates the event_id gate: a replayed `event_id` carrying a *different, still-RESERVED* reservation is skipped, which only a working gate can do. |
| `OrderFailedConsumerDedupTest` › `two distinct event_ids for the same reservation still release the seats only once` | Isolates the status guard: distinct `event_id`s sail past `processed_events`, and RESERVED→RELEASED stops the second release. |
| `OrderFailedConsumerDedupTest` › `an order-failed event without a reservation_id is consumed and changes nothing` | Stage 1's no-seats path is a clean no-op. |

---

## 4. Residual risks and open gaps

The blocking Orders-side defects previously recorded here — bare Kafka topic
names, an `order-failed` payload with no `reservation_id`, a `processed_events`
write that silently did nothing because of a non-null `String` `@Id`, and a
check-then-`save()` TOCTOU race — are **fixed and covered by the tests in §2.4 and
§3.4**. What follows is what is actually still open.

**Orders → Inventory has no bounded retry: the `@Retry` annotation is inert.**
`InventoryClient.reserveSeats` carries `@Retry(name = "inventory-client")` on a
`suspend fun`. resilience4j 2.2.0 ships no coroutine aspect extension, so
`RetryAspect` falls through to `retry.executeCheckedSupplier(joinPoint::proceed)`;
on a suspend function `proceed()` returns `COROUTINE_SUSPENDED` immediately and
without throwing, so Retry records a **success** and never retries. The real
outcome surfaces later in the continuation, outside the aspect's try/catch.

This is the same defect class as the `@CircuitBreaker` already recorded in
`ai-mistake-log.md`; the breaker was moved to the programmatic
`executeSuspendFunction` and the retry was left annotated. `PaymentClient` has no
retry at all — not even an inert one. Contract §1.4 and the capstone brief both
require bounded retries with backoff and jitter on these calls, so this is a
contract gap, not only a resilience one. No test covers it.

**Payments writes after it charges — and the retry that was supposed to heal it
does not exist.** `authorize()` calls the gateway before it persists anything, so
a pod death between the charge and the write leaves the money taken with no local
row. This document previously claimed the ledger self-heals, because Orders'
retry would re-call the gateway and Stripe's `Idempotency-Key: order_id` would
return the same PaymentIntent rather than charge again. That reasoning is sound
but its premise is false: per the item above, **there is no retry on Orders →
Payments**, so nothing re-calls the gateway and nothing heals. Closing this fully
needs claim-before-charge plus a reaper for abandoned claims — larger than §3.2
level 2 asks for, and a design decision. Restoring the retry shrinks the window
but does not remove it.

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

**ACCEPTED RISK — Notifications can send the same email twice.** Its two consumers
have no `event_id` check and no database to keep one in, so a Kafka redelivery
repeats the email. §3.3 sets out why the architecture excluded it and why that
holds: the cost is a confused customer, not money or seats, and giving
Notifications a database to dedup against would hand it a new way to fail in
exchange for suppressing a duplicate email. Accepted, not solved — and it stops
being acceptable the moment Notifications gains a side effect a duplicate really
breaks. Revisit the architecture decision *before* such an effect lands, not after.

**Catalog's availability never converges.** §1.3 sets out why this is safe as
built — nothing on the money path reads that number — but it is a known
simplification, not a property. "Tolerant of staleness" normally implies eventual
convergence, and here no mechanism would ever correct the figure. If Catalog is
ever given one, it must stay display-only: the moment anything trusts it, §1.2's
argument breaks.

**The PC half of PC/EC is asserted, not demonstrated.** §1.2 states what happens
under a partition; nothing proves it. The oversell invariant is proven under
concurrent load in the test suite, not under pod kills, a CloudNativePG primary
failover, or a Kafka partition — DoD Pillar B's last box, and chaos experiments 2,
4 and 5.

**Chaos experiment 5 has no number to pass or fail against.**
`chaos-experiment-hypotheses.md` asserts that "Checkout recovers within the stated
RTO", and the DoD asks whether "recovery happens within stated RTO" — but no
document states one. Until it does, any observed recovery time satisfies the
hypothesis, which makes the experiment unfalsifiable. The RTO is a consistency
decision (it quantifies exactly the availability §1.2 trades away under
partition), so it belongs in §1 once the team sets it. Owner: Data & Consistency.

---

## How to reproduce

The tests live in the **application repo** (`eurotransit-application-g02`), not
here — run these from its root. Docker must be running: Testcontainers starts
PostgreSQL, and the Kafka consumer tests additionally start a broker.

```bash
cd backend/orders    && ./gradlew test
cd backend/inventory && ./gradlew test
cd backend/payments  && ./gradlew test
```

Test counts are deliberately not quoted here, since they drift. What must hold is
the set of named tests in the tables above: if any of them disappears, the
guarantee it backs is no longer validated.
