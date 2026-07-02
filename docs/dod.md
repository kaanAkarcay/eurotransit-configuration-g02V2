# EuroTransit — Definition of Done

> This is a living document. Update it as the project evolves.
> Last updated: YYYY-MM-DD

## Pillar A: Distributed design and asynchronous execution

- [ ] Service decomposition documented with sync/async boundaries and justification for each
- [ ] POST /api/v1/orders returns 202 PENDING immediately; pipeline proceeds via Kafka
- [ ] 5 Kafka topics operational: order-placed, inventory-reserved, inventory-reservation-failed, order-confirmed, order-failed
- [ ] Order pipeline uses Kotlin coroutines / Flows for async processing
- [ ] Structured concurrency: each Kafka consumer runs in a CoroutineScope as a failure domain
- [ ] Cooperative cancellation on SIGTERM: in-flight work finishes or is cleanly cancelled, no orphaned tasks, no double-processing
- [ ] Readiness probe flips to "refusing traffic" while draining in-flight work
- [ ] Written analysis in docs/: where async reduces cost/scaling in EuroTransit, where it would not help (CPU-bound work)

## Pillar B: Consistency under contention

- [ ] Consistency model documented in CAP/PACELC terms (PC/EC: reject writes under partition, strong consistency via primary in normal operation)
- [ ] Atomic reservation in PostgreSQL: UPDATE seats SET available = available - :qty WHERE available >= :qty
- [ ] "Never oversell" invariant holds under concurrent requests
- [ ] Idempotency level 1 (REST): processed_requests table in Orders, keyed on frontend idempotency_key
- [ ] Idempotency level 2 (Kafka): processed_events table in each consuming service, keyed on event_id, checked in the same DB transaction as business logic
- [ ] Compensation path: order-failed triggers Inventory to release reservation
- [ ] Demonstrated under chaos: oversell does not occur when messages are duplicated or a pod dies mid-reservation

## Pillar C: Resilience engineering

- [ ] Circuit breaker on Orders → Payments sync call, with defined open/half-open policy and explicit fallback
- [ ] Bulkhead: isolated connection pools for each downstream service
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

## Chaos experiments

Each experiment produces: hypothesis, steady-state definition, observations from dashboards, whether hypothesis held, what was changed if not.

- [ ] Experiment 1 — Latency injection on Payments: does the circuit breaker open? Does Catalog remain healthy?
- [ ] Experiment 2 — Pod kill on Inventory mid-reservation: does idempotency hold? No oversell or double-charge?
- [ ] Experiment 3 — Node/AZ disruption: do PDB and topology spread keep the critical path available?
- [ ] Experiment 4 — Kafka disruption / network partition: does the async pipeline recover? No lost or duplicated messages?
- [ ] Experiment 5 — CloudNativePG primary failover: what is the impact on checkout? Does recovery happen within stated RTO?

## Agentic coding

- [ ] docs/agent-log.md with at least 3 concrete cases where an agent-produced artifact was incorrect, unsafe, or subtly wrong, and how the team caught and corrected it
- [ ] Agent threat-model paragraph in docs/: what credentials the agent has, whether changes require human review before merge, worst case if it proposes a bad change
- [ ] Agent changes do not merge to config repo without review (blast radius control)

## Deliverables checklist

- [ ] Application repo with source, tests, CI workflows, justfile
- [ ] Configuration repo with Helm charts, Argo CD Application, platform config, SealedSecrets
- [ ] Git history shows GitOps-driven delivery (not manual kubectl apply)
- [ ] docs/: DoD, design justification, consistency justification, SLO definitions, 5 chaos reports, postmortem, agent threat-model, agent-log.md
- [ ] Recorded demo (~5 min): running system, dashboards answering operational questions, canary deployment, blue/green deployment, at least one alert firing under injected failure
- [ ] Live presentation scheduled with Prof. Malnati
- [ ] Blameless postmortem written after the live incident injection