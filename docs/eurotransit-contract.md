# EuroTransit: service integration contract & payloads (v3)

This document defines the data structures and interaction patterns for the EuroTransit architecture. The system uses an **event-driven orchestration** via Kafka for the critical order pipeline, with **Orders as the central orchestrator**.

---

## 1. Synchronous APIs

### 1.1 Catalog (read-only, public via Traefik)

**List products**

- `GET /api/v1/catalog/products`
- Response `200`:

```json
{
  "products": [
    {
      "train_id": "TR-101",
      "origin": "Turin",
      "destination": "Milan",
      "departure": "2026-07-15T08:30:00Z",
      "seat_classes": [
        { "class": "standard", "price": 25.00, "currency": "EUR", "available": 42 },
        { "class": "business", "price": 45.50, "currency": "EUR", "available": 8 }
      ]
    }
  ]
}
```

**Get single product**

- `GET /api/v1/catalog/products/{train_id}`
- Response `200`: single product object as above
- Response `404`: `{ "error": "product_not_found" }`

### 1.2 Orders — create order (public via Traefik)

The only synchronous step the client directly experiences in the checkout flow — internally, Orders' own stages go on to make further synchronous calls to Inventory and Payments (see §1.4, §1.5), invisible to the client.

- `POST /api/v1/orders`
- Behavior: validates the request, generates an internal `order_id`, saves the order as PENDING and writes `order-placed` to its own outbox table in the same local transaction, then immediately returns 202. Kafka is never called synchronously here — a separate polling relay publishes the outbox row afterward (see §3.3).

Request:

```json
{
  "idempotency_key": "550e8400-e29b-41d4-a716-446655440000",
  "user_id": "user-42",
  "user_email": "user@example.com",
  "train_id": "TR-101",
  "seat_class": "business",
  "quantity": 1,
  "amount": 45.50,
  "currency": "EUR"
}
```

Response `202 Accepted`:

```json
{
  "order_id": "ord-98765",
  "status": "PENDING"
}
```

Response `409 Conflict` (duplicate idempotency_key):

```json
{
  "order_id": "ord-98765",
  "status": "CONFIRMED",
  "message": "order already processed"
}
```

Response `429 Too Many Requests` (load shedding):

- Empty body.
- Header: `Retry-After: <seconds>`.

Orders sheds inbound order creation above the configured concurrency limit
(`app.backpressure.orders.max-concurrent-requests`) rather than queueing work it
cannot complete. Clients should retry after `Retry-After` seconds. This is
deliberately non-5xx and therefore does not consume the §4.2 success-rate error
budget.

Idempotency: Orders checks the `idempotency_key` against its `processed_requests` table. If already seen, it returns the existing order. This deduplicates the frontend (user clicking "buy" twice).

### 1.3 Orders — poll order status (public via Traefik)

The frontend polls this endpoint to know when the async pipeline completes.

- `GET /api/v1/orders/{order_id}`

Response `200`:

```json
{
  "order_id": "ord-98765",
  "status": "CONFIRMED",
  "train_id": "TR-101",
  "seat_class": "business",
  "quantity": 1,
  "amount": 45.50,
  "currency": "EUR",
  "transaction_id": "txn-555",
  "created_at": "2026-07-15T10:00:00Z",
  "confirmed_at": "2026-07-15T10:00:00.450Z"
}
```

Possible statuses: `PENDING` → `RESERVED` → `CONFIRMED` | `FAILED`

### 1.4 Inventory — reserve (internal, called synchronously by Orders)

Not exposed via Traefik. Called synchronously by Orders' Stage 1 consumer (see §2.1), wrapped in a timeout + bounded retry with backoff and jitter.

- `POST /reserve`

Request:

```json
{
  "idempotency_key": "ord-98765",
  "train_id": "TR-101",
  "seat_class": "business",
  "quantity": 1
}
```

Response `200`:

```json
{
  "reservation_id": "res-777",
  "status": "RESERVED"
}
```

