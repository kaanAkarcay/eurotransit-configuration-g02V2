# eurotransit: service integration contract & payloads (v2)

this document defines the data structures and interaction patterns for the eurotransit architecture. the system uses an event-driven choreography via kafka for the critical order pipeline.

## 1. synchronous entrypoint

the only synchronous step in the checkout flow is the initial order submission.

- method & path: `POST /api/v1/orders`
- target: orders service
- behavior: validates the request, generates an internal `order_id`, publishes to kafka, and immediately returns a 202 status.

request payload:

```json
{
  "frontend_idempotency_key": "uuid",
  "user_id": "string",
  "train_id": "string",
  "seat_class": "string",
  "quantity": 1,
  "amount": 45.50,
  "currency": "EUR"
}
```

response (202 accepted):

```json
{
  "status": "PENDING",
  "order_id": "ord-98765"
}
```

## 2. asynchronous order pipeline (kafka)

once the order is accepted, it goes through kafka-driven stages using kotlin flows. every message must include an `event_id` for deduplication.

### 2.1 topic: `eurotransit.order-placed`

- producer: orders
- consumer: inventory

payload:

```json
{
  "event_id": "evt-111",
  "order_id": "ord-98765",
  "train_id": "string",
  "quantity": 1
}
```

### 2.2 topic: `eurotransit.inventory-reserved`

- producer: inventory
- consumer: payments

payload:

```json
{
  "event_id": "evt-222",
  "order_id": "ord-98765",
  "user_id": "string",
  "amount": 45.50
}
```

### 2.3 topic: `eurotransit.payment-authorized`

- producer: payments
- consumer: orders (updates db status to confirmed)

payload:

```json
{
  "event_id": "evt-333",
  "order_id": "ord-98765",
  "transaction_id": "txn-555"
}
```

### 2.4 topic: `eurotransit.order-confirmed`

- producer: orders
- consumer: notifications (graceful degradation: can fail without affecting checkout)

payload:

```json
{
  "event_id": "evt-444",
  "order_id": "ord-98765",
  "user_email": "user@example.com"
}
```

## 3. consistency & idempotency patterns

to handle kafka's at-least-once delivery and partial failures, all services must implement the following:

- inventory consistency (pacelc): strong consistency (pc/ec). the postgresql database is the single source of truth for the contended resource, to avoid overselling.
- idempotency (`processed_events` table): every service database must have a `processed_events` table. when a kafka consumer receives a message, it checks if the `event_id` already exists. if it does, the event is skipped. if not, the service runs its business logic and inserts the `event_id` into the table, in the same database transaction.

## 4. service level objectives (slos)

the critical "money path" is monitored with red dashboards and the following slos:

- latency slo: 99% of checkout workflows (from `POST /orders` to `payment-authorized` completion) finish in under 800ms over a 5-minute rolling window.
- success rate slo: 99.5% of `POST /orders` requests return a non-5xx response over a 5-minute rolling window.
