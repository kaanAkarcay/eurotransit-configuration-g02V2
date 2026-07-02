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

The only synchronous step in the checkout flow.

- `POST /api/v1/orders`
- Behavior: validates the request, generates an internal `order_id`, saves the order as PENDING in PostgreSQL, publishes `order-placed` to Kafka, and immediately returns 202.

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

### 1.4 Payments

Payments has no exposed API and no synchronous inbound call from Orders. It is a pure Kafka consumer/producer — see topics 2.4-2.6. The only synchronous call left anywhere in the system is Payments' own outbound call to the external payment gateway, wrapped in a **circuit breaker** (open / half-open, fallback = publish `payment-failed`).

---

## 2. Asynchronous order pipeline (Kafka)

Orders is the orchestrator: it publishes events, receives intermediate results, and decides the next step. Every Kafka message includes an `event_id` for consumer-side deduplication.

### Order state machine

```
PENDING → RESERVED → CONFIRMED
   ↓         ↓
 FAILED    FAILED (+ compensation: release reservation)
```

### 2.1 Topic: `eurotransit.order-placed`

- Producer: **Orders**
- Consumer: **Inventory**
- Trigger: after POST /orders saves PENDING and returns 202

```json
{
  "event_id": "evt-111",
  "order_id": "ord-98765",
  "train_id": "TR-101",
  "seat_class": "business",
  "quantity": 1
}
```

### 2.2 Topic: `eurotransit.inventory-reserved`

- Producer: **Inventory**
- Consumer: **Orders**
- Trigger: after Inventory successfully reserves seats via atomic PostgreSQL update

```json
{
  "event_id": "evt-222",
  "order_id": "ord-98765",
  "reservation_id": "res-777",
  "train_id": "TR-101",
  "seat_class": "business",
  "quantity": 1
}
```

On success: Orders updates order status to RESERVED, then publishes `payment-requested` (see 2.4).

### 2.3 Topic: `eurotransit.inventory-reservation-failed`

- Producer: **Inventory**
- Consumer: **Orders**
- Trigger: no seats available (`UPDATE ... WHERE available >= :qty` returns 0 rows)

```json
{
  "event_id": "evt-222b",
  "order_id": "ord-98765",
  "reason": "insufficient_seats"
}
```

On receive: Orders updates order status to FAILED, publishes `order-failed`. No compensation needed (nothing was reserved).

### 2.4 Topic: `eurotransit.payment-requested`

- Producer: **Orders**
- Consumer: **Payments**
- Trigger: after Orders consumes `inventory-reserved`

```json
{
  "event_id": "evt-333",
  "order_id": "ord-98765",
  "user_id": "user-42",
  "amount": 45.50,
  "currency": "EUR"
}
```

On receive: Payments checks `order_id` against its `processed_events` table (see §3.2 — same pattern as every other consumer). If new, it calls the external payment gateway inside a circuit breaker (open / half-open, fallback below), then publishes `payment-authorized` or `payment-failed`.

### 2.5 Topic: `eurotransit.payment-authorized`

- Producer: **Payments**
- Consumer: **Orders**
- Trigger: external gateway call succeeds

```json
{
  "event_id": "evt-444a",
  "order_id": "ord-98765",
  "transaction_id": "txn-555",
  "amount": 45.50,
  "currency": "EUR"
}
```

On receive: Orders updates order status to CONFIRMED, publishes `order-confirmed` (see 2.7).

### 2.6 Topic: `eurotransit.payment-failed`

- Producer: **Payments**
- Consumer: **Orders**
- Trigger: gateway declines the payment, **or** the circuit breaker is open and falls back without calling the gateway at all

```json
{
  "event_id": "evt-444b",
  "order_id": "ord-98765",
  "reason": "insufficient_funds"
}
```

Note: `reason` is `"insufficient_funds"` (or similar) for a real decline, or `"circuit_breaker_open"` when the fallback fires without reaching the gateway. Both cases are indistinguishable to the client (order still ends up FAILED) but distinguishable in dashboards/logs for diagnosing which failure mode is occurring.

On receive: Orders updates order status to FAILED, publishes `order-failed` (see 2.8).

### 2.7 Topic: `eurotransit.order-confirmed`

- Producer: **Orders**
- Consumer: **Notifications**
- Trigger: after Orders consumes `payment-authorized`

