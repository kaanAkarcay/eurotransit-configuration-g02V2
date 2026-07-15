# AI Mistake Log

Concrete cases where an agent-produced artifact was incorrect, unsafe, or subtly
wrong, per `ai-guidelines.md` §17. Only mistakes of the gravity the capstone
names (non-idempotent handlers, silently broken persistence, contract
divergence) are recorded here.

> Attribution note: several entries below concern an Orders session (commit
> `0993a04`, "Fase 1: Implement Saga pattern (Stages 1-4)...") that was never
> logged in `ai-logs.md`, which §16 requires — itself a process gap. AI
> generation is inferred from style markers (a Catalan comment in
> `Stage2Consumer.kt`, narrative restating comments, DTOs invented off-contract).
> This log records mistakes at the level of the artifact; it does not attribute
> them to any individual.

---

### 2026-07-15 18:00

#### Title

Orders' circuit breakers could never open — annotation inert, no call timeout

#### Agent

Not recorded (the `@CircuitBreaker` annotations on Orders' clients predate this
session; origin unlogged — see attribution note).

#### Context

`InventoryClient.reserveSeats` and `PaymentClient.authorizePayment` guard the two
synchronous downstream edges the architecture requires to be resilient
(architecture-design.md §2: `timeout + bounded retry`, and `circuit breaker,
fallback = treat as declined`). Both were annotated `@CircuitBreaker` and the
WebClients were built from a bare `WebClient.Builder`.

#### Incorrect Suggestion

`@CircuitBreaker(name = "…-client")` on a `suspend fun`, plus a WebClient with no
response timeout — presented as a working breaker on each edge.

#### Why It Was Wrong

Two compounding faults made the breaker a no-op against the exact failure it
exists for:

- **No timeout.** With no `responseTimeout` on the Netty connector, a hung or
  network-partitioned downstream leaves `awaitBody()` suspended indefinitely. A
  circuit breaker only records *outcomes* (success/failure); a call that never
  returns is never counted, so the breaker never reaches its threshold and never
  opens. A `resilience4j.timelimiter` block existed in config but was inert — no
  `@TimeLimiter` was ever wired to it.
- **Inert annotation.** Even discounting the timeout, the `@CircuitBreaker` aspect
  never ran: no `aspectjweaver` is on Orders' runtime classpath (so resilience4j's
  `AspectJOnClasspathCondition` creates no aspect bean), and the resilience4j
  2.2.0 aspect does not support Kotlin `suspend` functions — it dispatches on the
  static return type and records *success* the instant the coroutine suspends.

Net effect: "resilience theater". The config, the annotation and the dashboards
all implied a protected edge, while under a real Inventory/Payments outage the
breaker stayed CLOSED and every caller hung.

#### How It Was Detected

Reviewing config PR #22 (a Chaos Mesh experiment to "tune the Orders→Inventory
breaker"). Tracing whether the experiment could actually make the breaker open
showed it could not — a `partition` fault drops packets, and with no timeout the
call just hangs past the fault window. Following that into the Orders source
confirmed the root cause was the client, not the experiment. The inert-aspect
half was then proven by inspecting the runtime classpath (no aspectjweaver) and
the resilience4j 2.2.0 jar (no coroutine handling); a new integration test opens
the breaker under the programmatic path and fails under the annotation path.

#### Correct Solution

Mirror payments' `HttpPaymentGateway`: set a Reactor Netty `responseTimeout`
(inventory 2s, payments 6s) so a hung call becomes a recorded failure, and drive
the breaker **programmatically** via `circuitBreakerRegistry.circuitBreaker(name)
.executeSuspendFunction { … }` instead of the annotation. The inert `timelimiter`
block is removed. Instance names are unchanged, so all GitOps circuit-breaker
config still binds. (Landed in the 2026-07-15 application/config PRs.)

#### Lesson Learned

A circuit breaker is only as real as the timeout under it: without a bounded call,
it cannot observe the outage it guards. And an annotation-based resilience aspect
must be verified to actually fire — on Kotlin suspend functions, and with the
aspect weaver actually present — not assumed from the annotation being written.

---

### 2026-07-13 16:30

#### Title

Persistence silently writes nothing for every String-keyed entity in Orders

#### Agent

