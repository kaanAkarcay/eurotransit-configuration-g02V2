# EuroTransit Probe Resilience Review

## Resilience Owner Objective

As Resilience Owner, I reviewed the Kubernetes probe configuration to verify
that dependency failures are not amplified into unnecessary pod restarts and
cascading instability on the EuroTransit critical path.

Critical resilience invariant:

A downstream or infrastructure dependency failure must not be misclassified as
application process death.

This review focuses on failure amplification, blast radius, and recovery
evidence. It does not treat the mere presence of Kubernetes probes as sufficient
resilience proof.

## Current Architecture Baseline Used

The project documentation describes the target resilience architecture. The
actual configuration and application repositories currently implement only part
of that target.

For this review, I use the following baseline:

- Target architecture source: `docs/architecture-design.md`,
  `docs/eurotransit-contract.md`, `docs/dod.md`, and
  `docs/chaos-experiment-hypotheses.md`.
- Current repository state source: Helm chart under `deploy/charts/eurotransit`
  and application modules under
  `/Users/srbuhidanielyan/IdeaProjects/eurotransit-application-g02`.
- Probe defect source of truth: current Helm probe paths compared with current
  Spring Boot application dependencies and health configuration.

Target architecture assumptions remain relevant to the Resilience Owner scope,
but they are not treated as implemented runtime evidence unless supported by the
current application/configuration repositories.

## Critical Path and Failure Boundaries Reviewed

- Orders -> Inventory:
  Documented target boundary. Inventory latency or unavailability must not make
  Orders liveness fail. Current application evidence does not show an
  Orders-to-Inventory client or Inventory reservation endpoint implementation.
- Orders -> Payments:
  Implemented partial boundary. Orders has a `PaymentClient` using WebClient and
  a Resilience4j circuit breaker for `payments-client`. Payments unavailability
  must not trigger Orders restart churn.
- Payments -> external gateway:
  Documented target boundary. Current application evidence does not show an
  external payment gateway client in Payments, so runtime validation of this
  edge is not currently executable.
- Orders / Kafka:
  Implemented partial boundary. Orders publishes `eurotransit.order-placed` and
  consumes `eurotransit.inventory-reserved` and
  `eurotransit.inventory-reservation-failed`. The documented six-topic
  multi-stage flow is not fully implemented in the inspected application repo.
- Service -> own database:
  Implemented partial boundary. Orders has R2DBC configuration. Inventory and
  Payments include R2DBC dependencies but only minimal application code was
  found. The configuration repository now contains four platform CNPG Cluster
  manifests, but the Helm workload templates still inject the older
  chart-managed database endpoint.
- Services -> Keycloak/JWKS:
  Documented target boundary. Current application evidence does not show
  `spring-boot-starter-oauth2-resource-server` or JWKS issuer configuration.

## What I Inspected

Configuration repository:

- `deploy/charts/eurotransit/values.yaml`
- `deploy/charts/eurotransit/Chart.yaml`
- `deploy/charts/eurotransit/templates/catalog-deployment.yaml`
- `deploy/charts/eurotransit/templates/orders-deployment.yaml`
- `deploy/charts/eurotransit/templates/inventory-deployment.yaml`
- `deploy/charts/eurotransit/templates/payments-deployment.yaml`
- `deploy/charts/eurotransit/templates/notifications-deployment.yaml`
- `deploy/charts/eurotransit/templates/_helpers.tpl`
- rendered Helm output from `helm template eurotransit deploy/charts/eurotransit --namespace eurotransit`

Application repository:

- `catalog/build.gradle.kts`
- `orders/build.gradle.kts`
- `inventory/build.gradle.kts`
- `payments/build.gradle.kts`
- `notifications/build.gradle.kts`
- `catalog/src/main/resources/application.yaml`
- `orders/src/main/resources/application.yaml`
- `inventory/src/main/resources/application.yaml`
- `payments/src/main/resources/application.yaml`
- `notifications/src/main/resources/application.yaml`
- `orders/src/main/kotlin/.../OrderService.kt`
- `orders/src/main/kotlin/.../OrderConsumer.kt`
- `orders/src/main/kotlin/.../PaymentClient.kt`
- Spring Boot Actuator dependency and health configuration search
- health group configuration search
- custom `HealthIndicator` / `ReactiveHealthIndicator` search

Project documentation:

