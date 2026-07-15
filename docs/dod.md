# EuroTransit — Definition of Done

> This is a living document. Update it as the project evolves.
> Last updated: 2026-07-08

## Pillar A: Distributed design and asynchronous execution

- [ ] Service decomposition documented with sync/async boundaries and justification for each
- [ ] POST /api/v1/orders returns 202 PENDING immediately; pipeline proceeds via Kafka
- [ ] 6 Kafka topics operational, all produced and mostly self-consumed by Orders across its four internal stages: order-placed, inventory-reserved, payment-authorized, payment-failed, order-confirmed, order-failed
- [ ] Every Kafka event payload includes `event_id` for deduplication and `event_timestamp` as the UTC producer-created timestamp
- [ ] Order pipeline uses Kotlin coroutines / Flows for async processing
- [ ] Structured concurrency: each Kafka consumer runs in a CoroutineScope as a failure domain
- [ ] Cooperative cancellation on SIGTERM: in-flight work finishes or is cleanly cancelled, no orphaned tasks, no double-processing
- [ ] Readiness probe flips to "refusing traffic" while draining in-flight work
- [ ] Written analysis in docs/: where async reduces cost/scaling in EuroTransit, where it would not help (CPU-bound work)

## Pillar B: Consistency under contention

- [x] Consistency model documented in CAP/PACELC terms (PC/EC: reject writes under partition, strong consistency via primary in normal operation) — see `consistency-validation.md` §1
- [x] Atomic reservation in PostgreSQL: UPDATE seats SET available = available - :qty WHERE available >= :qty
- [x] "Never oversell" invariant holds under concurrent requests — proven over real HTTP at 10-on-5 and 50-on-20 (`InventoryReserveTest`)
- [ ] Idempotency level 1 (REST, frontend): processed_requests table in Orders, keyed on the client's idempotency_key
- [x] Idempotency level 2 (REST, internal): processed_requests table in Inventory and Payments, keyed on order_id, protecting Orders' bounded retries on POST /reserve and POST /authorize from double-reserving or double-charging
- [ ] Idempotency level 3 (Kafka): processed_events table in every Kafka consumer (Orders consuming its own order-placed/inventory-reserved/payment-authorized/payment-failed across its four stages, plus Inventory consuming order-failed), keyed on event_id, checked in the same DB transaction as business logic — Inventory's consumer is done and tested. Orders' four stages have the table and the code, but `processedEventRepo.save(...)` writes nothing: `ProcessedEvent` has a non-null `String` `@Id`, so Spring Data R2DBC issues an UPDATE that silently affects 0 rows. `existsById` is therefore always false and the dedup never fires. Blocked on Orders (`consistency-validation.md` §4)
- [ ] Outbox pattern used for Orders' DB-write-then-Kafka-publish step at every stage transition (Inventory and Payments need no outbox — they never publish to Kafka): event written to Orders' own outbox table in the same transaction as the business write; a polling relay publishes to Kafka and marks rows sent, using SELECT ... FOR UPDATE SKIP LOCKED so multiple replicas never double-publish the same row
- [ ] Compensation path: order-failed (with reservation_id) triggers Inventory to release reservation — Inventory's consumer is implemented and tested, but Orders publishes `order-failed` to a bare topic name (no `eurotransit.` prefix) with no `reservation_id` in the payload, so nothing reaches it. Blocked on Orders (`consistency-validation.md` §4)
- [ ] Demonstrated under chaos: oversell does not occur when messages are duplicated or a pod dies mid-reservation

## Pillar C: Resilience engineering