Not recorded (unlogged session behind commit `0993a04`; see attribution note).

#### Context

Orders persists its core state through Spring Data R2DBC `save()` on entities
whose `@Id` is a non-null `String`: `Order`, `ProcessedRequest` (idempotency
level 1) and `ProcessedEvent` (idempotency level 3, all four stage consumers).

#### Incorrect Suggestion

`orderRepo.save(order)`, `requestRepo.save(processedReq)` and
`processedEventRepo.save(ProcessedEvent(eventId))` were generated as if `save()`
inserts new rows.

#### Why It Was Wrong

Spring Data R2DBC treats a non-null id as "not new" and issues an **UPDATE**,
which affects 0 rows on an empty table and — verified empirically on this exact
stack — **completes silently**. No exception, no row. The consequences compound:

- `POST /orders` returns 202 but the order row is never written; `GET
  /orders/{id}` 404s and Stage 4's `findById` throws, causing endless Kafka
  redelivery.
- Level 1 idempotency never records a key: double-clicking "buy" creates two
  orders.
- Level 3 dedup never records an event_id: `existsById` is always false, so
  every stage reprocesses every redelivered event in full — the "non-idempotent
  handler" failure class verbatim.

The outbox is the one thing that works (`OutboxEntry` has `@Id Long? = null`,
so it genuinely inserts), which makes the system *look* alive: events flow while
the state behind them was never saved.

#### How It Was Detected

Phase 2 consistency review. First noticed reading `Stage1Consumer`; proven by a
throwaway integration test against Postgres via Testcontainers: `save()` on a
String-keyed entity returned success, `count()` stayed 0. Invisible to the
existing suite because every Orders "integration" test mocks the repositories
(`SagaIntegrationTest` stubs `orderRepo.save` to echo its argument).

#### Correct Solution

Pending (Orders owner). Options: explicit `INSERT ... ON CONFLICT` `@Query`
methods returning affected rows (the pattern Inventory/Payments now use),
implementing `Persistable.isNew()`, or DB-generated keys. Plus at least one
repository test against a real database.

#### Lesson Learned

`save()` semantics depend on id nullability — never assume insert. Tests that
mock the repository can't catch persistence bugs; every service needs at least
one real-DB test. A green suite over mocks is not evidence.

---

### 2026-07-13 16:30

#### Title

Saga events diverge from the contract at every stage — compensation is a no-op

#### Agent

Not recorded (same unlogged session, commits `0993a04` and `6086f5b`; see note).

#### Context

Orders' four stage consumers publish the saga's events via the outbox. The
contract (§2) fixes topic names (`eurotransit.*`) and payload fields
(`event_id`, `event_timestamp`, `reservation_id`, `user_id`, `amount`,
`currency`, `user_email`, `reason`).

#### Incorrect Suggestion

Stages 1–4 write outbox rows with **bare topic names** (`"inventory-reserved"`,
`"order-failed"`, `"payment-authorized"`, `"payment-failed"`,
`"order-confirmed"`) and payloads of only `{order_id, status|reason}`. Stage 1
receives `reservation_id` from Inventory's response and discards it.

#### Why It Was Wrong

- The `eurotransit.`-prefixed topics that Strimzi provisions and that
  Inventory/Notifications/Orders' own listeners subscribe to never receive
  these events: the saga publishes into auto-created topics nobody consumes and
  stalls after Stage 1.
- `order-failed` carries no `reservation_id`, so even with topics fixed,
  Inventory's compensation early-returns: **reserved seats are never released
  on payment failure** — the exact money-path invariant the saga exists for.
- No `event_id` anywhere, yet Stages 2–4 read `event["event_id"].asText()`
  (NPE) and Notifications' DTOs declare `user_email` non-nullable (throws on
  every event).
- Ironic detail: commit `6086f5b` is titled "align order events with contract"
  and still ships none of the contract's fields.

#### How It Was Detected

Phase 2 review, cross-checking `eurotransit-contract.md` §2 against
`Stage1..4Consumer` and the Strimzi `KafkaTopic` CRs. No test could catch it:
consumer tests mock everything and no end-to-end path exists yet.

#### Correct Solution