- `docs/ai-guidelines.md`
- `docs/ai-logs.md`
- `docs/architecture-design.md`
- `docs/eurotransit-contract.md`
- `docs/dod.md`
- `docs/chaos-experiment-hypotheses.md`
- `docs/resilience/probe-review.md`

## Documentation Comparison Matrix

| Document | Architecture assumptions | Resilience assumptions | Relevant to probe review? | Freshness status | Conflict found |
|---|---|---|---|---|---|
| `docs/ai-guidelines.md` | Defines document hierarchy and requires inconsistencies to be reported before relying on assumptions. | Requires verification, minimal blast radius, and logging of significant AI sessions. | Yes. Governs how conflicting docs and repo state are handled. | Current for process rules. | Mentions `docs/ai-mistake-log.md`, while prior project state uses `docs/ai-logs.md` and `docs/dod.md` mentions `docs/agent-log.md`. |
| `docs/ai-logs.md` | Records prior decisions: Catalog DB and Keycloak were added to architecture docs; Chaos Mesh was added as GitOps prerequisite. | Notes known risks that implementation/manifests for Catalog DB and Keycloak are not complete. | Yes. Confirms that some architecture docs are ahead of implementation. | Current as project history. | Confirms docs/application drift rather than resolving it. |
| `docs/architecture-design.md` | Target architecture: five backend services, six Kafka topics, Orders as four-stage Kafka-driven orchestrator, Orders->Inventory, Orders->Payments, Payments->gateway, Keycloak, Strimzi, four CNPG clusters. | Liveness/readiness, service ownership, database-per-service, graceful degradation for Notifications, Chaos Mesh fault-injection target. | Yes. Defines target probe invariants. | Partially stale relative to current repos. | Config repo now has Strimzi and four CNPG platform manifests, but application Helm DB wiring still points at the chart-managed cluster endpoint and no Keycloak manifests were found; app repo does not implement full six-topic pipeline or Actuator. |
| `docs/eurotransit-contract.md` | Target contract v3: six topics, Orders writes outbox, Stage 1 calls Inventory, Stage 2 calls Payments, payment-authorized/payment-failed drive later stages. | Circuit breaker on Orders->Payments, Payments->gateway circuit breaker, Kafka recovery through outbox, no Kafka in request path. | Yes. Defines intended critical-path dependencies and failure boundaries. | Partially stale relative to current app repo. | App repo publishes `order-placed` directly, has no outbox implementation found, consumes `inventory-reserved` and `inventory-reservation-failed`, and does not show `payment-authorized` or `payment-failed`. |
| `docs/dod.md` | Target DoD: six Kafka topics, outbox, Inventory/Payments idempotency, Keycloak auth, GitOps, observability. | Explicitly requires liveness probes not to check downstream dependencies and readiness to reflect ability to serve traffic. | Yes. Directly relevant to probe review. | Current as acceptance criteria; partially ahead of implementation. | DoD expects operational topics and resilience mechanisms not fully present in current app/config repos. |
| `docs/chaos-experiment-hypotheses.md` | Target chaos plan: Payments latency, Inventory pod kill, node disruption, Kafka partition, CNPG failover. | Validates circuit breakers, no oversell, no Kafka loss, no manual restart after recovery, Catalog isolation. | Yes. Defines runtime tests that probe review must support. | Partially stale relative to current repos. | Experiments assume deployed Strimzi, Chaos Mesh, CNPG failover topology, Orders->Inventory, and outbox behaviour not currently present in inspected repos/cluster. |
| `docs/resilience/probe-review.md` | Owner artifact for probe resilience; now separates target architecture from current repository evidence. | Focuses on failure amplification through liveness/readiness/startup probes. | Yes. This is the reviewed artifact. | Current after this audit. | Prior wording treated some target edges as implemented; this version marks them as documented target boundaries when app evidence is missing. |

## Resilience Review Matrix