```json
{
  "event_id": "evt-555",
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

### 2.8 Topic: `eurotransit.order-failed`

- Producer: **Orders**
- Consumer: **Inventory** (compensation) + **Notifications** (failure email)
- Trigger: Orders consumes `inventory-reservation-failed` **or** `payment-failed`

```json
{
  "event_id": "evt-666",
  "order_id": "ord-98765",
  "reservation_id": "res-777",
  "reason": "payment_declined",
  "user_email": "user@example.com"
}
```

Note: `reservation_id` is only present when the failure happened after a reservation existed (i.e. triggered by `payment-failed`, not by `inventory-reservation-failed`) — that's what tells Inventory whether there's anything to compensate.

On receive by Inventory: if `reservation_id` is present, releases the reservation (compensation); otherwise ignores (nothing was reserved). On receive by Notifications: sends a failure email to the user.

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

If 0 rows affected → insufficient seats → publish `inventory-reservation-failed`. This guarantees the "never oversell" invariant even under concurrent requests, because the `WHERE available >= :quantity` check and the decrement happen in a single atomic operation.

During a network partition (P): refuse writes rather than risk overselling (choose C). In normal operation (E): accept slightly higher latency from always hitting the primary (choose C), because the cost of showing wrong availability is higher than the cost of a few extra milliseconds.

### 3.2 Idempotency — two levels

**Level 1: frontend deduplication (sync)**

Orders has a `processed_requests` table keyed on `idempotency_key` from the REST request. If the user clicks "buy" twice with the same key, the second call returns the existing order instead of creating a duplicate.

**Level 2: Kafka consumer deduplication (async)**

Every service that consumes Kafka events has a `processed_events` table:

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

---

## 4. Service level objectives (SLOs)

### 4.1 Latency SLO

**Objective**: 99% of orders reach CONFIRMED within 800ms of creation, measured over a 5-minute rolling window.

**SLI**: `confirmed_at - created_at` for each order that reaches CONFIRMED. Computed by Orders when it writes the final status update.

**Error budget**: over 1000 orders in 5 minutes, up to 10 can exceed 800ms.

**Open risk — needs load-test validation**: this target was set when payment authorization was a single synchronous HTTP call. The critical path is now 4 Kafka hops end-to-end (`order-placed`, `inventory-reserved`, `payment-requested`, `payment-authorized`), each adding producer/broker/consumer latency beyond a direct call. Keep 800ms as the target, but validate it under load once the pipeline is running, before wiring burn-rate alerts around it — if it's not achievable, revisit with real numbers rather than a guess. Tune consumer poll settings (e.g. low `fetch.min.bytes`/`linger.ms`) if the extra hops push latency over budget.

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
  Client               Orders                       Inventory                           Payments                           Payment Gateway        Notifications
  |                      |                              |                                  |                                      |                     |
  |----POST /orders----->|                              |                                  |                                      |                     |
  |<-----202 PENDING-----|                              |                                  |                                      |                     |
  |                      |                              |                                  |                                      |                     |
  |                      |--------order-placed--------->|                                  |                                      |                     |
  |                      |                              | [atomic reserve (SQL)]           |                                      |                     |
  |                      |                              |                                  |                                      |                     |
              [success path]
  |                      |<-----inventory-reserved------|                                  |                                      |                     |
  |                      |-----------------------payment-requested------------------------>|                                      |                     |
  |                      |                              |                                  |--------------call (CB)-------------->|                     |
  |                      |                              |                                  |<---------------200 OK----------------|                     |
  |                      |<-----------------------payment-authorized-----------------------|                                      |                     |
  |                      |-------------------------------------------------------order-confirmed------------------------------------------------------->|
  |                      |                              |                                  |                                      |                     |
  |---GET /orders/id---->|                              |                                  |                                      |                     |
  |<------CONFIRMED------|                              |                                  |                                      |                     |
  |                      |                              |                                  |                                      |                     |
              [failure: no seats]
  |                      |<---inv-reservation-failed----|                                  |                                      |                     |
  |                      |--------order-failed--------->|                                  |                                      |                     |
  |                      |                              | [no reservation, ignored]        |                                      |                     |
  |                      |--------------------------------------------------------order-failed--------------------------------------------------------->|
  |                      |                              |                                  |                                      |                     |
              [failure: payment declined by gateway]
  |                      |-----------------------payment-requested------------------------>|                                      |                     |
  |                      |                              |                                  |--------------call (CB)-------------->|                     |
  |                      |                              |                                  |<--------------declined---------------|                     |
  |                      |<-------------------------payment-failed-------------------------|                                      |                     |
  |                      |--------order-failed--------->|                                  |                                      |                     |
  |                      |                              | [release reservation (SQL)]      |                                      |                     |
  |                      |--------------------------------------------------------order-failed--------------------------------------------------------->|
  |                      |                              |                                  |                                      |                     |
              [failure: circuit breaker OPEN -- gateway is skipped entirely]
  |                      |-----------------------payment-requested------------------------>|                                      |                     |
  |                      |                              |                                  | [CB open: skip call, fallback now]   |                     |
  |                      |<-------------------------payment-failed-------------------------|                                      |                     |
  |                      |--------order-failed--------->|                                  |                                      |                     |
  |                      |                              | [release reservation (SQL)]      |                                      |                     |
  |                      |--------------------------------------------------------order-failed--------------------------------------------------------->|
```

Notes:
- The "Payment Gateway" lane is the external third-party payment processor Payments calls out to — not an API/ingress gateway (Traefik never appears in this diagram; it only fronts the two client-facing endpoints above).
- The no-seats failure branch now notifies Notifications too, matching §2.8: `order-failed`'s consumers (Inventory + Notifications) are unconditional — every message on that topic reaches both, regardless of which upstream event triggered it.
- The two payment-failure sub-cases are now drawn separately per §2.6: a real decline still calls the gateway and gets `declined` back; a circuit-breaker-open fallback never calls the gateway at all — Payments short-circuits straight to publishing `payment-failed`.