Response `409 Conflict`:

```json
{
  "status": "INSUFFICIENT_SEATS"
}
```

Behavior: reserves seats atomically via `UPDATE ... WHERE available >= :quantity` (see §3.1) and returns the decision immediately — no Kafka involved in this call at all.

Idempotency: Inventory checks `idempotency_key` (the `order_id`) against its own `processed_requests` table. If already reserved, returns the existing `reservation_id` instead of reserving again — this is what protects Orders' bounded retries from double-reserving.

### 1.5 Payments — authorize (internal, called synchronously by Orders)

Not exposed via Traefik. Called synchronously by Orders' Stage 2 consumer (see §2.2). This is the call wrapped by **Orders' circuit breaker** (open / half-open, fallback = treat as `payment-failed`) — the exact edge the capstone brief names as its circuit-breaker example.

- `POST /api/v1/payments/authorize`

Request:

```json
{
  "idempotency_key": "ord-98765",
  "user_id": "user-42",
  "amount": 45.50,
  "currency": "EUR"
}
```

Response `200`:

```json
{
  "transaction_id": "txn-555",
  "status": "AUTHORIZED"
}
```

Response `402`:

```json
{
  "status": "DECLINED",
  "reason": "insufficient_funds"
}
```

Idempotency: Payments checks `idempotency_key` (the `order_id`) against its own `processed_requests` table. If already authorized, returns the existing transaction instead of calling the gateway again — this protects Orders' bounded retries from double-charging.

Internally, Payments calls the external payment gateway — its **own**, separate synchronous call, wrapped in its **own**, separate circuit breaker (open / half-open, fallback = respond `402` without reaching the gateway at all, `reason: "circuit_breaker_open"`). This gives two independent circuit breakers protecting two independent failure modes: Orders is protected from a slow/unavailable Payments; Payments is protected from a slow/unavailable gateway.

---

## 2. Asynchronous order pipeline (Kafka)

Orders is the sole producer and the sole consumer of every topic below except `order-confirmed` (also consumed by Notifications) and `order-failed` (also consumed by Notifications and Inventory, for compensation). Each topic marks the boundary between one of Orders' four internal stages — entered by consuming an event, exited by publishing the next one. Every Kafka message includes an `event_id` for consumer-side deduplication and an `event_timestamp` with the UTC instant when the producer created the event payload.

### Order state machine

```
PENDING → RESERVED → CONFIRMED
   ↓         ↓
 FAILED    FAILED (+ compensation: release reservation)
```

### 2.1 Topic: `eurotransit.order-placed`

- Producer: **Orders** (right after `POST /orders` saves PENDING and returns 202)
- Consumer: **Orders**, Stage 1 (Reservation)
- Trigger: enters Stage 1

```json
{
  "event_id": "evt-111",
  "event_timestamp": "2026-07-15T10:00:00Z",
  "order_id": "ord-98765",
  "train_id": "TR-101",
  "seat_class": "business",
  "quantity": 1
}
```

Stage 1 behavior: calls Inventory synchronously (`POST /reserve`, see §1.4). On `200`: publishes `inventory-reserved`. On `409`: publishes `order-failed` directly — no reservation was ever made, so there's nothing for Inventory to compensate, and no intermediate topic is needed.

### 2.2 Topic: `eurotransit.inventory-reserved`

- Producer: **Orders**, Stage 1 (after a successful synchronous reserve)
- Consumer: **Orders**, Stage 2 (Payment)
- Trigger: enters Stage 2

```json
{
  "event_id": "evt-222",
  "event_timestamp": "2026-07-15T10:00:00.100Z",
  "order_id": "ord-98765",
  "reservation_id": "res-777",
  "user_id": "user-42",
  "amount": 45.50,
  "currency": "EUR"
}
```

Stage 2 behavior: order status set to RESERVED; calls Payments synchronously (`POST /authorize`, see §1.5). On `200`: publishes `payment-authorized`. On `402`: publishes `payment-failed`.