| Service | Failure I am protecting against | Current liveness behaviour | Current readiness behaviour | Resilience risk | Owner action |
|---|---|---|---|---|---|
| Orders | Implemented: Payments/Kafka/DB outage being amplified into Orders restart loops. Documented target but not implemented: Inventory and Keycloak/JWKS. | Helm calls `/actuator/health/liveness`; inspected app repo does not provide Actuator or a custom endpoint. | Helm calls `/actuator/health/readiness`; inspected app repo does not provide Actuator or a custom endpoint. | Critical path service may restart because the configured probe endpoint is absent. Dependency-specific semantics cannot be validated until endpoints exist. | Fix Actuator health group; runtime verification required for implemented Payments/Kafka/DB edges; team confirmation required before treating Inventory/Keycloak edges as executable tests. |
| Inventory | Documented target: database/Kafka disruption during reservation or compensation flows. Current app evidence: R2DBC/Kafka dependencies exist, but no reservation/compensation implementation found. | Helm calls `/actuator/health/liveness`; inspected app repo does not provide Actuator or a custom endpoint. | Helm calls `/actuator/health/readiness`; inspected app repo does not provide Actuator or a custom endpoint. | Inventory can restart because the probe endpoint is absent; documented reservation semantics cannot be validated against current code. | Fix Actuator health group; runtime verification required after Inventory business flow exists. |
| Payments | Documented target: external gateway degradation. Current app evidence: R2DBC/Kafka dependencies exist, but no external gateway client implementation found. | Helm calls `/actuator/health/liveness`; inspected app repo does not provide Actuator or a custom endpoint. | Helm calls `/actuator/health/readiness`; inspected app repo does not provide Actuator or a custom endpoint. | Payment gateway failure isolation cannot be proven from current code; probe endpoint absence can cause restart churn regardless of gateway state. | Fix Actuator health group; runtime verification required after Payments endpoint/gateway behaviour exists. |
| Catalog | Documented target: Catalog remains isolated from checkout failures and owns catalog-db. Current app evidence: no DB dependency/config found in Catalog module. | Helm calls `/actuator/health/liveness`; inspected app repo does not provide Actuator or a custom endpoint. | Helm calls `/actuator/health/readiness`; inspected app repo does not provide Actuator or a custom endpoint. | Catalog independence cannot be proven from probes because the endpoint is absent; catalog-db dependency is documented but not implemented in app code. | Fix Actuator health group; confirm Catalog DB implementation scope before DB readiness tests. |
| Notifications | Kafka outage causing restart churn even though Notifications is non-critical to checkout. Current app evidence: Kafka dependency exists, but no listener implementation found. | Helm calls `/actuator/health/liveness`; inspected app repo does not provide Actuator or a custom endpoint. | Helm calls `/actuator/health/readiness`; inspected app repo does not provide Actuator or a custom endpoint. | Non-critical async service may restart repeatedly because the probe endpoint is absent; Kafka graceful-degradation behaviour cannot yet be validated. | Fix Actuator health group; runtime verification required after notification consumer exists. |

## Verified Resilience Findings

### RES-PROBE-001 — Probe endpoints are configured in Helm but not provided by the inspected applications

Resilience property at risk:

Dependency failures and process health cannot be separated because the configured
probe endpoints are absent in the inspected application configuration.

Failure scenario:

Backend pod starts
-> Kubernetes calls `/actuator/health/liveness`
-> application does not provide the endpoint
-> startup or liveness probe fails
-> Kubernetes restarts the pod
-> restart repeats independently of real process health
-> service instability blocks later dependency-failure validation.

Amplification path:

Payments unavailable, Kafka unavailable, database unavailable, or another
documented dependency unavailable
-> Resilience Owner expects service-specific degradation
-> probe endpoint absence prevents verifying correct degradation
-> Kubernetes may restart the service before downstream failure behaviour can be
measured
-> failure domain expands from dependency outage to service restart churn.

Repository evidence:

- `deploy/charts/eurotransit/templates/orders-deployment.yaml`
- `deploy/charts/eurotransit/templates/inventory-deployment.yaml`
- `deploy/charts/eurotransit/templates/payments-deployment.yaml`
- `deploy/charts/eurotransit/templates/catalog-deployment.yaml`
- `deploy/charts/eurotransit/templates/notifications-deployment.yaml`
- Rendered Helm output configures:
  - liveness path: `/actuator/health/liveness`
  - readiness path: `/actuator/health/readiness`
  - startup path: `/actuator/health/liveness`
- Application repository search found no `spring-boot-starter-actuator`.
- Application repository search found no `management.endpoint.health`,
  `management.health`, `livenessState`, `readinessState`, custom
  `HealthIndicator`, custom `ReactiveHealthIndicator`, or custom
  `/actuator/health` implementation in the inspected service modules.

Impact on critical path:

Orders is part of the implemented checkout entry path and currently has Kafka,
database, and Payments dependencies. If its probe endpoint is absent, the
platform may restart Orders regardless of whether the process is recoverable.
This blocks validation of the intended timeout, circuit-breaker, Kafka recovery,
database recovery, and future Inventory/Keycloak behaviour.