Pending (Orders owner): publish to `app.kafka.topics.*` values instead of
string literals, and build payloads from the contract's schemas — carrying
`reservation_id` through Stage 1 → Stage 2 → Stage 4 (requires persisting it,
see the persistence entry above).

#### Lesson Learned

Topic names and payload schemas must come from configuration/contract, never
retyped inline. A commit that claims contract alignment needs a test that
asserts it — payload golden tests against the contract's JSON examples.

---

### 2026-07-13 16:30

#### Title

Hand-built Jackson bean silently disables the snake_case wire format

#### Agent

Not recorded (same unlogged session; see note).

#### Context

Orders serializes `OrderPlacedEvent` into the outbox with the application's
`ObjectMapper`. `application.yaml` sets
`spring.jackson.property-naming-strategy: SNAKE_CASE`.

#### Incorrect Suggestion

`JacksonConfig` declares `@Bean fun objectMapper() = jacksonObjectMapper()` — a
bare mapper that replaces Spring Boot's auto-configured one.

#### Why It Was Wrong

The yaml naming strategy only applies to Boot's auto-configured mapper; the
hand-built bean ignores it. `OrderPlacedEvent` has no `@JsonProperty`
annotations, so `order-placed` goes out camelCase (`eventId`, `orderId`,
`trainId`) while Stage 1 — in the same service — reads `event["event_id"]`,
`event["train_id"]`: null → NPE on the very first event of every order.

#### How It Was Detected

Phase 2 review, tracing one `order-placed` event from `OrderServiceImpl`
serialization to `Stage1Consumer` field access.

#### Correct Solution

Pending (Orders owner): delete the redundant bean (Boot's mapper + yaml already
does everything needed), or annotate every event DTO with `@JsonProperty` as
the other services do.

#### Lesson Learned

Never hand-declare beans the framework already provides unless overriding is
the point — a bare replacement silently discards every yaml customization. A
serialize→deserialize round-trip test per event type would have caught it.

---

### 2026-07-13 16:30

#### Title

Circuit-breaker fallback swallows legitimate card declines in Orders

#### Agent

Not recorded (commit `0993a04` family; see note).

#### Context

`PaymentClient.authorizePayment` wraps Orders→Payments in
`@CircuitBreaker(name = "payments-client", fallbackMethod = "fallbackPayment")`.
Payments answers a legitimate decline with HTTP 402 per contract §1.5.

#### Incorrect Suggestion

The 402 is not handled: `awaitBody` throws `WebClientResponseException` for it,
and the catch-all fallback turns **every** throwable into
`DECLINED / payment_system_unavailable`. Stage 2 then hardcodes the reason to
`PAYMENT_REJECTED` in `payment-failed`.

#### Why It Was Wrong

Two distinct failure modes the architecture deliberately separates get merged:

- A genuinely declined card is reported as a platform outage, and the
  contract's `reason` (`insufficient_funds` vs `circuit_breaker_open`) — which
  §2.4 says feeds dashboards — is erased twice before reaching Kafka.
- Worse, each legitimate decline **counts as a circuit-breaker failure**: a
  burst of declined cards opens the Orders→Payments breaker and blocks payments
  for everyone — customers with valid cards included. A resilience mechanism
  turned into a denial-of-service amplifier.

#### How It Was Detected

Phase 2 review of the Payments idempotency work: while tracing what a replayed
402 looks like to Orders, the fallback's catch-all signature made the
conflation visible. `PaymentClientTest` never exercises a 402.

#### Correct Solution

Partially landed (2026-07-15 PR). `PaymentClient` now catches the 402 *inside*
the breaker block, treats it as a successful call carrying its real `reason`, and
reserves the fallback for transport errors / open-breaker only — so declines no
longer trip the breaker (the DoS-amplifier is gone) and the real reason reaches
the client boundary. Still open (Orders owner, tangled with entry #2's
off-contract events): `Stage2Consumer` hardcodes `reason = "PAYMENT_REJECTED"`
into the `payment-failed` event, so the propagated reason is still erased before
it reaches Kafka/dashboards.

#### Lesson Learned

An HTTP error status can be a valid business answer. Circuit breakers must
count infrastructure failures, not domain outcomes — `recordExceptions` /
explicit handling of expected statuses, and a test for the "declined but
healthy" path.