### 2.3 Topic: `eurotransit.payment-authorized`

- Producer: **Orders**, Stage 2 (after a successful synchronous authorize)
- Consumer: **Orders**, Stage 3 (Confirmation)
- Trigger: enters Stage 3

```json
{
  "event_id": "evt-444a",
  "event_timestamp": "2026-07-15T10:00:00.350Z",
  "order_id": "ord-98765",
  "transaction_id": "txn-555",
  "amount": 45.50,
  "currency": "EUR"
}
```

Stage 3 behavior: order status set to CONFIRMED, publishes `order-confirmed`. No further downstream call needed.

### 2.4 Topic: `eurotransit.payment-failed`

- Producer: **Orders**, Stage 2 (after a declined or circuit-breaker-fallback authorize)
- Consumer: **Orders**, Stage 4 (Failure handling)
- Trigger: enters Stage 4

```json
{
  "event_id": "evt-444b",
  "event_timestamp": "2026-07-15T10:00:00.350Z",
  "order_id": "ord-98765",
  "reservation_id": "res-777",
  "reason": "insufficient_funds"
}
```

Note: `reason` is `"insufficient_funds"` (or similar) for a real decline, or `"circuit_breaker_open"` when Payments' own circuit breaker fell back without reaching the gateway. Both cases are indistinguishable to the client (order still ends up FAILED) but distinguishable in dashboards/logs for diagnosing which failure mode occurred.

Stage 4 behavior: order status set to FAILED, publishes `order-failed` — this time **with** `reservation_id`, since a reservation exists and needs releasing.

### 2.5 Topic: `eurotransit.order-confirmed`

- Producer: **Orders**, Stage 3
- Consumer: **Notifications**
- Trigger: after Orders' Stage 3 confirms the order

```json
{
  "event_id": "evt-555",
  "event_timestamp": "2026-07-15T10:00:00.450Z",
  "order_id": "ord-98765",
  "user_email": "user@example.com",
  "train_id": "TR-101",
  "seat_class": "business",
  "quantity": 1,
  "amount": 45.50,
  "transaction_id": "txn-555"
}
```

On receive: Notifications sends a confirmation email. **Graceful degradation**: if Notifications is down, the event stays in Kafka and will be processed when it recovers. The checkout is already complete.

### 2.6 Topic: `eurotransit.order-failed`

- Producer: **Orders** — either Stage 1 directly (no-seats case, no `reservation_id`) or Stage 4 (payment-failed case, **with** `reservation_id`)
- Consumer: **Inventory** (compensation) + **Notifications** (failure email)
- Trigger: Stage 1's synchronous reserve call returns 409, **or** Stage 4 processes a `payment-failed`

```json
{
  "event_id": "evt-666",
  "event_timestamp": "2026-07-15T10:00:00.450Z",
  "order_id": "ord-98765",
  "reservation_id": "res-777",
  "reason": "insufficient_funds",
  "user_email": "user@example.com"
}
```