Severity:

Critical

Resilience Owner decision:

The current static probe configuration is not acceptable for resilience
validation. The probe paths must either be backed by implemented Actuator
endpoints with explicit health groups or changed to implemented endpoints with
equivalent semantics.

Required action:

Implement service probe endpoints in the application repository. The preferred
minimal action is to add Spring Boot Actuator to each backend module and define
health groups so liveness remains process-local while readiness is
service-specific.

Validation required after fix:

- Render Helm and confirm paths still match implemented endpoints.
- Deploy workloads.
- Verify liveness stays healthy during implemented dependency failures.
- Verify readiness transitions and recovery without manual pod restart.
- Add additional runtime tests as target architecture edges are implemented.

Status:

- Open
- Runtime validation required

### RES-PROBE-002 — Probe review target edges exceed the currently implemented application architecture

Resilience property at risk:

Runtime validation could be planned against failure boundaries that are only
documented targets, not current executable paths.

Failure scenario:

Probe review assumes Orders->Inventory, Payments->external gateway,
Keycloak/JWKS, outbox relay, and the full six-topic Kafka pipeline are
implemented
-> fault injection is planned for those edges
-> live test cannot execute or validates the wrong path
-> probe resilience task is closed without evidence for the actual running
system.

Amplification path:

Stale assumption
-> wrong fault target
-> missing evidence
-> unresolved probe risk remains hidden.

Repository evidence:

- Target docs describe six Kafka topics:
  `order-placed`, `inventory-reserved`, `payment-authorized`, `payment-failed`,
  `order-confirmed`, and `order-failed`.
- Current Orders application configuration lists
  `order-placed`, `order-confirmed`, `order-failed`, `inventory-reserved`, and
  `inventory-reservation-failed`.
- Current Orders code publishes `eurotransit.order-placed` directly from
  `OrderService`.
- Current Orders code consumes `eurotransit.inventory-reserved` and
  `eurotransit.inventory-reservation-failed`.
- Current Orders code calls Payments through `PaymentClient`.
- Current application search found no Orders->Inventory client, no
  `payment-authorized` or `payment-failed` topic usage, no outbox relay
  implementation, no Payments external gateway client, and no Keycloak/JWKS
  resource-server configuration.
- Current config repo has explicit platform manifests for the four target CNPG
  clusters, while the Helm workload templates still inject the older
  chart-managed `{{ .Release.Name }}-cluster-rw` endpoint.

Impact on critical path:

The probe-review artifact remains relevant, but runtime validation must be
aligned to the actual deployed implementation. Target-architecture tests remain
blocked or pending implementation until the corresponding code and platform
components exist.

Severity:

High

Resilience Owner decision:

Keep the target failure boundaries visible, but do not present them as verified
or executable current runtime tests. Split validation work into current
repository-supported tests and target-architecture tests requiring team
confirmation or implementation.

Required action:

Before running chaos or recovery validation, confirm which architecture baseline
is being deployed: current partial implementation or target v3 architecture.
Update fault targets and pass/fail criteria accordingly.

Validation required after fix:

- Confirm implemented Kafka topic set in the deployed application.
- Confirm Orders->Inventory and Payments->gateway paths before injecting faults
  on those edges.
- Confirm database topology before CNPG failover testing.
- Confirm Keycloak/JWKS integration before auth dependency probe tests.

Status:

- Open
- Blocked pending architecture/team confirmation
- Runtime validation required

## Static Changes Owned by Resilience

### Change 1

Problem being prevented:

Loss of review traceability for probe configuration defects that can amplify
dependency failures into restart churn.

File changed:

- `docs/resilience/probe-review.md`

Decision:

Maintain a persistent Resilience Owner review artifact with verified repository
evidence, current blocker status, cross-document relevance audit, and runtime
validation backlog.

Why this is the minimum justified fix:

The static review found that the functional probe fix belongs in the
application repository, not in the configuration repository probe paths alone.
This document records the defect and closure criteria without changing
unrelated infrastructure.

Expected resilience effect:

The team has a concrete owner-facing checklist for resolving the probe defect
and proving that dependency failures do not become Kubernetes restart loops.

Runtime proof still required:

Yes. No EuroTransit workloads are currently deployed in Lab02Cluster.

### Change 2

Problem being prevented:

Loss of AI-assisted review traceability required by project guidelines.

File changed:

- `docs/ai-logs.md`

Decision:

Record the static probe review session and its runtime boundary.

Why this is the minimum justified fix:

Project rules require significant AI-assisted sessions to be logged. The change
does not modify application or infrastructure behaviour.

Expected resilience effect:

Maintains auditability of the identified probe risk and the fact that runtime
validation remains blocked.

Runtime proof still required:

Yes. The log entry is traceability only.

## Current Blockers

BLOCKED — deployment/runtime dependency unavailable at the time of review.

Lab02Cluster did not contain the EuroTransit workloads or required platform
components during the original live check. The live cluster check showed only
system namespaces and system workloads; `eurotransit`, `argocd`, Kafka/Strimzi,
CNPG, Chaos Mesh, and observability components were not present at review time.

Blocked resilience validations:

- downstream failure vs liveness behaviour;
- pod restart count observation during dependency failures;
- dependency recovery without manual pod restart;
- Chaos Mesh fault injection;
- runtime readiness transitions;
- circuit-breaker and probe interaction evidence;
- Kafka outage behaviour under live consumers/producers.

These items are not marked failed. They remain blocked until deployment exists.

## Resilience Validation Backlog

| Validation ID | Fault injected | Property being validated | Evidence | PASS criterion | Related task | Current executable status |
|---|---|---|---|---|---|---|
| RV-001 | Payments unavailable | Orders remains alive; Orders payment circuit breaker handles failure. | Orders restart count, Orders liveness endpoint, Orders logs, circuit-breaker metrics. | No liveness-driven Orders restart. | Experiment 1 / Orders->Payments validation | Pending deployment; supported by current Orders code once probes exist. |
| RV-002 | Inventory unavailable | Orders remains alive during reservation failure. | Orders restart count, Orders logs, probe state, failed/resumed reservation evidence. | No restart amplification. | Inventory failure test | Blocked: Orders->Inventory client not found in inspected app code. |
| RV-003 | External gateway unavailable | Payments process remains alive; gateway failure is isolated by Payments circuit breaker. | Payments restart count, Payments liveness endpoint, Payments logs, circuit-breaker metrics. | Gateway failure is isolated by Payments circuit breaker; no liveness-driven Payments restart. | Payments Gateway CB validation | Blocked: Payments gateway client not found in inspected app code. |
| RV-004 | Kafka unavailable | Kafka-dependent services do not enter liveness restart loops. | Restart counts, Kafka client logs, Kubernetes events, liveness endpoint responses. | No cascading restart churn. | Experiment 4 | Pending deployment; current Orders Kafka usage supports a reduced Kafka outage test once probes exist. |
| RV-005 | Dependency restored | Affected services reconnect automatically. | Logs, readiness transitions, restart count, recovery metrics. | No manual pod restart required. | Recovery validation | Pending deployment and implemented dependency paths. |
| RV-006 | Keycloak/JWKS unavailable | Auth dependency outage does not kill otherwise healthy services. | Service restart counts, liveness endpoint, auth/JWKS logs. | No liveness-driven restart from temporary JWKS outage. | Keycloak resilience validation | Blocked: resource-server/JWKS config not found in inspected app code. |
| RV-007 | CNPG failover | Database failover affects readiness/business operations without inappropriate liveness restart loops. | CNPG status, pod restart counts, readiness transitions, DB reconnect logs. | Services reconnect without manual pod restart. | Experiment 5 | Partially blocked: target CNPG platform manifests exist, but workload DB wiring and runtime deployment must be confirmed before testing. |

## Resilience Owner Assessment

Static configuration assessment: FAIL

Reason: verified probe configuration defects remain. The Helm chart configures
Actuator probe paths, but the inspected application modules do not provide
Actuator endpoints or health-group semantics.

Runtime resilience validation: BLOCKED

Reason: EuroTransit workloads and platform components are not currently deployed
in Lab02Cluster. Several target-architecture failure edges are also not
implemented in the inspected application repository.

Resilience Owner conclusion:

The current risk is restart amplification caused by probe endpoints that are
configured but not implemented. I verified the Helm probe paths and verified the
absence of Actuator or equivalent health endpoint configuration in the inspected
application modules. I also verified that parts of the documented target
architecture are ahead of the current application/configuration repositories.
My next action is to track RES-PROBE-001 until application-side probe endpoints
exist, and track RES-PROBE-002 until the team confirms which architecture
baseline will be deployed for resilience validation.

## Task Closure Criteria

The probe-review task can only be closed when:

- static probe defects are resolved;
- Helm rendering is valid;
- architecture baseline for the deployed system is confirmed;
- Orders liveness remains healthy during implemented Payments failure;
- Orders liveness remains healthy during implemented Inventory failure, if that
  edge is part of the deployed baseline;
- Payments liveness remains healthy during external gateway failure, if that
  edge is part of the deployed baseline;
- Kafka disruption does not cause cascading pod restarts for implemented Kafka
  producers/consumers;
- affected services recover without manual pod restart.

Until then, keep the relevant runtime validation items open or blocked.

## Cross-Document Relevance Check

Documents compared:

- `docs/ai-guidelines.md`
- `docs/ai-logs.md`
- `docs/architecture-design.md`
- `docs/chaos-experiment-hypotheses.md`
- `docs/dod.md`
- `docs/eurotransit-contract.md`
- `docs/resilience/probe-review.md`
- `deploy/charts/eurotransit`
- `/Users/srbuhidanielyan/IdeaProjects/eurotransit-application-g02`

Stale or conflicting assumptions found:

- `docs/architecture-design.md` and `docs/eurotransit-contract.md` describe a
  six-topic, four-stage Orders orchestrator. The inspected Orders app currently
  uses `order-placed`, `inventory-reserved`,
  `inventory-reservation-failed`, `order-confirmed`, and `order-failed`; no
  `payment-authorized` or `payment-failed` usage was found.
- `docs/eurotransit-contract.md` describes an Orders outbox for reliable Kafka
  publishing. The inspected Orders app sends `eurotransit.order-placed`
  directly through `KafkaTemplate` in `OrderService`.
- The target docs describe Orders->Inventory as a synchronous Stage 1 call. No
  Orders Inventory client was found in the inspected app code.
- The target docs describe Payments->external gateway and a Payments-owned
  circuit breaker. No external gateway client was found in the inspected
  Payments app code.
- The target docs describe Keycloak/JWKS validation. No resource-server or JWKS
  configuration was found in the inspected application modules.
- The target docs describe four service-owned CNPG clusters. The current config
  repo now contains those platform manifests under `platform/cnpg`, but the
  Helm workload templates still point application DB env vars to the
  chart-managed `{{ .Release.Name }}-cluster-rw` service.
- `docs/dod.md` and `docs/ai-guidelines.md` use different agent-log filenames
  (`docs/agent-log.md`, `docs/ai-logs.md`, and the guidelines' older
  `docs/ai-mistake-log.md` instruction).

Architecture baseline used:

- Target baseline: architecture-design, eurotransit-contract, DoD, and chaos
  hypotheses.
- Repository-supported baseline for this probe artifact: current Helm
  Deployments plus current Spring Boot application configuration and code.

Probe-review statements changed because of the audit:

- Orders->Inventory is now labeled as a documented target boundary, not an
  implemented current edge.
- Payments->external gateway is now labeled as a documented target boundary, not
  an implemented current edge.
- Keycloak/JWKS is now labeled as a documented target dependency, not an
  implemented current dependency.
- Kafka validation now distinguishes the documented six-topic pipeline from the
  reduced topic set found in the inspected Orders application.
- CNPG validation now distinguishes the documented four-cluster topology from
  the current mismatch between platform CNPG manifests and workload DB wiring.
- Runtime validation backlog now marks each test as pending deployment, blocked
  by missing implementation, or supported by current code once probes exist.

Remaining ambiguities requiring team confirmation:

- Whether the next deployed baseline is the current partial app implementation
  or the target v3 architecture.
- Whether `inventory-reserved` and related inventory events are temporary
  current implementation topics or should be replaced by the target six-topic
  flow.
- Whether `inventory-reservation-failed` is intentionally part of the current
  task breakdown or an older/stale topic.
- Whether payment result topics are still required as executable stages or
  should become audit-only topics in a newer architecture not yet reflected in
  docs.
- Whether the application Helm chart should be rewired from the older
  chart-managed CNPG dependency to the explicit service-owned CNPG clusters
  before CNPG failover validation.

Overall relevance of probe-review.md: High

The document remains highly relevant because the core verified defect is
directly supported by current Helm and application repository evidence: probes
target Actuator endpoints that are not implemented. The audit changed the
document so it no longer treats target-only architecture edges as current
runtime facts. The remaining runtime work is now scoped to the actual deployed
baseline once the team confirms it, which keeps the artifact actionable for the
Resilience Owner role.
