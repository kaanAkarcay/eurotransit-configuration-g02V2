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

### 1.4 Payments — authorize (internal, called by Orders sync)

Not exposed via Traefik. Called by Orders from within the async pipeline (inside a Kafka consumer). This is the call wrapped by the **circuit breaker**.

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

Idempotency: Payments checks `idempotency_key` in its `processed_events` table. If already authorized, returns the existing transaction. Uses the `order_id` as the key since one order should produce exactly one payment.

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

On success: Orders updates order status to RESERVED, then calls Payments sync (see 1.4).

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

On receive: Orders updates order status to FAILED. No compensation needed (nothing was reserved).

### 2.4 Topic: `eurotransit.order-confirmed`

- Producer: **Orders**
- Consumer: **Notifications**
- Trigger: after Orders receives a successful sync response from Payments

```json
{
  "event_id": "evt-444",
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

### 2.5 Topic: `eurotransit.order-failed`

- Producer: **Orders**
- Consumer: **Inventory** (compensation) + **Notifications** (failure email)
- Trigger: Payments declines or circuit breaker opens

```json
{
  "event_id": "evt-555",
  "order_id": "ord-98765",
  "reservation_id": "res-777",
  "reason": "payment_declined",
  "user_email": "user@example.com"
}
```

On receive by Inventory: releases the reservation (compensation). On receive by Notifications: sends a failure email to the user.

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

```
Client                Orders              Inventory            Payments         Notifications
  |                      |                    |                    |                  |
  |-- POST /orders ----->|                    |                    |                  |
  |<---- 202 PENDING ----|                    |                    |                  |
  |                      |                    |                    |                  |
  |                      |-- order-placed --->|                    |                  |
  |                      |                    |-- reserve (SQL) -->|                  |
  |                      |                    |                    |                  |
  |              [success path]               |                    |                  |
  |                      |<- inv-reserved ----|                    |                  |
  |                      |                    |                    |                  |
  |                      |--------- POST /authorize ------------->|                  |
  |                      |<-------- 200 AUTHORIZED ---------------|                  |
  |                      |                    |                    |                  |
  |                      |-- order-confirmed ---------------------------------------->|
  |                      |                    |                    |                  |
  |-- GET /orders/id --->|                    |                    |                  |
  |<---- CONFIRMED ------|                    |                    |                  |
  |                                                                                  |
  |              [failure: no seats]          |                    |                  |
  |                      |<- inv-failed ------|                    |                  |
  |                      |   (FAILED)         |                    |                  |
  |                                                                                  |
  |              [failure: payment declined]  |                    |                  |
  |                      |--------- POST /authorize ------------->|                  |
  |                      |<-------- 402 DECLINED -----------------|                  |
  |                      |-- order-failed --->|                    |                  |
  |                      |                    |-- release (SQL)    |                  |
  |                      |-- order-failed ------------------------------------------------>|
```