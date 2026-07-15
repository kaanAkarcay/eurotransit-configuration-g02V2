# AI Interaction Log

This file records significant AI-assisted development sessions, as required by
`docs/ai-guidelines.md` §16. Newest entries first.

---

### 2026-07-14 23:34

**Agent**

Codex

**Task**

Address review feedback on the Orders -> Inventory network-partition chaos
experiment.

**Files Modified**

- platform/chaos-mesh/experiments/orders-inventory-network-failure-schedule.yaml
- docs/resilience/orders-inventory-circuit-breaker-chaos.md
- docs/chaos-experiment-hypotheses.md
- docs/ai-logs.md

**Summary**

Corrected the experiment documentation to avoid overclaiming what a Chaos Mesh
`partition` can prove. The runbook now states that network partition is a packet
blackhole, not a fast hard failure, and that the manifest is blocked until the
deployed Orders image enforces an Inventory timeout. Added explicit blast-radius
risk for hanging Orders -> Inventory calls because the committed Orders code does
not enforce the configured TimeLimiter, bulkhead, or Inventory connection-pool
settings. Fixed the threshold decision guide so a no-open result under full
partition is diagnosed as missing timeout/samples/wrapping rather than a reason
to lower `failure-rate-threshold`.

Also clarified that current Argo CD syncs `deploy/charts/eurotransit`, not the
`platform/chaos-mesh/experiments` path, so merging this branch does not apply the
experiment manifest. Moved the targeted experiment out of the numbered
Experiment 1-5 sequence.

**Potential Risks**

- The manifest remains a future suspended experiment; it still cannot tune
  thresholds until the application-side timeout prerequisite is implemented.
- Live Chaos Mesh CRDs are still absent unless the platform application is
  bootstrapped separately.

**Confidence**

High. The changes are documentation and manifest-comment corrections that align
the branch with the current Orders implementation evidence and GitOps layout.

**Notes**

No application code or threshold values were changed.
### 2026-07-14 23:43

**Agent**

Claude Sonnet 5 via Claude Code

**Task**

Root-cause the recurring node instability/pod-concentration problem that
surfaced repeatedly this session (nodes flapping toward 100%+ memory, one
node repeatedly absorbing most of the app stack, Catalog/Traefik hanging
under load), then restore previously-paused platform components (see
2026-07-14 16:26 entry) with chaos-testing readiness in mind.

**Files Modified**

- deploy/charts/eurotransit/values.yaml (added `resources` to 6 services)
- deploy/charts/eurotransit/templates/{catalog,frontend,inventory,
  notifications,orders,payments}-deployment.yaml (added `resources:` block
  referencing the above)
- platform/traefik/values.yaml (added `resources`)
- platform/strimzi/kafka-cluster.yaml (broker memory request 256Mi -> 650Mi)
- docs/ai-logs.md (this entry)
- (live cluster state - see below, not fully reflected in git yet)

**Summary**

Root cause: all 6 app services, Traefik, the CNPG operator, and every ArgoCD
component had **no `resources.requests` declared at all** - BestEffort QoS,
completely invisible to the scheduler's placement math. The scheduler had no
way to know these pods needed real memory (observed: 246-698Mi each), so it
kept stacking them onto whichever node looked "empty" on paper, regardless of
real usage - the actual mechanism behind the whole session's node-instability
whack-a-mole, not random flakiness.

Fix: measured each service's real memory usage via `kubectl top`, then set
honest `resources.requests`/`limits` (roughly observed usage + 20-30%
headroom for requests, ~2x for limits) in the Helm chart for the 6 app
services and Traefik, applied live via `kubectl set resources` (Helm/ArgoCD
itself is not currently syncing - see below). Also raised Kafka's broker
request from 256Mi (deliberately lowered earlier this project during a prior
capacity crunch) back to 650Mi to match real usage (~630-700Mi/broker);
required briefly restoring `strimzi-cluster-operator` to reconcile the
`KafkaNodePool` change, then leaving it running per explicit direction.

