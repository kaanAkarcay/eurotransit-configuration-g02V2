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

- [x] Consistency model documented in CAP/PACELC terms — strong consistency scoped to `seats.available` (PC/EC: refuse writes under partition, always hit the primary otherwise), with the saga eventually consistent around it and Catalog's availability a deliberately stale, display-only projection outside the authoritative boundary (not a CAP choice: it is wrong with no partition at all). See `consistency-validation.md` §1
- [x] Atomic reservation in PostgreSQL: UPDATE seats SET available = available - :qty WHERE available >= :qty
- [x] "Never oversell" invariant holds under concurrent requests — proven over real HTTP at 10-on-5 and 50-on-20 (`InventoryReserveTest`)
- [x] Idempotency level 1 (REST, frontend): processed_requests table in Orders, keyed on the client's idempotency_key, claimed with INSERT ... ON CONFLICT DO NOTHING in the same transaction as the order and its order-placed outbox row — race-free under concurrent duplicates (`consistency-validation.md` §2.1, §2.4)
- [x] Idempotency level 2 (REST, internal): processed_requests table in Inventory and Payments, keyed on order_id, protecting Orders' retries on POST /reserve and POST /authorize from double-reserving or double-charging. Note the retries themselves are currently inert — see `consistency-validation.md` §4; the dedup is what makes restoring them safe
- [x] Idempotency level 3 (Kafka): processed_events table in every **state-changing** Kafka consumer on the money path — Orders' four stage consumers plus Inventory's order-failed consumer — keyed on event_id, claimed with INSERT ... ON CONFLICT DO NOTHING in the same DB transaction as the business logic it guards (`consistency-validation.md` §3). Scope matches architecture-design.md §2 ("Notifications needs no durable dedup") and contract §3.2, which requires the table for "every one of *these* consumers" and does not list Notifications. Notifications is therefore deliberately at-least-once and can send a duplicate email; that exclusion is an accepted risk with a stated trigger to revisit it, not an omission (`consistency-validation.md` §3.3, §4)
- [x] Outbox pattern used for Orders' DB-write-then-Kafka-publish step at every stage transition (Inventory and Payments need no outbox — they never publish to Kafka): event written to Orders' own outbox table in the same transaction as the business write; a polling relay publishes to Kafka and marks rows sent, using SELECT ... FOR UPDATE SKIP LOCKED so multiple replicas never double-publish the same row
- [x] Compensation path: order-failed (with reservation_id) triggers Inventory to release the reservation — Stage 4 propagates reservation_id and reason to the final event, and Inventory releases exactly once (`OrdersCompensationPathTest`, `OrderFailedConsumerDedupTest`)
- [ ] Demonstrated under chaos: oversell does not occur when messages are duplicated or a pod dies mid-reservation — also the only thing that would demonstrate the PC half of PC/EC (`consistency-validation.md` §4)

## Pillar C: Resilience engineering

- [ ] Circuit breaker on Orders → Payments sync call (the brief's named example), with defined open/half-open policy and explicit fallback (treat as declined); same treatment (timeout + bounded retry, circuit breaker) on Orders → Inventory; a third, independent circuit breaker on Payments → external gateway, since that's a separate failure mode from Orders → Payments
- [ ] Bulkhead: isolated connection pools for each downstream service (Orders→Inventory, Orders→Payments, Payments→gateway)
- [ ] Timeout + exponential backoff + jitter on every remote call
- [ ] Backpressure / load shedding: HTTP 429 when overloaded
- [ ] Graceful degradation: Notifications can be completely down without affecting checkout
- [ ] Liveness probes do NOT check downstream dependencies
- [ ] Readiness probes reflect actual ability to serve traffic
- [ ] PodDisruptionBudget for critical-path services, sized against the actual replica count so it permits at least one voluntary disruption (`minAvailable: 1` requires replicas >= 2). A PDB reporting `ALLOWED DISRUPTIONS = 0` blocks node drains without protecting availability, so the objects existing is not the bar; prove this with an approved node-drain test (see `docs/resilience/critical-service-pdbs.md`)
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
