# AI Interaction Log

This file records significant AI-assisted development sessions, as required by
`docs/ai-guidelines.md` §16. Newest entries first.

---

### 2026-07-09 22:35

**Agent**

Claude Sonnet 5 via Claude Code

**Task**

Install the Strimzi Kafka operator (KRaft) and create the 6 Kafka topics for
the money path, on `feature/strimzi-kafka-topics`.

**Files Modified**

- platform/strimzi/operator-values.yaml (created)
- platform/strimzi/kafka-cluster.yaml (created)
- platform/strimzi/kafka-topics.yaml (created)
- docs/ai-logs.md (this entry)

**Summary**

Chart version (1.1.0), namespace (`kafka`), node count (3, KRaft), storage,
and partition count (3) were all decided by the human (Kaan), not the agent.
Manifests were verified against the actual strimzi-kafka-operator 1.1.0 CRDs
(pulled and inspected directly) before writing, which caught a real API
difference from older Strimzi versions: `kafka.strimzi.io/v1`, not `v1beta2`,
and `replicas`/`storage` now live on `KafkaNodePool` rather than `Kafka`.
Applied to Srbuhi's `Lab02cluster` (resource group `G_06`) and confirmed
live: operator rolled out, Kafka reached `Ready`, all 6 topics show
`READY: True` with 3 partitions / replication factor 3.

**Potential Risks**

- `min.insync.replicas: 2` and the two resource names were agent judgment
  calls, flagged to the human rather than asked as a separate question.
- Branch is 9 commits behind `origin/main` (CI image-tag bumps only, no
  overlap) — rebase before opening the PR.
- `docs/architecture-design.md`/`docs/dod.md` already carry an approved
  Catalog-DB + Keycloak change from a separate session, not yet cross-checked
  against the saga/outbox redesign done in this one.

**Confidence**

High — verified against the CRD schema before writing and against the live
cluster after applying.

**Notes**

this entry exists so those decisions are visible to the team, not just
captured in chat history.

---

### 2026-07-09 17:46

**Agent**

Codex — Resilience Engineering agent

**Task**

Static review of EuroTransit Helm liveness, readiness, and startup probes.

**Files Modified**

- docs/ai-logs.md

**Summary**

Reviewed the configuration repository Helm probe templates and the available
application repository health configuration. Found that the Helm chart points
backend probes at `/actuator/health/liveness` and
`/actuator/health/readiness`, while the application modules do not currently
include Spring Boot Actuator or explicit health-group configuration.

**Potential Risks**

- This was a static review only because the current AKS cluster has no
  EuroTransit workloads or platform components deployed.
- Runtime behaviour under dependency failures remains unverified until the
  services are deployed.
- The smallest functional fix likely belongs in the application repository:
  add Actuator and service-specific health-group semantics before relying on
  the existing Helm probe paths.

**Confidence**

High for the static mismatch; medium for service-specific runtime conclusions
until the application health endpoints are implemented and tested.

**Notes**

No probe configuration was changed during this review.

---

### 2026-07-09 11:20

**Agent**

Codex — Resilience Engineering agent

**Task**

Install Chaos Mesh through the existing GitOps/configuration repository.

**Files Modified**

- platform/argocd/chaos-mesh-application.yaml
- docs/ai-logs.md

**Summary**

Added a GitOps-managed Argo CD Application for the official Chaos Mesh Helm
chart. The configuration installs Chaos Mesh into the `chaos-mesh` namespace,
uses AKS/containerd runtime settings, keeps the dashboard internal, and supports
the documented `PodChaos` and `NetworkChaos` experiment hypotheses.

**Potential Risks**

- Live installation depends on the Argo CD instance being able to reach
  `https://charts.chaos-mesh.org` and `ghcr.io`.
- `ServerSideApply=true` is used to reduce CRD apply issues; this assumes the
  deployed Argo CD version supports that sync option.
- The team should converge on one log filename convention:
  `docs/ai-guidelines.md` uses `docs/ai-logs.md`, while `docs/dod.md` mentions
  `docs/agent-log.md`.

**Confidence**

Medium

**Notes**

This change installs the Chaos Mesh platform prerequisite only. It does not
define or run any chaos experiments. During implementation, Codex initially
mistook `docs/ai-logs.md` as missing because it had inspected an older branch;
after switching to `origin/dev`, the file existed. The overwrite was detected
with `git diff`/`git show HEAD:docs/ai-logs.md` and corrected.

---

### 2026-07-08 20:07

**Agent**

Claude (Opus 4.8) via Claude Code

**Task**

Update the Architecture Design and Definition of Done to reflect two approved
architectural decisions: (1) Catalog now owns a CloudNativePG database
(database-per-service), and (2) Keycloak is introduced for authentication
(pattern B — distributed JWT validation).

**Files Modified**

- docs/architecture-design.md
- docs/dod.md
- docs/ai-logs.md (created)

**Summary**

- Catalog DB: system overview updated from 3 to 4 CNPG clusters (added
  catalog-db); the "own CNPG cluster" bullet and the service table row for
  Catalog now state it owns catalog-db (removed "No DB"); config-repo structure
  gained platform/cnpg/catalog-db-cluster.yaml; the "Shared database" item under
  "What is NOT needed" now lists Catalog.
- Keycloak: removed "Authentication / JWT / OAuth" from "What is NOT needed";
  added Keycloak to the Platform components in the system overview; added a JWT
  entry to the communication-diagram legend and a new "Authentication
  (Keycloak)" subsection describing pattern B (each service validates Bearer
  tokens locally via spring-boot-starter-oauth2-resource-server against
  Keycloak's JWKS endpoint, no gateway-side auth).
- Frontend description updated: it now authenticates against Keycloak and
  attaches the Bearer JWT (previously "no auth").
- DoD: added an "Authentication (Keycloak)" section with four acceptance
  criteria; refreshed the "Last updated" date.

**Potential Risks**

- Documentation-only change. The real config-repo manifests do not yet exist:
  platform/cnpg/catalog-db-cluster.yaml, the Keycloak Deployment/Service, and
  the CNPG wiring for Catalog still need to be created and reconciled by Argo CD.
- The eurotransit-contract.md was intentionally left unchanged (it carries no DB
  topology, "What is NOT needed" section, or auth references); if API-level auth
  semantics (e.g. 401 responses) should be codified in the contract, that is a
  follow-up.
- Naming inconsistency across project docs: ai-guidelines.md §16 refers to
  docs/ai-logs.md (created here), while dod.md and the app-repo structure refer
  to docs/agent-log.md. Team should converge on one name.

**Confidence**

High — edits faithfully implement the human-approved decisions; ASCII-box
alignment was verified by character count.

**Notes**

Changes were explicitly approved by the human developer before implementation,
per ai-guidelines.md §5 and §19. Scope was kept to the two architecture
documents plus this log, with follow-up items surfaced rather than actioned.