Made one real mistake mid-fix: an initial `helm template eurotransit ... |
kubectl apply -f -` was run without `-n eurotransit` on the apply side, and
none of these Deployment templates set `metadata.namespace` explicitly -
this created a full duplicate of every app service (plus `payment-gateway-sim`,
which isn't even supposed to be live yet - it's on `dev`, not `main`) in the
`default` namespace. Caught immediately via `kubectl get all -n default`,
confirmed the real `eurotransit`-namespace resources were untouched, deleted
the duplicates entirely. Switched to targeted `kubectl set resources` per
Deployment for the rest of this session to avoid repeating this.

Separately, given this project's chaos-experiment requirements
(`docs/chaos-experiment-hypotheses.md`), restored several platform components
that had been scaled to 0 for capacity earlier: CNPG operator (databases had
zero self-healing without it - the single biggest gap for chaos testing,
since a chaos-killed DB pod wouldn't recover), the full monitoring stack
(chaos testing without observability can't measure anything), and most of
ArgoCD (GitOps self-heal is itself a documented resilience mechanism worth
being able to test). Found the CNPG operator and every ArgoCD component had
the exact same zero-request problem as the app services - fixed those too as
they came back up, using the same measure-then-declare approach.

Hit a real, hard capacity ceiling doing this: with every component now
honestly declaring its real memory need, the cluster's three nodes are
genuinely near 100% of allocatable memory in requests-terms (actual live
usage is lower, ~85-89%, but the scheduler only ever looks at declared
requests, never live usage). `argocd-application-controller` (320Mi, the
actual sync engine) and `argocd-notifications-controller` (32Mi) cannot
schedule anywhere right now and are stuck `Pending`. `keycloak-operator`,
all of `cert-manager`, and `sealed-secrets-controller` remain at 0 by
explicit choice, deferred until real headroom exists - restoring them now
would just create new Pending pods, not actually help anything.

**Current state (verified live, not all reflected in git as a diff beyond
what's listed above)**:
- Running with proper resources: CNPG operator, full monitoring stack
  (Prometheus/Alertmanager/Grafana/kube-state-metrics/prometheus-operator),
  `strimzi-cluster-operator`, `argocd-dex-server`/`redis`/
  `applicationset-controller`, all 6 app services, Traefik.
- Desired=1 but not actually running (Pending, no capacity):
  `argocd-application-controller`, `argocd-notifications-controller`.
- `argocd-repo-server`/`argocd-server`: functionally up, but still serving
  via their pre-resource-patch pod - the replacement pod with real requests
  is itself stuck Pending until room frees up.
- Still at 0 by choice: `keycloak-operator`, `cert-manager` (all 3
  components), `sealed-secrets-controller`.

**Potential Risks**

- The live cluster's Deployment/StatefulSet resource specs (kubectl-applied)
  and Helm's own release state may now differ until this is properly
  reconciled through Argo CD/Helm again - same category of drift risk
  documented in the 2026-07-14 16:26 entry for the Keycloak realm.
- `argocd-application-controller` being down means Argo CD is not actually
  reconciling anything right now, on top of already tracking a stale `main`
  and `dev` being 17 commits ahead unpromoted (see same earlier entry).
- No headroom exists for `keycloak-operator`/`cert-manager`/
  `sealed-secrets-controller` - if any of the 5 already-running things below
  needed a genuine emergency restart while under this ceiling, another
  Pending situation is likely.
- The specific request/limit numbers were sized from a single snapshot of
  observed usage, not sustained load - worth re-validating once the app is
  handling real traffic instead of ad-hoc test bookings.

**Confidence**

High on the root cause (directly observed: `resources: {}` on every
affected workload, confirmed via `kubectl get ... -o jsonpath`) and on the
capacity ceiling being real, not a misconfiguration (confirmed via exact
allocatable-vs-requested arithmetic per node, not just percentages). Medium
on the specific number choices - reasonable given observed data, but not
load-tested.

---

### 2026-07-14 19:15

**Agent**

Claude Opus 4.8

**Task**

Make `payment-gateway-sim` deployable: CI inclusion (application repo, separate
PR), and completing the Helm wiring this repo already gained in `ad3693a`.

**Files Modified**

- `deploy/charts/eurotransit/templates/payment-gateway-sim-deployment.yaml`
- `deploy/charts/eurotransit/templates/payment-gateway-sim-service.yaml`
- `deploy/charts/eurotransit/values.yaml`
- `deploy/charts/eurotransit/templates/servicemonitor-backend.yaml`
- `docs/ai-logs.md`

**Summary**

Built on the templates added in `ad3693a` rather than duplicating them; four
gaps closed:

1. Values key renamed `paymentGatewaySim` -> `payment-gateway-sim`: CI's rollout
   step bumps `."<service>".restartedAt` using the service's directory name, so
   the camelCase key would never receive the bump and pods would never roll.
   Templates now read it via `index`.
2. Env wired: `STRIPE_ENABLED` from `stripe.enabled` (set to **false** — first
   deploy runs the LocalChargeGateway; the app fails fast at startup if Stripe
   is enabled with a blank key, so as merged the pod would have crash-looped),
   `STRIPE_SECRET_KEY` via `secretKeyRef` to `payment-gateway-sim-stripe`
   (`optional: true`, safe because the app's own fail-fast guards the enabled
   case), `STRIPE_PAYMENT_METHOD` from values.
3. Probes switched from `tcpSocket` to the actuator readiness/liveness groups
   (verified enabled in the service's application.yaml): an open TCP port says
   nothing about readiness, and the DoD requires readiness to reflect actual
   ability to serve.
4. `payment-gateway-sim` added to the ServiceMonitor list (it serves
   `/actuator/prometheus`).

This closes the deployment TODO left open by the 2026-07-11 17:55 entry.

**Potential Risks**

- Enabling Stripe requires the `payment-gateway-sim-stripe` Secret first; the
  sealed-secrets controller's presence on the cluster is unverified (a prior
  log entry says it may never have been installed), so the secret may need
  manual `kubectl create secret` like `orders-service-client`.
- First `stripe.enabled=true` flip is also the first-ever live Stripe call:
  the wire format is validated only against WireMock stubs.
- Argo CD tracks `main`; merging to `dev` alone deploys nothing.

**Confidence**

High — chart rendered with `helm template` and the gateway Deployment/Service/
ServiceMonitor inspected field-by-field; CI's quoted yq expression verified
empirically against both dashed and plain keys.

**Notes**

The 401 reported as this task's symptom does not come from this service (it has
no security dependency at all): it is Payments rejecting calls lacking a JWT
with `aud=payments`. Tracked as a separate Keycloak realm task.

---


### 2026-07-14 20:20

**Agent**

Codex

**Task**

Prepare repository-side Orders -> Inventory circuit-breaker tuning through a
Chaos Mesh experiment and runbook.

**Files Modified**

- platform/chaos-mesh/experiments/orders-inventory-network-failure-schedule.yaml
- docs/resilience/orders-inventory-circuit-breaker-chaos.md
- docs/chaos-experiment-hypotheses.md
- docs/ai-logs.md

**Summary**

Created a suspended draft `NetworkChaos` Schedule for the Orders -> Inventory
failure path and documented how to execute it safely through the existing
GitOps/Chaos Mesh conventions. The runbook records prerequisite findings:
committed Orders currently has an `inventory-client` circuit breaker but no
committed `@TimeLimiter` on the Inventory call, Resilience4j defaults
`minimumNumberOfCalls` to 100 if omitted, and the live cluster currently lacks
the Chaos Mesh namespace, CRDs, and Argo CD Application.

No circuit-breaker thresholds were changed because the experiment has not run.
The documentation now calls out QPS/sample-size requirements for the 60 second
fault window, a short selector smoke run before the full experiment, the limits
of an all-pod partition for threshold tuning, and the possibility of a future
one-shot `Workflow` only after the live Chaos Mesh version/CRDs are confirmed.

**Validation**

- `helm lint deploy/charts/eurotransit`
- `helm template eurotransit deploy/charts/eurotransit --namespace eurotransit`
- `git diff --check`
- YAML parsing for Chaos Mesh and Argo CD manifests
- `kubectl apply --dry-run=server -f platform/argocd/chaos-mesh-application.yaml`
- Server dry-run of the new Chaos Mesh Schedule was blocked as expected because
  the live cluster does not currently have Chaos Mesh CRDs installed.

**Potential Risks**

- The experiment is a repository-side draft only; it cannot run until Chaos Mesh
  is installed or bootstrapped into the live GitOps flow.
- Timeout-sensitive tuning remains blocked until the deployed Orders image
  actually enforces an Inventory timeout.
- The current manifest uses a full Orders -> Inventory partition; finer
  threshold calibration should use a later partial-failure run.

**Confidence**

Medium. The Git-side implementation and validations are straightforward, but
runtime tuning remains blocked by missing live Chaos Mesh components and the
application-side timeout prerequisite.

**Notes**

This branch completes the Git preparation for the task, not the live resilience
validation. Do not mark the thresholds tuned until a controlled run has produced
Prometheus/Resilience4j evidence.

---

### 2026-07-13 16:45

**Agent**

Codex

**Task**

Move the ingress incident from open-ended audit to controlled recovery, without
changing live infrastructure before approval.

**Files Modified**

- platform/traefik/values.yaml
- platform/keycloak/keycloak-cr.yaml
- platform/keycloak/keycloak-ingress.yaml
- docs/ingress-dns-recovery-report-2026-07-13.md
- docs/ai-logs.md

**Summary**

Captured a fresh read-only incident snapshot. Proved the current Azure Public IP
`134.112.8.66` routes successfully to Traefik, frontend, ArgoCD, and the
protected Orders API when public DNS is bypassed with `curl --resolve`. Also
proved DNS update alone is not sufficient yet: `catalog-db` has no active
endpoint, `eurotransit-catalog` is `CrashLoopBackOff`, `eurotransit-keycloak-0`
is stuck terminating on NotReady `vms21`, and `eurotransit-keycloak-service` has
no ready endpoint.

Found an additional hidden routing issue: the Keycloak operator-generated
Ingress is host-only and has no explicit `/auth` path, while the EuroTransit
frontend ingress owns `/`. `/auth/` currently returns the frontend rather than a
Keycloak response. Prepared a repo fix that disables the operator-generated
Keycloak ingress and adds an explicit `/auth` Prefix ingress.

Prepared a Traefik Helm values fix that binds the current Public IP by name via
`service.beta.kubernetes.io/azure-pip-name` and
`service.beta.kubernetes.io/azure-load-balancer-resource-group`, while keeping
the current Azure DNS label `g02-entrypoint-2026`. Removed the earlier
two-replica Traefik change from the incident fix to avoid adding scheduling
pressure while `vms21` is NotReady.

Searched both accessible Azure subscriptions and Azure Resource Graph for the
old IP `134.112.166.65`, label `g02-entrypoint`, and FQDN
`g02-entrypoint.polandcentral.cloudapp.azure.com`; no matching Public IP
resource was found. Authoritative DNS for `cpo2026.it` is OVH and still points
both real domains to the old Azure FQDN.

**Validation**

- `kubectl get nodes -o wide`
- `kubectl -n eurotransit get pods,svc,endpoints -o wide`
- `kubectl describe ingress -n eurotransit eurotransit`
- `kubectl describe ingress -n eurotransit eurotransit-keycloak-ingress`
- `kubectl get certificates,orders,challenges -A`
- `curl -k -I --resolve g02.cpo2026.it:443:134.112.8.66 https://g02.cpo2026.it/`
- `curl -k -I --resolve argocd.g02.cpo2026.it:443:134.112.8.66 https://argocd.g02.cpo2026.it/`
- `curl -k -I --resolve g02.cpo2026.it:443:134.112.8.66 https://g02.cpo2026.it/api/v1/catalog/products`
- `helm template traefik traefik/traefik --version 41.0.2 --namespace traefik -f platform/traefik/values.yaml`
- `helm template traefik traefik/traefik --version 41.0.2 --namespace traefik -f platform/traefik/values.yaml | kubectl -n traefik apply --dry-run=server -f -`
- `kubectl apply --dry-run=server -f platform/keycloak/keycloak-cr.yaml -f platform/keycloak/keycloak-ingress.yaml`
- `az network public-ip list --subscription b4055687-faee-4bee-8a51-ad027dcf6c12`
- `az network public-ip list --subscription c7768585-2a5f-45e4-acb0-d6e083cbbc33`
- `az graph query`
- `dig @dns14.ovh.net g02.cpo2026.it +noall +answer`
- `dig @dns14.ovh.net argocd.g02.cpo2026.it +noall +answer`

**Confidence**

High that the current Azure IP is the right endpoint to preserve, that Helm
currently risks reverting the DNS label, and that catalog/Keycloak runtime
health must be restored before declaring the incident resolved. Live application
of the prepared fixes is pending explicit approval.

---

### 2026-07-13 16:25

**Agent**

Codex

**Task**

Investigate why Azure created a different Public IP instead of reusing the
previous Traefik endpoint, using only repository, Git history, Kubernetes,
Helm, and Azure evidence.

**Files Modified**

- docs/azure-public-ip-root-cause-2026-07-13.md
- docs/ai-logs.md

**Summary**

Audited `platform/traefik/values.yaml`, Git history, live Traefik Service,
Helm release state, Azure Public IPs, and the AKS Load Balancer. Found no
historical or current `service.beta.kubernetes.io/azure-pip-name`,
`service.beta.kubernetes.io/azure-load-balancer-resource-group`, or
`loadBalancerIP` in the actual Traefik configuration. The original Traefik
values were introduced with only `service.beta.kubernetes.io/azure-dns-label-name:
g02-entrypoint`, which requests a DNS label but does not bind the Service to a
specific Azure Public IP.

Confirmed the current Public IP `134.112.8.66` is AKS-managed and tagged for
`traefik/traefik`, with generated name
`kubernetes-a18745822eff349198a98b394c413147`. The old IP `134.112.166.65` and
old label `g02-entrypoint` were not present in the current subscription's Public
IP inventory. Helm history shows a single Traefik install, not a later
upgrade/reinstall, while live Helm values still contain the old DNS label.

**Validation**

- `rg -n "azure-pip-name|azure-load-balancer|azure-dns-label-name|loadBalancerIP|g02-entrypoint" .`
- `git log --all --follow -p -- platform/traefik/values.yaml`
- `git log --all -S azure-pip-name --oneline --decorate -- .`
- `git log --all -S loadBalancerIP --oneline --decorate -- .`
- `kubectl -n traefik get svc traefik -o yaml`
- `helm get values traefik -n traefik -o yaml`
- `helm history traefik -n traefik`
- `az network public-ip list -o json`
- `az network lb list -g MC_G_06_Lab02cluster_polandcentral -o json`

**Confidence**

High. Azure behaved correctly for a Service that did not reference a persistent
Public IP; the root cause is missing Azure Public IP binding in the Traefik
Service design, not a removed configuration regression.

---

### 2026-07-13 16:05

**Agent**

Codex

**Task**

Continue AKS recovery investigation without changing cluster state before
approval.

**Files Modified**

- docs/ingress-dns-recovery-report-2026-07-13.md
- docs/ai-logs.md

**Summary**

Re-verified live cluster state. `aks-cloudlab02-33508055-vms21` remains
`Ready,SchedulingDisabled`, while four critical pods remain Pending:
`eurotransit-keycloak-0`, `inventory-db-2`, and Kafka brokers `pool-0`/`pool-2`.
Traefik is currently `1/1 Ready`, but has restarted again and remains a single
replica on `aks-cloudlab02-33508055-vms23`, the node with recent kubelet,
container runtime, CoreDNS, and VNet DNS instability.

Added evidence that DNS is necessary but still not sufficient: bypassing public
DNS with `curl --resolve` reaches the current IP, but HTTPS still fails or
returns 503 while TLS secrets are absent and Keycloak has no endpoints. Azure
quota also blocks immediate scale-out because `Total Regional vCPUs` is already
`6/6`, making uncordoning the healthy existing `vms21` the first recommended
non-destructive recovery step.

Refreshed Helm repo metadata and validated Traefik values against chart
`41.0.2`. A draft `logs:` block was rejected by the chart schema and was
corrected to `log.level` plus `accessLog.enabled` before any live Helm change.

After explicit approval, ran `kubectl uncordon
aks-cloudlab02-33508055-vms21`. This cleared all Pending pods:
`eurotransit-keycloak-0`, `inventory-db-2`, and Kafka brokers `pool-0`/`pool-2`
all scheduled onto `vms21` and became Ready. The remaining live blocker is
Traefik: it is still one replica on `vms23`, and `vms23` continues to report
`NotReady`/kubelet instability, leaving the Traefik Deployment at `0/1`
available.

**Validation**

- `kubectl get nodes -o wide`
- `kubectl get pods -A --field-selector=status.phase=Pending -o wide`
- `kubectl -n traefik get pods,deploy,svc,endpointslice -o wide`
- `az vm list-usage -l polandcentral -o table`
- `helm template traefik traefik/traefik --version 41.0.2 --namespace traefik -f platform/traefik/values.yaml`
- `helm template traefik traefik/traefik --version 41.0.2 --namespace traefik -f platform/traefik/values.yaml | kubectl -n traefik apply --dry-run=server -f -`
- `kubectl uncordon aks-cloudlab02-33508055-vms21`
- `kubectl -n eurotransit wait pod/eurotransit-keycloak-0 --for=condition=Ready --timeout=180s`
- `kubectl -n eurotransit wait pod/inventory-db-2 --for=condition=Ready --timeout=180s`
- `kubectl -n kafka wait pod/eurotransit-kafka-eurotransit-pool-0 --for=condition=Ready --timeout=180s`
- `kubectl -n kafka wait pod/eurotransit-kafka-eurotransit-pool-2 --for=condition=Ready --timeout=180s`

**Confidence**

High that uncordoning `vms21` was the correct first recovery action. High that
the next cluster action should be the validated Traefik Helm upgrade to preserve
`g02-entrypoint-2026` in Helm state and scale Traefik to two replicas; that
still requires explicit approval because it changes production ingress.

---

### 2026-07-13 15:50

**Agent**

Codex

**Task**

Create a new branch and independently audit the remaining ingress/DNS incident
without assuming DNS is the only root cause.

**Files Modified**

- platform/traefik/values.yaml
- docs/ingress-dns-recovery-report-2026-07-13.md
- docs/ai-logs.md

**Summary**

Created branch `feat/ingress-dns-recovery` from `dev`.

Verified that DNS for `cpo2026.it` is managed by OVH, not Azure DNS:
`dns14.ovh.net` and `ns14.ovh.net` are authoritative. Both
`g02.cpo2026.it` and `argocd.g02.cpo2026.it` currently have OVH CNAME records
to the old Azure label `g02-entrypoint.polandcentral.cloudapp.azure.com`, which
resolves to `134.112.166.65`.

Audited Azure Public IPs and Load Balancer state. The old IP `134.112.166.65`
and old label `g02-entrypoint` are not present in the current subscription. The
current Traefik IP is `134.112.8.66` with label `g02-entrypoint-2026`.

Challenged the DNS-only hypothesis and found hidden live issues: Traefik is a
single replica on unstable node `aks-cloudlab02-33508055-vms23`, repeatedly
failing `/ping` liveness/readiness and leaving the Traefik Deployment `0/1`.
Keycloak is also Pending with no service endpoints, and node capacity is tight
(`Too many pods`, `Insufficient cpu`, `Insufficient memory`).

Updated `platform/traefik/values.yaml` to keep the current DNS label,
use chart-supported `log.*` / `accessLog.*` keys, and run Traefik with two replicas plus
topology spread. A PDB was intentionally not kept because the locally rendered
Traefik chart emits `policy/v1beta1`, which Kubernetes 1.33 rejects.

**Validation**

- `helm template traefik traefik/traefik --namespace traefik -f platform/traefik/values.yaml`
- `helm template traefik traefik/traefik --namespace traefik -f platform/traefik/values.yaml | kubectl -n traefik apply --dry-run=server -f -`
- `helm lint deploy/charts/eurotransit`
- `helm template eurotransit deploy/charts/eurotransit --namespace eurotransit`

**Confidence**

High that DNS must be updated in OVH, but also high that DNS alone is not
sufficient until Traefik/node stability and Keycloak readiness are addressed.

---

### 2026-07-11 17:55

**Agent**

Claude (Opus 4.8) via Claude Code

**Task**

Sync the design docs with the application change that made `payment-gateway-sim`
a real Stripe adapter (application PR #18), per ai-guidelines §8/§19.

**Files Modified**

- docs/architecture-design.md
- docs/eurotransit-contract.md

**Summary**

Added a note after the service table in architecture-design.md and extended the
"Payment Gateway" lane note in eurotransit-contract.md to record that the
external payment gateway is realised by an in-cluster adapter, `payment-gateway-sim`,
which now calls Stripe's PaymentIntents API for real and keeps a header-driven
fault-injection short-circuit for chaos/test harnesses. Payments' request/response
contract with the gateway is explicitly unchanged.

**Potential Risks**

- Documentation-only; no diagrams or the fixed-width service table were reflowed
  (notes added alongside to avoid formatting churn).
- Not covered here: a first-class service-table row for `payment-gateway-sim`, a
  documented `POST /gateway/charge` API section, and the service's Helm
  deployment + Stripe SealedSecret — proposed as follow-ups.

**Confidence**

High — wording mirrors the implemented behavior in application PR #18.

**Notes**

Introducing a Stripe-backed adapter is an architecture-doc change (§19); it was
proposed and approved before editing.
### 2026-07-12 19:51

**Agent**

Claude Sonnet 5 via Claude Code

**Task**

A CI run auto-committed image tags (`7a24ccb`) for all 5 backend services
that didn't actually exist in the registry, taking every backend pod down at
once. Root-cause it and fix the whole CI/CD pipeline, not just patch the
symptom.

**Files Modified**

- .github/workflows/ci.yaml (application repo)
- deploy/charts/eurotransit/values.yaml
- deploy/charts/eurotransit/templates/{catalog,orders,inventory,payments,notifications}-deployment.yaml
- backend/inventory, backend/payments (application repo - JWT decoder fix, same as orders' earlier one)
- docs/ai-logs.md (this entry)

**Summary**

Root cause of the outage: `ci.yaml` built and pushed to
`eurotransit-<service>` (hyphen) while every Deployment pulls from
`eurotransit/<service>` (slash) - a typo that meant CI's images never landed
anywhere Kubernetes could find them, yet the workflow still committed the
tag bump unconditionally. Argo CD's `selfHeal` then deployed the broken
reference to all 5 services within minutes, with zero verification gate in
between - confirmed Argo CD itself isn't the problem, it's purely
declarative and was doing exactly what git told it to.

Rebuilt the tagging strategy end-to-end rather than just fixing the typo,
per explicit human direction: switched to a fixed `latest` tag (paired with
`imagePullPolicy: Always` on all 5 services - a mutable tag under
`IfNotPresent` is exactly what caused today's earlier node-caching pain) and
added a `restartedAt` annotation the CI now bumps on every push, since the
tag string no longer changes and Kubernetes doesn't restart running pods
just because a remote image moved. Chose a git-driven mechanism (CI commits
the bump to the config repo, same GitOps token it already had) over giving
CI direct cluster credentials - human's call, keeps the trust boundary
where it already was.

Verified the fixed pipeline for real: pushed a genuine source change
(inventory/payments JWT decoder fix, same root cause and same fix pattern
as orders' `g02.cpo2026.it` DNS-timeout bug from earlier - both services'
`SecurityConfig.kt` were byte-for-byte identical to orders' pre-fix version)
to `dev` and watched CI run end-to-end: build, test, push, verify, commit,
Argo CD sync. Caught a real gap in the verification step doing this - see
`docs/ai-error-log.md` (local, this session) for the full write-up. Separately,
one of the 3 nodes went `NotReady` mid-rollout (kubelet stopped posting
status) - unrelated to any of this, Kubernetes' own node-eviction handled it
without intervention.

**Potential Risks**

- The verification-gate bug (CI's own check passed while deploying stale
  content) is fixed in `ci.yaml` locally but not yet committed/pushed as of
  this entry - `inventory` and `payments` are still down live pending either
  a fresh CI run or a manual rebuild.
- `payments` had zero Keycloak-related env vars wired into its Deployment
  before this session (`KEYCLOAK_ISSUER_URI`, audience, etc. were all
  silently falling back to hardcoded defaults in `application.yaml`) - now
  fixed, but worth knowing this JWT feature (`feat/payments-jwt`) shipped
  without ever being wired to Helm values at all until now.
- `imagePullSecrets: acr-secret` (flagged twice already as broken/unused)
  is still in `values.yaml` - not fixed this session either.

**Confidence**

High for the root cause and the naming/pull-policy fixes - both directly
confirmed against the registry API. Medium for the CI pipeline overall -
the rollout-trigger mechanism is proven working end-to-end, but the
push-verification gate had one real gap already found live, and hasn't yet
been re-verified after being patched.

**Notes**

Second time today a CI/CD "success" signal (a passing verification step,
not just an unchecked one) turned out to be trusting the wrong thing rather
than actually being wrong - worth treating even an added safety check as
unproven until it's watched catch a real failure, not just assumed correct
because it was added deliberately.

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

---

### 2026-07-13 18:08

**Agent**

Codex

**Task**

Recover EuroTransit AKS ingress path and document the remaining DNS-only cutover.

**Files Modified**

- `platform/traefik/values.yaml`
- `platform/keycloak/keycloak-cr.yaml`
- `platform/keycloak/keycloak-ingress.yaml`
- `docs/ingress-dns-recovery-report-2026-07-13.md`
- `docs/azure-public-ip-root-cause-2026-07-13.md`
- `docs/ai-logs.md`

**Summary**

Pinned Traefik to the current Azure Public IP resource and DNS label, replaced
the Keycloak operator host-only ingress with an explicit `/auth` Traefik
Ingress, recovered flapping AKS nodes with Azure VM redeploy/restart actions,
temporarily scaled non-public controllers down to free pod capacity, restored
those controllers, and verified the public path through `134.112.8.66`.

**Verification**

- All AKS nodes are `Ready`.
- Traefik `LoadBalancer` remains `134.112.8.66`.
- EuroTransit, PostgreSQL, ArgoCD, cert-manager, monitoring, and Kafka pods are
  Ready.
- ArgoCD application `eurotransit` is `Synced` and `Healthy`.
- Direct tests with `--resolve` returned:
  - `/` -> `HTTP/2 200`
  - `/auth/` -> `HTTP/2 302`
  - `/api/v1/catalog/products` -> `HTTP/2 200`
  - `/api/v1/orders` -> `HTTP/2 401`
  - `argocd.g02.cpo2026.it/` -> `HTTP/2 200`

**Remaining Action**

Manual OVH DNS update only:

```text
g02.cpo2026.it        CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
argocd.g02.cpo2026.it CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

cert-manager certificates remain pending until public DNS points to the current
Traefik endpoint.