- [ ] Circuit breaker on Orders → Payments sync call (the brief's named example), with defined open/half-open policy and explicit fallback (treat as declined); same treatment (timeout + bounded retry, circuit breaker) on Orders → Inventory; a third, independent circuit breaker on Payments → external gateway, since that's a separate failure mode from Orders → Payments
- [ ] Bulkhead: isolated connection pools for each downstream service (Orders→Inventory, Orders→Payments, Payments→gateway)
- [ ] Timeout + exponential backoff + jitter on every remote call
- [ ] Backpressure / load shedding: HTTP 429 when overloaded
- [ ] Graceful degradation: Notifications can be completely down without affecting checkout
- [ ] Liveness probes do NOT check downstream dependencies
- [ ] Readiness probes reflect actual ability to serve traffic
- [ ] PodDisruptionBudget with minAvailable >= 1 for critical-path services
- [ ] HPA configured for at least one service with a meaningful scaling metric

## Pillar D: Delivery, observability, and proof

- [ ] GitOps: CI builds + pushes images, updates config repo; Argo CD deploys. CI has no cluster credentials
- [ ] Canary deployment via TraefikService (partial traffic split, observe SLI, promote or abort)
- [ ] Blue/green deployment (traffic switch, rollback capability)
- [ ] Written discussion: where all-at-once and rolling deployment would apply and why not used on the critical path
- [ ] RED dashboard per service (Rate, Errors, Duration)
- [ ] USE / Golden Signals dashboard for infrastructure
- [ ] SLO: 99% of checkouts complete under 800ms in 5-min window (latency)
- [ ] SLO: 99.5% of POST /orders return non-5xx in 5-min window (availability)
- [ ] SLO: 99% of PENDING orders reach terminal state within 30s (pipeline completion)
- [ ] Alerts based on burn-rate, not raw thresholds
- [ ] Distributed tracing across the money path (request → Orders → Inventory/Payments → Kafka → Notifications)

## Authentication (Keycloak)

- [ ] Keycloak deployed as a Pod in the eurotransit namespace, acting as OIDC provider / JWT issuer
- [ ] Distributed JWT validation (pattern B): each Spring Boot service validates Bearer tokens locally via spring-boot-starter-oauth2-resource-server against Keycloak's JWKS endpoint; no authentication step at the gateway
- [ ] Public API endpoints (POST /api/v1/orders, GET /api/v1/catalog/products) reject requests without a valid JWT (401 Unauthorized)
- [ ] Frontend authenticates users against Keycloak (OIDC) and attaches the resulting Bearer token to its API calls

## Chaos experiments

Each experiment produces: hypothesis, steady-state definition, observations from dashboards, whether hypothesis held, what was changed if not.

- [ ] Experiment 1 — Latency injection on Payments: does the circuit breaker open? Does Catalog remain healthy?
- [ ] Experiment 2 — Pod kill on Inventory mid-reservation: does idempotency hold? No oversell or double-charge?
- [ ] Experiment 3 — Node/AZ disruption: do PDB and topology spread keep the critical path available?
- [ ] Experiment 4 — Kafka disruption / network partition: does the async pipeline recover? No lost or duplicated messages?
- [ ] Experiment 5 — CloudNativePG primary failover: what is the impact on checkout? Does recovery happen within stated RTO?

## Agentic coding

- [ ] `docs/ai-logs.md` records significant AI-assisted sessions
- [ ] `docs/ai-mistake-log.md` records at least 3 concrete cases where an agent-produced artifact was incorrect, unsafe, or subtly wrong, and how the team caught and corrected it
- [ ] Agent threat-model paragraph in docs/: what credentials the agent has, whether changes require human review before merge, worst case if it proposes a bad change
- [ ] Agent changes do not merge to config repo without review (blast radius control)

## Deliverables checklist

- [ ] Application repo with source, tests, CI workflows, justfile
- [ ] Configuration repo with Helm charts, Argo CD Application, platform config, SealedSecrets
- [ ] Git history shows GitOps-driven delivery (not manual kubectl apply)
- [ ] docs/: DoD, design justification, consistency justification, SLO definitions, 5 chaos reports, postmortem, agent threat-model, ai-logs.md, ai-mistake-log.md
- [ ] Recorded demo (~5 min): running system, dashboards answering operational questions, canary deployment, blue/green deployment, at least one alert firing under injected failure
- [ ] Live presentation scheduled with Prof. Malnati
- [ ] Blameless postmortem written after the live incident injection
