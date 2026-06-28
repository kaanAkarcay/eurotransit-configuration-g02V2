# eurotransit: service integration contract

this document shows the data structures used for communication between the services in the architecture, for both the synchronous (rest) and asynchronous (kafka) parts.

## 1. synchronous path: "the money path" (rest)

this is the critical path. calls here need circuit breakers and idempotency keys, so retries don't cause double charges or double reservations.

### 1.1 orders → inventory (reservation)

inventory is the resource everyone is fighting for, so we need a clear consistency model to avoid overselling seats.

- method & path: `POST /api/v1/inventory/reserve`
- caller: orders
- target: inventory

request payload:

```json
{
  "order_id": "string",
  "idempotency_key": "uuid",
  "train_id": "string",
  "seat_class": "string",
  "quantity": 1
}
```

response (200 ok):

```json
{
  "status": "RESERVED",
  "reservation_id": "string"
}
```

### 1.2 orders → payments (authorization)

payment authorization also needs a synchronous call with strict idempotency, to avoid charging the user twice.

- method & path: `POST /api/v1/payments/authorize`
- caller: orders
- target: payments

request payload:

```json
{
  "order_id": "string",
  "idempotency_key": "uuid",
  "user_id": "string",
  "amount": 45.50,
  "currency": "EUR"
}
```

response (200 ok):

```json
{
  "status": "AUTHORIZED",
  "transaction_id": "string"
}
```

## 2. asynchronous path (kafka / strimzi)

kafka is used here for the order pipeline and for events in general. this allows graceful degradation: for example, if notifications fails completely, the checkout still works fine.

### 2.1 topic: `eurotransit.orders.confirmed`

sent when the checkout workflow finishes successfully.

- producer: orders
- consumer: notifications (sends confirmation emails)

message payload:

```json
{
  "event_id": "uuid",
  "timestamp": "2026-06-28T11:40:00Z",
  "order_id": "string",
  "customer_email": "string",
  "payment_transaction_id": "string",
  "ticket_details": {
    "train_id": "string",
    "departure": "2026-07-15T08:00:00Z",
    "seat_reserved": true
  }
}
```

### 2.2 topic: `eurotransit.orders.failed` (optional / compensation)

sent to trigger compensating actions when something fails in the middle of the async pipeline (e.g. a timeout right after a reservation was made).

message payload:

```json
{
  "event_id": "uuid",
  "timestamp": "2026-06-28T11:42:00Z",
  "order_id": "string",
  "reason": "string",
  "failed_step": "string",
  "compensation_required": true
}
```