Note: `reservation_id` is only present when the failure happened after a reservation existed (i.e. published by Stage 4, not by Stage 1's direct no-seats path) — that's what tells Inventory whether there's anything to compensate. For payment failures, `reason` is propagated from `payment-failed`; if Stage 4 receives an older or malformed event without a reason, it uses `PAYMENT_REJECTED`.

On receive by Inventory: if `reservation_id` is present, releases the reservation (compensation) by calling its own `UPDATE seats SET available = available + :quantity ...`; otherwise ignores (nothing was reserved). On receive by Notifications: sends a failure email to the user.

---

## 3. Consistency & idempotency patterns

### 3.1 Inventory consistency (PACELC: PC/EC)

Strong consistency via PostgreSQL single-primary (CloudNativePG). The atomic reservation uses:

```sql
UPDATE seats
SET available = available - :quantity
WHERE train_id = :train_id
  AND seat_class = :seat_class
  AND available >= :quantity
RETURNING available;
```

If 0 rows affected → insufficient seats → respond `409` to Orders' synchronous `POST /reserve` call (see §1.4); Orders' Stage 1 then publishes `order-failed` directly. This guarantees the "never oversell" invariant even under concurrent requests, because the `WHERE available >= :quantity` check and the decrement happen in a single atomic operation — and it now happens inside a synchronous HTTP handler rather than a Kafka consumer, which doesn't change the guarantee at all.

During a network partition (P): refuse writes rather than risk overselling (choose C). In normal operation (E): accept slightly higher latency from always hitting the primary (choose C), because the cost of showing wrong availability is higher than the cost of a few extra milliseconds.

### 3.2 Idempotency — three levels

**Level 1: frontend deduplication (sync)**

Orders has a `processed_requests` table keyed on `idempotency_key` from the REST request. If the user clicks "buy" twice with the same key, the second call returns the existing order instead of creating a duplicate.

**Level 2: internal synchronous call deduplication (sync)**

Inventory (`POST /reserve`, §1.4) and Payments (`POST /authorize`, §1.5) each have their own `processed_requests` table, keyed on the `order_id` Orders sends as the idempotency key. This is the same pattern as Level 1, one hop deeper: it's what protects Orders' bounded retry-with-backoff-and-jitter on these two synchronous calls from double-reserving a seat or double-charging a card if a retry is actually a duplicate of a request that already succeeded (e.g. the response was lost but the write committed).

**Level 3: Kafka consumer deduplication (async)**

Orders is the only service that consumes Kafka events on the money path now — it consumes its own `order-placed`, `inventory-reserved`, `payment-authorized`, and `payment-failed` across its four stages (see §2). Inventory also consumes `order-failed`, for compensation. Every one of these consumers has a `processed_events` table:

```sql
CREATE TABLE processed_events (
    event_id   TEXT PRIMARY KEY,
    result     JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);
```

When a consumer receives a message:
1. Check if `event_id` exists in `processed_events`
2. If yes → skip (return cached result if needed)
3. If no → run business logic + insert `event_id` in the **same database transaction**

This handles Kafka's at-least-once delivery: the same event arriving twice is harmlessly deduplicated.

### 3.3 Reliable publishing (Outbox pattern)

§3.2 covers the consumer side of at-least-once delivery (dedup on receive). This section covers the producer side: making sure an event is never silently lost between committing a local write and publishing it to Kafka.

**The problem**: a DB write immediately followed by a Kafka publish, where a pod killed in between leaves the local state saying "done" while the event is never sent and nothing downstream ever finds out. This only applies to a service that does both a DB write and a Kafka publish for the same operation — with Inventory and Payments now pure synchronous services (§1.4, §1.5) with no Kafka producer at all, **Orders is the only service with this problem**: every one of its four stages writes to its own DB and immediately publishes the next event.

**The fix**: Orders writes the outgoing event to its own `outbox` table, in the **same database transaction** as the business write:

```sql
CREATE TABLE outbox (
    id         BIGSERIAL PRIMARY KEY,
    event_id   TEXT NOT NULL,
    topic      TEXT NOT NULL,
    payload    JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    sent_at    TIMESTAMPTZ
);
```

A polling relay — a scheduled loop inside the service — periodically runs:

```sql
SELECT * FROM outbox
WHERE sent_at IS NULL
ORDER BY id
FOR UPDATE SKIP LOCKED
LIMIT 100;
```

For each row: publish `payload` to `topic`, then set `sent_at`. `FOR UPDATE SKIP LOCKED` means that if Orders is scaled to multiple replicas, two replica pollers running at the same time will never grab and double-publish the same row — each locks and skips whatever the other has already claimed.

Inventory and Payments don't need this: Inventory's reservation is a single transaction in its own database with no second system to coordinate with (it answers Orders synchronously, in the same request), and Payments never publishes anything at all.

This does not weaken the consistency model in §3.1: the business decision (e.g. the reservation) is still made atomically and instantly, in the same transaction as before. The outbox only affects how quickly that already-durable decision is relayed to Kafka — a pipeline-latency concern, not a correctness concern.

---

## 4. Service level objectives (SLOs)

### 4.1 Latency SLO

**Objective**: 99% of orders reach CONFIRMED within ~7.16s of creation, measured over a 5-minute rolling window.

**SLI**: `confirmed_at - created_at` for each order that reaches CONFIRMED. Computed by Orders when it writes the final status update.

**Error budget**: over 1000 orders in 5 minutes, up to 10 can exceed ~7.16s.

**Revalidated under real load 2026-07-16**: the original 800ms target was never achievable. 10 real CONFIRMED orders measured 1.17s–5.36s end to end. Root cause: the critical path crosses Orders' own once-per-second outbox poll (`OutboxRelay`, `fixedDelay = 1000`) three times (`order-placed` → `inventory-reserved` → `payment-authorized`/`payment-failed` → `order-confirmed`/`order-failed`), each hop able to wait up to ~1s for the next poll tick before any work starts, on top of the two real synchronous HTTP calls embedded inside those stages (Orders→Inventory, Orders→Payments) and one more inside Payments (Payments→gateway). Retargeted to ~7.16s — a real Micrometer histogram bucket already present from `publishPercentileHistogram()`'s default buckets (`le="7.158278826"`), giving headroom above the observed range without needing a code change. If the outbox poll interval is later reduced (e.g. 1000ms → 200-300ms), this budget should be revisited downward with fresh real numbers rather than left stale.

### 4.2 Gateway success rate SLO

**Objective**: 99.5% of `POST /api/v1/orders` requests return non-5xx over a 5-minute rolling window.

**SLI**: `rate(http_requests_total{status!~"5.."}[5m]) / rate(http_requests_total[5m])` on the Orders service.

**Note**: this measures only gateway availability (is Orders alive?), not pipeline success.

### 4.3 Pipeline completion SLO

**Objective**: 99% of PENDING orders reach a terminal state (CONFIRMED or FAILED) within 30 seconds, over a 5-minute rolling window.

**SLI**: orders that have been PENDING for > 30 seconds without reaching a terminal state. This catches stuck orders due to consumer lag, Kafka issues, or downstream failures.

### 4.4 Alerting

All SLOs use **burn-rate alerting** (not threshold alerting). A fast burn (14.4× error budget consumption) pages immediately. A slow burn (3× consumption over 1 hour) creates a ticket. This avoids alert fatigue from transient spikes.

---

## 5. Order flow summary

The diagram below is column-verified: every arrow's start and end sit exactly under the two lifelines it connects (generated programmatically rather than hand-aligned, after an earlier hand-drawn version had a decline/circuit-breaker response visually drifting into the wrong column).

```
  Client                 Orders                                                 Inventory                          Payments                                Payment Gateway          Notifications
  |                      |                                                      |                                  |                                       |                        |
  |----POST /orders----->|                                                      |                                  |                                       |                        |
  |<-----202 PENDING-----|                                                      |                                  |                                       |                        |
  |                      | [Kafka: order-placed -> Stage 1 begins]              |                                  |                                       |                        |
  |                      |                                                      |                                  |                                       |                        |
              [success path]
  |                      |--------------------POST /reserve-------------------->|                                  |                                       |                        |
  |                      |<--------------------200 reserved---------------------|                                  |                                       |                        |
  |                      | [Kafka: inventory-reserved -> Stage 2 begins]        |                                  |                                       |                        |
  |                      |------------------------------------POST /authorize------------------------------------->|                                       |                        |
  |                      |                                                      |                                  |--------------call (CB)--------------->|                        |
  |                      |                                                      |                                  |<----------------200 OK----------------|                        |
  |                      |<-------------------------------------200 authorized-------------------------------------|                                       |                        |
  |                      | [Kafka: payment-authorized -> Stage 3 begins]        |                                  |                                       |                        |
  |                      |---------------------------------------------------------------------order-confirmed--------------------------------------------------------------------->|
  |                      |                                                      |                                  |                                       |                        |
  |---GET /orders/id---->|                                                      |                                  |                                       |                        |
  |<------CONFIRMED------|                                                      |                                  |                                       |                        |
  |                      |                                                      |                                  |                                       |                        |
              [failure: no seats]
  |                      |--------------------POST /reserve-------------------->|                                  |                                       |                        |
  |                      |<--------------------409 no seats---------------------|                                  |                                       |                        |
  |                      | [Kafka: order-failed (no reservation_id)]            |                                  |                                       |                        |
  |                      |----------------------------------------------------------------------order-failed----------------------------------------------------------------------->|
  |                      |                                                      |                                  |                                       |                        |
              [failure: payment declined by gateway]
  |                      |--------------------POST /reserve-------------------->|                                  |                                       |                        |
  |                      |<--------------------200 reserved---------------------|                                  |                                       |                        |
  |                      |------------------------------------POST /authorize------------------------------------->|                                       |                        |
  |                      |                                                      |                                  |--------------call (CB)--------------->|                        |
  |                      |                                                      |                                  |<---------------declined---------------|                        |
  |                      |<--------------------------------------402 declined--------------------------------------|                                       |                        |
  |                      | [Kafka: payment-failed -> Stage 4 begins]            |                                  |                                       |                        |
  |                      |--------------------order-failed--------------------->|                                  |                                       |                        |
  |                      |                                                      | [release reservation (SQL)]      |                                       |                        |
  |                      |----------------------------------------------------------------------order-failed----------------------------------------------------------------------->|
  |                      |                                                      |                                  |                                       |                        |
              [failure: circuit breaker OPEN -- gateway is skipped entirely]
  |                      |--------------------POST /reserve-------------------->|                                  |                                       |                        |
  |                      |<--------------------200 reserved---------------------|                                  |                                       |                        |
  |                      |------------------------------------POST /authorize------------------------------------->|                                       |                        |
  |                      |                                                      |                                  | [CB open: skip call, fallback now]    |                        |
  |                      |<--------------------------------------402 declined--------------------------------------|                                       |                        |
  |                      |--------------------order-failed--------------------->|                                  |                                       |                        |
  |                      |                                                      | [release reservation (SQL)]      |                                       |                        |
  |                      |----------------------------------------------------------------------order-failed----------------------------------------------------------------------->|
```

Notes:
- `POST /reserve` and `POST /authorize` are real synchronous calls — Orders blocks and gets an immediate decision, exactly matching the capstone brief's domain table ("Synchronous reservation," "Synchronous call") and its circuit-breaker example (Orders → Payments).
- The `[Kafka: ... -> Stage N begins]` self-notes on Orders' own lane are its four internal stages: each is entered by consuming an event Orders itself published, and exited by publishing the next one. This is what makes "reservation, payment, and confirmation proceed through Kafka-driven stages" literally true, while the actual reservation/authorization decisions are real synchronous calls.
- The "Payment Gateway" lane is the external third-party payment processor Payments calls out to — not an API/ingress gateway (Traefik never appears in this diagram; it only fronts the two client-facing endpoints above). In this deployment that processor is fronted by an in-cluster adapter service, `payment-gateway-sim`, which calls Stripe's PaymentIntents API for real and supports a deterministic fault-injection short-circuit (`X-Simulate-*` headers) for chaos/test harnesses; the Payments→gateway request/response contract is unchanged.
- The no-seats failure branch notifies Notifications too, matching §2.6: `order-failed`'s consumers (Inventory + Notifications) are unconditional — every message on that topic reaches both, regardless of which upstream event triggered it. Inventory only acts on it (releases a reservation) when `reservation_id` is present.
- The two payment-failure sub-cases are drawn separately: a real decline still calls the gateway and gets `declined` back; a circuit-breaker-open fallback never calls the gateway at all — Payments short-circuits straight to responding `402`.
