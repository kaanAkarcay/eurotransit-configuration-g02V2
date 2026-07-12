# AI Interaction Log

This file records significant AI-assisted development sessions, as required by
`docs/ai-guidelines.md` §16. Newest entries first.

---

### 2026-07-12 13:40

**Agent**

Claude Sonnet 5 via Claude Code

**Task**

Continuation of the same-day recovery: human merged `cluster.enabled: false`
and the Keycloak resource fix to `main` (PR #14) - verify it held, then chase
down why orders/notifications were still unhealthy and why 2 of 3 Kafka
brokers stayed `Pending`.

**Files Modified**

- platform/strimzi/kafka-cluster.yaml (broker resource requests lowered)
- backend/orders and backend/notifications (application repo, several fixes - see docs/ai-error-log.md for detail)
- docs/ai-logs.md (this entry)

**Summary**

Confirmed the merge held: `eurotransit-cluster` stayed gone, `orders-db` and
`keycloak-0` scheduled successfully. Kafka's remaining 2 brokers were still
blocked - real per-node deadlock, not one fixable constraint (one node
disk-maxed, one pod-count-maxed, one memory-tight). Node pool scaling was a
dead end: `az aks nodepool scale` hit a hard Azure regional vCPU quota wall
(0 left in `polandcentral`), not something retrying fixes. Chose to lower
the Kafka broker `resources.requests.memory` (768Mi -> 256Mi, limit kept
near the original ceiling) rather than reduce broker count or replication
factor - a human call, since dropping replicas would have broken
`min.insync.replicas: 2` and meant real data-durability loss, not just a
resource tweak. After deleting the two pending brokers to pick up the new
request, then deleting all 3 simultaneously so their KRaft quorum handshake
would overlap instead of missing each other on staggered restart timers, all
3 brokers came up healthy with the original replication factor 3 intact on
every topic - no durability tradeoff.

Separately chased orders/notifications through several real, distinct bugs
(each verified independently, not assumed - detail in `docs/ai-error-log.md`,
kept local): a missing `spring-boot-starter-actuator` dependency in both
services (probes-enabled YAML was correct but inert without it); a mutable
image-tag caching trap where nodes served stale cached digests under
`imagePullPolicy: IfNotPresent` even after the registry was updated,
requiring `kubectl debug node ... crictl rmi` to flush; and, for orders
specifically, a `jwtDecoder` bean that eagerly resolved the external
`g02.cpo2026.it` hostname at startup and timed out - root-caused to an
orphaned Azure Public IP resource still holding the `g02-entrypoint` DNS
label after the cluster restart, blocking a new LoadBalancer IP from
provisioning (`DnsRecordInUse`). Fixing that Azure-side needs Network
Contributor permissions neither of us has - worked around it instead by
splitting the JWT decoder's key-fetch source (now Keycloak's in-cluster
Service, always reachable) from issuer validation (still the public
hostname, since that's what real tokens are actually stamped with).

Also found the identical `SecurityConfig.kt` pattern already exists in
`inventory` - tested directly (`kubectl delete pod`) rather than assumed:
the currently-deployed `inventory` image predates the security-delivery
merge and doesn't contain that code at all, so it's not currently at risk,
but the source on disk has the same landmine for whenever it's next rebuilt.
Left unfixed - human's call to defer.

**Potential Risks**

- `inventory`'s source has the same eager-external-DNS JWT bug as orders
  did; dormant only because its deployed image predates the security merge.
- Docker build caching bit twice today: an incremental `docker build` silently
  reused a stale layer and produced an image without a just-made source
  change, even though `COPY src ./src` should invalidate on file changes -
  `--no-cache` was needed to force it. Worth verifying image content
  directly (not just trusting `docker build` succeeded) after any source fix
  that must land in the next build.
- The Azure Public IP/DNS conflict blocking the real ingress hostname is
  still unresolved - the JWT workaround only unblocks orders' own startup,
  it doesn't fix external access to `g02.cpo2026.it` itself.

**Confidence**

High for the Kafka resource fix and the JWT decoder split - both verified
live (all 3 brokers healthy with full replication; orders' fix confirmed
present in the built jar before pushing). Medium-high for orders overall as
of this entry - the actuator fix just went through a fresh, verified build
but hadn't yet been confirmed healthy live at the time of writing.

**Notes**

Second and third time today a "fixed" image turned out to not actually be
running the fix - once from a failed `az acr login` silently breaking `docker
push`, once from Docker's own build cache. Treat "the build/push succeeded"
as unverified until the actual deployed digest or jar content is checked
directly.

---

### 2026-07-12 12:18

**Agent**

Claude Sonnet 5 via Claude Code

**Task**

Cluster restarted after an overnight `az aks stop`/`start` for cost savings.
Orders and notifications were still crash-looping despite yesterday's fixes -
diagnose and get them, and the wider platform, healthy again.

**Files Modified**

- backend/orders/src/main/kotlin/it/polito/eurotransit/orders/config/JacksonConfig.kt (created, application repo)
- backend/notifications/src/main/resources/application.yaml (application repo)
- platform/keycloak/keycloak-cr.yaml
- deploy/charts/eurotransit/values.yaml
- docs/ai-logs.md (this entry)

**Summary**

Yesterday's orders/notifications image push never actually happened - `az acr
login` had silently failed before the build, so `docker push` ran with no
valid credentials and errored, but the failure was easy to miss in the
output. Confirmed via the registry API (tag timestamps unchanged since the
original broken build) rather than assumed. Re-pushed, then found deleting
the crash-looping pods just respawned the *same* wrong image - turned out
each Deployment had a stale, long-orphaned ReplicaSet (image tag `v4`) stuck
at `desired: 1` because its pod had never once passed readiness, so the
Deployment controller could never safely scale it down. Deleted the stale
ReplicaSets directly (not just their pods).

That surfaced two further, real, distinct bugs once the correct image
actually ran: orders was missing a `com.fasterxml.jackson.databind.ObjectMapper`
bean (same auto-configuration gap as yesterday's `WebClient.Builder` issue -
fixed the same way, an explicit `@Bean`); notifications was missing
`management.endpoint.health.probes.enabled: true`, so `/actuator/health/liveness`
404'd and kubelet kept killing it on startup-probe failure, not a code crash.
Also hit real image-tag caching: reusing `manual-7008275` meant a node that
already had it locally served the stale digest under `imagePullPolicy:
IfNotPresent` even after the registry was updated - confirmed via `imageID`
mismatch, worked around by deleting pods so they rescheduled onto nodes
without a cached copy.

Separately, the platform-wide capacity problem from two days ago resurfaced
harder: a cold restart tries to schedule everything at once (Argo CD, 5 CNPG
clusters, 3 Kafka brokers, Keycloak, observability stack) rather than the
gradual rollout that worked before. `orders-db`, `keycloak-0`, and 2/3 Kafka
brokers were stuck `Pending` on `Insufficient memory` / `Too many pods` /
`exceed max volume count` simultaneously. Scaling the node pool (the fix last
time) hit a hard wall: 0 regional vCPU quota left in `polandcentral` - not
fixable by retrying, a real Azure subscription ceiling. Pivoted to trimming
footprint instead: reduced Keycloak's memory request (1700Mi, an Operator
default never set by us, was the single largest reservation in the cluster)
to 512Mi via an explicit `resources` override, and found `eurotransit-cluster`
- a bundled, leftover single-shared-Postgres CNPG cluster from before the
per-service migration - still running with 3 full PVCs + 3 pods for a
resource nothing references. Deleted it live for immediate relief; also set
`cluster.enabled: false` in `values.yaml` since Argo CD's `selfHeal` recreated
it within a minute of the live deletion (git still said `enabled: true`) -
the live delete alone doesn't hold.

**Potential Risks**

- `values.yaml`'s `cluster.enabled: false` and the Keycloak resource
  override are uncommitted - human is merging separately. Until that lands
  on `main`, `eurotransit-cluster` will keep coming back on every Argo CD
  reconcile and re-consume the capacity Kafka needs.
- Kafka's remaining 2 broker pods (`pool-0`/`pool-2`) were still `Pending` as
  of this entry - cluster is not fully healthy yet, pending the above merge.
- `imagePullSecrets: acr-secret` (removed once already, flagged as broken)
  reappeared in `values.yaml`, apparently reintroduced by the
  `feature/security-delivery` merge - not yet re-removed, flagged to the
  human, not fixed in this session.
- The Azure vCPU quota shortage is a subscription-level constraint, not a
  cluster config problem - re-attempting node pool scale will fail identically
  until quota is increased or requested via Azure support.

**Confidence**

High for the diagnosed root causes (each confirmed via logs/registry
API/CRD inspection, not assumed) and the two application fixes (both
compile clean). Medium for the capacity situation overall - real relief was
achieved, but it's only fully verified once the pending `values.yaml`/
`keycloak-cr.yaml` changes are merged and Kafka's last 2 brokers are
confirmed healthy.

**Notes**

Second time an `az acr login` failure has silently caused a bad push (same
class of transient network blip seen with the AKS API server DNS earlier)
- worth treating "push completed" claims as unverified until checked against
the registry directly, not just the CLI's apparent success.

---

### 2026-07-11 16:54

**Agent**

Claude Sonnet 5 via Claude Code

**Task**

Debug why the 5 backend Deployments (catalog, orders, inventory, payments,
notifications) were failing after the human manually built and pushed images
to `lab02clusterregistry`, on `dev` (merged to `main` via PR #12).

**Files Modified**

- deploy/charts/eurotransit/templates/{catalog,orders,inventory,payments,notifications}-deployment.yaml
- deploy/charts/eurotransit/values.yaml
- platform/cnpg/{catalog,orders,inventory,payments,keycloak}-db-cluster.yaml
- platform/strimzi/kafka-cluster.yaml
- docs/ai-logs.md (this entry)

**Summary**

Two independent, real bugs, not one. First: the Deployment templates' DB env
vars were leftover from an older single-shared-Postgres design - catalog/
inventory/payments set `DB_HOST`/etc, which their Spring apps never read
(they expect `SPRING_R2DBC_URL`/`USERNAME`/`PASSWORD`); orders' names matched
but pointed at the old shared cluster instead of `orders-db`. All 5 were also
missing Kafka bootstrap and, for orders, `PAYMENTS_HOST`/`INVENTORY_HOST` -
confirmed by reading each service's actual `application.yaml`, not assumed.
Also removed a stale `imagePullSecrets: acr-secret` that referenced a Secret
that was never created (redundant anyway now that ACR is attached via
kubelet managed identity).

Second, found while fixing the first: `catalog-db`/`orders-db`/`inventory-db`/
`payments-db` were still in `cnpg-system`, but their Deployments run in
`eurotransit` - a Pod's `secretKeyRef` can only resolve a Secret in its own
namespace, so no amount of env-var renaming would have worked. Moved all 4 to
`eurotransit`, same reasoning already documented on `keycloak-db`. Required
deleting and recreating the live `Cluster` CRs (confirmed safe - no real data
yet, schema-only).

Fix verified end-to-end after merging to `main`: catalog, inventory, and
payments are healthy (`1/1`, zero restarts, correct image, correct DB/Kafka
wiring) via the real GitOps flow, not just a manual `kubectl apply`. Orders
and notifications still crash-loop, but on two unrelated, pre-existing
application-code bugs (missing `jackson-databind` on the classpath; missing
`WebClient.Builder` bean for `InventoryClient`) - out of scope for this repo,
flagged to the human for the application repo.

Also added `resources.requests/limits` to all 5 CNPG clusters and the
Strimzi `KafkaNodePool` (previously flagged as a gap, deferred until
something actually failed). It did: `keycloak-db` was killed mid-session by
a failed liveness probe while running `BestEffort` QoS under real node
memory pressure (one node hit 101%). Sized from observed usage
(`kubectl top pods`) with headroom. Confirmed after rollout: all 3 nodes
back to 86-87% memory, `MemoryPressure: False`, CNPG/Kafka pods now
`Burstable` QoS, no evictions since.

**Potential Risks**

- Registry push is still manual (`docker build`/`push` by hand) - the
  application repo's CI pipeline is not yet reliably producing pushed images
  under its own tags; `main` briefly had a commit pointing at a tag
  (`06dc58e`) that was never actually pushed to the registry.
- `payment-gateway-sim` still has no Deployment/Service in the Helm chart at
  all - deliberately not added without a decision on how it should be wired.

**Confidence**

High for the infra fixes - each one verified live against the real cluster
(pod logs, `kubectl top`, QoS class, registry manifest checks), not assumed.
The two remaining crash-looping services are confirmed to be application-code
bugs, not infra, but the exact fix for either wasn't pinned down yet.

**Notes**

Argo CD's `eurotransit` Application tracks `main`, not `dev` - manual
`kubectl apply` testing against a `selfHeal: true` Application gets reverted
on the next reconcile unless the fix actually lands on `main`.

---

### 2026-07-10 18:20

**Agent**

Claude Sonnet 5 via Claude Code

**Task**

Deploy Keycloak (operator, database, realm/client/test user) on
`feature/keycloak`, per the architecture's already-approved pattern B
(distributed JWT validation).

**Files Modified**

- platform/cnpg/keycloak-db-cluster.yaml (created)
- platform/keycloak/keycloak-cr.yaml (created)
- platform/keycloak/realm-import.yaml (created)
- platform/keycloak/keycloak-admin-credentials-sealed.yaml (created)
- docs/ai-logs.md (this entry)

**Summary**

Persistence (real Postgres) and install method (official Operator) were
human decisions. Everything else was verified, not assumed: the Operator has
no Helm chart at all (the GitHub repo literally named "keycloak-operator" is
archived - old WildFly-based project, unrelated to the current Quarkus-based
one); the real install command
(`kubectl apply -k 'github.com/keycloak/keycloak-k8s-resources/kubernetes?ref=26.7.0'`)
came from the human fetching the official docs directly, since keycloak.org
wasn't reachable from this environment. First install attempt landed in the
wrong namespace (`keycloak`, matching the doc's example, instead of
`eurotransit`, the actual architecture decision) - caught and corrected.

CRD inspection (group `k8s.keycloak.org`) found that `db.usernameSecret`/
`passwordSecret` have no namespace field - same-namespace-only - so
`keycloak-db` had to live in `eurotransit` instead of `cnpg-system` like the
other 4 CNPG clusters, a technical necessity rather than a style choice.
Path-based routing (`/auth`) goes through `additionalOptions` +
`http-relative-path`, the only mechanism available since there's no
first-class path field.

Separately discovered the sealed-secrets controller was never actually
installed on this cluster at all, despite an existing committed SealedSecret
referencing one - installed it properly (Bitnami chart 2.19.1, correcting a
wrong repo URL guess along the way). All 5 pieces (operator, keycloak-db,
sealed admin secret, Keycloak server, realm import) are confirmed healthy
live, not just applied without error - `KeycloakRealmImport` shows
`Done: True`, `HasErrors: False`.

"Service accounts" from the original task phrasing was deliberately not
implemented - no service in the finalized architecture authenticates as a
client to obtain its own token (pattern B only validates incoming tokens),
so there's no concrete use case for one. Flagged to the human rather than
invented.

**Potential Risks**

- `platform/argocd/private-config-repo-sealedsecret.yaml` (pre-existing) was
  sealed against a controller that no longer exists (or never existed on
  this cluster) - it's currently undecryptable and needs resealing against
  the controller installed here, separate follow-up not yet done.
- Test user's password is intentionally plaintext in `realm-import.yaml`
  (throwaway demo credential, not treated as a real secret) - worth
  confirming the team is fine with that tradeoff before the repo goes public
  anywhere.

**Confidence**

High - every structural claim (CRD schema, operator distribution, secret
scoping) was verified against the real source or the live cluster, not
memory. The one thing not yet done is resealing the orphaned Argo CD secret.

**Notes**

Two separate transient network blips (DNS resolution failing mid-session)
were unrelated to any of the above - retried and cleared on their own each
time, not a sign of anything wrong with the manifests.

---

### 2026-07-10 00:20


**Agent**

Claude Sonnet 5 via Claude Code

**Task**

Install the CloudNativePG operator and create Postgres clusters for all 4
services (catalog, orders, inventory, payments), on `feature/cnpg-clusters`.

**Files Modified**

- platform/cnpg/operator-values.yaml (created)
- platform/cnpg/catalog-db-cluster.yaml (created)
- platform/cnpg/orders-db-cluster.yaml (created)
- platform/cnpg/inventory-db-cluster.yaml (created)
- platform/cnpg/payments-db-cluster.yaml (created)
Install the Strimzi Kafka operator (KRaft) and create the 6 Kafka topics for
the money path, on `feature/strimzi-kafka-topics`.

**Files Modified**

- platform/strimzi/operator-values.yaml (created)
- platform/strimzi/kafka-cluster.yaml (created)
- platform/strimzi/kafka-topics.yaml (created)
- docs/ai-logs.md (this entry)

**Summary**

Scope was widened from the original 3 clusters to all 4 after checking
ai-logs.md/dev/main confirmed the Catalog-DB architecture change (from a
separate session) was never reversed. Chart version, namespace, instance
counts, and Postgres version were human decisions; Postgres 17 was confirmed
to actually exist in the registry before use (direct manifest check), not
assumed. `inventory-db` got 2 instances (the Chaos Experiment 5 target), the
other 3 got 1 each.

Applying all 4 hit a real infrastructure limit, not a manifest problem: the
node's Azure Disk CSI driver allows a maximum of 4 attached volumes
(confirmed via `kubectl get csinode ... -o yaml`), and Strimzi's 3 Kafka
broker PVCs already consume 3 of those before any Postgres cluster is even
considered. Root-caused via `FailedScheduling` events rather than guessed.
Resolved pragmatically for now: `orders-db` (the only service with real
application code to test against) is live and healthy; `catalog-db`,
`inventory-db`, and `payments-db` were deliberately deleted from the live
cluster to keep `orders-db` unblocked, while their manifests stay committed
and untouched. Full reconciliation is pending a node-pool scaling decision
the human is taking to the team.

**Resolved (same branch, after node pool scaled)**

The human took the capacity question to the team and got the node pool
scaled from 1 to 3 nodes (also sized for Chaos Experiment 3 - Node/AZ
disruption - which needs 3+ nodes to be a credible demonstration in its own
right, not just enough disks for Kafka+Postgres). All 4 Cluster manifests
were reapplied and are now live and healthy: catalog-db (1/1), orders-db
(1/1), inventory-db (2/2), payments-db (1/1). Live cluster state now matches
git desired state exactly - no more divergence.

**Potential Risks**

- Cost estimates given to the human for the extra nodes were rough, general
  Azure pricing knowledge, not verified against the actual subscription's
  billing - flagged as such at the time.
- No CPU/memory resource requests are defined yet on any of the 4 Cluster
  manifests, or anywhere in the application Helm chart's deployment
  templates - fine at current scale, worth setting before the 6 application
  pods and HPA-scaled replicas land on top of this.

**Confidence**

High - validated against the real CRD schema before writing, and all 4
clusters are now confirmed healthy live with the node pool at 3 nodes.

**Notes**

The exact disk-attach ceiling wasn't visible via `kubectl describe node`
(it's exposed through the `CSINode` object instead) - worth remembering for
next time this class of scheduling failure comes up.

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

---

### 2026-07-08 17:00

**Agent**

Codex

**Task**

Add `event_timestamp` to the shared Kafka event schema after human approval.

**Files Modified**

- `tasks-valeria.md`
- `eurotransit-contract.md`
- `architecture-design.md`
- `dod.md`
- `eurotransit-application-g02/orders/src/main/kotlin/it/polito/eurotransit/orders/service/OrderService.kt`
- `eurotransit-application-g02/orders/src/main/kotlin/it/polito/eurotransit/orders/kafka/OrderConsumer.kt`
- `eurotransit-configuration-g02/docs/eurotransit-contract.md`
- `eurotransit-configuration-g02/docs/architecture-design.md`
- `eurotransit-configuration-g02/docs/dod.md`
- `eurotransit-configuration-g02/docs/ai-logs/ai-logs-valeria.md`

**Summary**

Updated the Kafka event contract to require `event_timestamp`, documented its
producer-created UTC semantics, and added the field to the Orders event DTOs and
emitted events currently present in the codebase.

**Potential Risks**

- Other services and future event producers/consumers must include the same field
  when their Kafka handlers are implemented.
- Existing Kafka messages without `event_timestamp` would not match the updated
  required event DTOs.

**Confidence**

Medium

**Notes**

This was a contract change requested explicitly by the human developer after
discussion. Verified with Orders `clean test`; the Gradle wrapper jar was invoked
directly because `gradlew.bat` does not handle the `CloudProg&Ops` path
correctly.

---

### 2026-07-08 16:33

**Agent**

Codex

**Task**

Execute Valeria-owned tasks that can be completed locally without waiting for
other team members or making unapproved architecture decisions.

**Files Modified**

- `tasks-valeria.md`
- `eurotransit-application-g02/orders/src/main/kotlin/it/polito/eurotransit/orders/service/OrderService.kt`
- `eurotransit-application-g02/orders/src/main/kotlin/it/polito/eurotransit/orders/kafka/OrderConsumer.kt`
- `eurotransit-application-g02/orders/src/main/resources/application.yaml`
- `eurotransit-application-g02/.github/workflows/ci.yaml`
- `eurotransit-configuration-g02/platform/argocd/eurotransit-application.yaml`
- `eurotransit-configuration-g02/deploy/charts/eurotransit/values.yaml`
- `eurotransit-configuration-g02/deploy/charts/eurotransit/templates/ingress.yaml`
- `eurotransit-configuration-g02/deploy/charts/eurotransit/templates/orders-canary-traefikservice.yaml`
- `eurotransit-configuration-g02/deploy/charts/eurotransit/templates/orders-canary-ingressroute.yaml`
- `eurotransit-configuration-g02/docs/deployment-strategies.md`
- `eurotransit-configuration-g02/docs/ai-logs/ai-logs-valeria.md`

**Summary**

Aligned Orders Kafka event DTO JSON names with the snake_case contract, updated
Orders topic configuration to the six current topics, enabled Argo CD automated
sync in the Application manifest, fixed CI image/tag handling for changed-service
builds, added a disabled-by-default Orders canary TraefikService scaffold,
documented deployment strategies, and created a Valeria-only task tracker.

**Potential Risks**

- The explicit event timestamp task is intentionally not implemented because it
  changes the API Contract and needs human approval.
- JWT and service-to-service authentication are blocked because Architecture
  Design currently says authentication/JWT/OAuth are not required.
- Canary configuration is scaffolded but disabled by default; it still requires a
  canary service and live validation before promotion.
- Blue/green implementation still needs a human decision on scope and routing
  model.

**Confidence**

Medium

**Notes**

Verified with `helm template` both with canary disabled and with
`canary.orders.enabled=true`. Verified Orders with a forced `clean test`; the
Gradle batch wrapper fails in this workspace path because `CloudProg&Ops` is
split by `cmd.exe`, so the Gradle wrapper jar was invoked directly.

---

### 2026-07-11 14:30

**Agent**

Codex

**Task**

Wire Keycloak realm and Helm environment for Orders and Inventory JWT support,
excluding Payments per human instruction.

**Files Modified**

- platform/keycloak/realm-import.yaml
- deploy/charts/eurotransit/values.yaml
- deploy/charts/eurotransit/templates/orders-deployment.yaml
- deploy/charts/eurotransit/templates/inventory-deployment.yaml
- docs/ai-logs.md

**Summary**

Extended the existing `eurotransit` Keycloak realm import with Orders and
Inventory API audiences, plus an `orders-service` service-account client that
receives the Inventory audience. Added Helm values and deployment environment
variables for issuer URI, expected audiences, token endpoint, client id, and the
Secret reference used by Orders to read the service-account client secret.

**Potential Risks**

- The real `orders-service` client secret must be set in Keycloak and stored as
  a Kubernetes Secret or SealedSecret named `orders-service-client` with key
  `client-secret`; no plaintext secret is committed.
- The configured issuer is `https://g02.cpo2026.it/auth/realms/eurotransit`,
  matching the Keycloak CR hostname/path. Runtime DNS/TLS reachability must be
  validated in cluster.
- Payments is intentionally not wired in this pass, even though the full
  documented service-to-service security model includes it.

**Confidence**

Medium — manifests are aligned with the existing Keycloak CR/realm import
structure, but they require cluster validation and a real sealed client secret.

**Notes**

No Kubernetes service names, image repositories, API paths, or Kafka topics were
changed.
