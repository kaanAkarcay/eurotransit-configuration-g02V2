# Deployment Strategies

## Purpose and safety model

EuroTransit uses GitOps: application CI builds an image and updates this configuration repository; Argo CD renders the Helm chart and reconciles the cluster. CI does not need cluster credentials.

The chart supports standard Kubernetes rolling Deployments plus Argo Rollouts Canary and Blue/Green strategies. All progressive modes are inactive by default. Merging the default values does not create a Rollout and does not change the active public routes.

```yaml
deploymentStrategies:
  frontend: standard
  catalog: standard
  orders: standard

blueGreen:
  inventory:
    enabled: false
  payments:
    enabled: false
```

## Strategy matrix

| Service | Standard | Canary | Blue/Green | Selector |
|---|---:|---:|---:|---|
| Frontend | Yes | Yes | Yes | `deploymentStrategies.frontend` |
| Catalog | Yes | Yes | Yes | `deploymentStrategies.catalog` |
| Orders | Yes | Yes | Yes | `deploymentStrategies.orders` |
| Inventory | Yes | No | Yes | `blueGreen.inventory.enabled` |
| Payments | Yes | No | Yes | `blueGreen.payments.enabled` |
| Notifications | Yes | No | No | none |
| Payment gateway simulator | Yes | No | No | none |

The three enums accept only `standard`, `canary`, or `blueGreen`. Helm schema validation rejects any other value. Inventory and Payments have one progressive option, so each uses one boolean and cannot enter two strategies simultaneously.

Notifications and the payment gateway simulator remain normal rolling Deployments. Databases, Kafka, Keycloak and operators retain their native/operator-managed lifecycle.

## Architecture

Argo Rollouts v1.9.0 is installed from pinned Helm chart `argo-rollouts` 2.41.0 by `platform/argocd/argo-rollouts-application.yaml`.

Every progressive Rollout uses `workloadRef` to copy the complete pod template from the existing Deployment. The chart therefore has one source for ports, probes, environment variables, Secrets, security settings and image configuration.

### Canary

Canary is limited to public HTTP services:

```text
Traefik IngressRoute
        |
        v
weighted TraefikService (weights owned by Argo Rollouts)
        |-------------------------------|
        v                               v
stable Kubernetes Service       canary Kubernetes Service
        |                               |
        v                               v
stable ReplicaSet                candidate ReplicaSet
```

The direct Kubernetes Ingress path is removed only for the service currently in Canary mode. Its `IngressRoute` uses the existing public host and path. The Frontend catch-all route has lower priority than Catalog and Orders routes.

The TraefikService intentionally contains no weights in Git. Argo Rollouts writes them at runtime. Committing weights would make Argo CD self-heal fight the Rollouts controller.

### Blue/Green

```text
existing active Service ----------------> active ReplicaSet
new preview Service --------------------> preview ReplicaSet
```

The existing Service remains the active endpoint, so public routes and internal DNS names do not change. Promotion atomically moves that Service to the preview ReplicaSet. The old ReplicaSet remains available for 1800 seconds after promotion.

Inventory and Payments receive no public Ingress or private Traefik entrypoint. Their preview Services are reachable only inside the cluster.

## Argo CD ownership and sync order

Argo Rollouts mutates these runtime fields:

- `rollouts-pod-template-hash` in stable/canary/active/preview Service selectors;
- the `argo-rollouts.argoproj.io/managed-by-rollouts` annotation used to restore resources during Rollout deletion;
- TraefikService weights;
- the Rollout workload-generation annotation.

The EuroTransit Argo CD Application ignores only those fields and keeps `selfHeal` for everything else. It also uses `ApplyOutOfSyncOnly=true`, `RespectIgnoreDifferences=true`, and `PruneLast=true`.

Activation uses sync waves:

1. wave `-2`: candidate/preview Services and the dormant weighted TraefikService exist;
2. wave `-1`: the Rollout adopts the existing stable Deployment, initializes traffic to the stable ReplicaSet, and becomes healthy;
3. wave `0`: the Canary IngressRoute and the direct Ingress-path removal are reconciled; any brief overlap still targets the same stable revision;
4. wave `1`: the referenced Deployment is set to zero replicas.

This order prevents a gap in active endpoints. When returning to `standard`, Argo CD restores and waits for the Deployment before pruning the Rollout. Argo Rollouts then restores the Service selector it managed.

## Mandatory prerequisites

Do not enable a progressive strategy until all items below are true:

1. The standard workload is already deployed and healthy.
2. The `argo-rollouts` Argo CD Application is synced and healthy.
3. `rollouts.argoproj.io`, `analysisruns.argoproj.io` and `analysistemplates.argoproj.io` CRDs exist.
4. The Argo Rollouts controller is healthy in namespace `argo-rollouts`.
5. The Argo CD ownership rules in `eurotransit-application.yaml` are deployed.
6. CI has produced the immutable digest of the exact tested image.
7. The current stable version is already pinned in `image.digest` while still in standard mode.
8. Database changes are backward compatible with stable and candidate versions running together.
9. The operator knows the smoke checks, promotion decision owner and rollback command.
10. The cluster has enough capacity for stable and candidate ReplicaSets during the strategy.

Helm blocks a progressive render unless the selected service has a digest matching `sha256:<64 lowercase hexadecimal characters>`. It never invents or resolves a digest.

The feature implementation already pins the five stable digests read from the
healthy `Lab02cluster` pods on 2026-07-14. The application CI change on its
`feature/canary` branch propagates the verified registry digest for every future
Frontend, Catalog, Orders, Inventory and Payments build on `main`. Before the
feature branches are merged, recheck the live digest if any service has been
released again.

### Platform bootstrap (one time)

The files under `platform/argocd` are bootstrap manifests; the EuroTransit Application watches only the application Helm chart and does not install sibling Applications. An authorized platform operator must therefore review and apply both manifests once:

```powershell
kubectl diff -f platform/argocd/argo-rollouts-application.yaml
kubectl apply -f platform/argocd/argo-rollouts-application.yaml

kubectl diff -f platform/argocd/eurotransit-application.yaml
kubectl apply -f platform/argocd/eurotransit-application.yaml
```

These are future activation commands, not local validation commands. Applying the first manifest installs a new controller and CRDs; applying the second changes Argo CD reconciliation ownership. Both require human review and cluster-change authorization. After applying them, allow automated sync to finish and verify:

```powershell
kubectl get applications.argoproj.io -n argocd argo-rollouts eurotransit
kubectl get deployment -n argo-rollouts argo-rollouts
kubectl get crd rollouts.argoproj.io analysisruns.argoproj.io analysistemplates.argoproj.io
```

## Activation procedure

The first creation of any Argo Rollout skips Canary/Blue-Green update steps because no stable Rollout revision exists yet. For that reason, strategy activation and candidate introduction must never be the same Git change.

### Stage 1: pin the currently running stable image

While the service is still standard, obtain the digest from the successful CI build or registry and set it without changing the strategy:

```yaml
orders:
  image:
    repository: lab02clusterregistry.azurecr.io/eurotransit/orders
    tag: latest       # compatibility fallback; ignored while digest is set
    digest: sha256:<verified-stable-digest>

deploymentStrategies:
  orders: standard
```

Merge this change and verify that the standard Deployment is healthy and runs the expected digest.

This stage is already prepared in the current configuration feature branch. It
must be repeated only if the live stable image changes before these values reach
`main` or if a future service is returned to tag-based configuration.

### Stage 2: adopt the stable baseline

In a new reviewed commit, change only the strategy selector. Do not change the image, `restartedAt`, environment, probes or any other pod-template field.

Canary example:

```yaml
deploymentStrategies:
  orders: canary
```

Blue/Green examples:

```yaml
deploymentStrategies:
  catalog: blueGreen

blueGreen:
  inventory:
    enabled: true
```

After Argo CD syncs, confirm:

```powershell
kubectl get rollout -n eurotransit
kubectl argo rollouts get rollout eurotransit-orders -n eurotransit --watch
kubectl get deployment eurotransit-orders -n eurotransit
kubectl get service eurotransit-orders eurotransit-orders-canary -n eurotransit
```

Expected state: the Rollout is Healthy, the Rollout owns a stable ReplicaSet, and the referenced Deployment has zero replicas. This is baseline adoption, not a candidate release.

### Stage 3: introduce the candidate

After the application CI feature reaches `main`, merge a tested application
change for the selected service. CI pushes the image, verifies the registry
digest, and commits that digest to configuration `main`; no manual values edit is
required. The resulting Git commit changes the service digest only as the
release identity. Do not use `latest`, `canary`, or another mutable tag instead.

```yaml
orders:
  image:
    digest: sha256:<verified-candidate-digest>
```

The zero-replica Deployment remains the pod-template source. Argo Rollouts observes its new generation and creates the candidate ReplicaSet.

## Canary operation

Every candidate Pod must remain Ready for
`progressiveDelivery.minReadySeconds` (20 seconds by default) before Argo
Rollouts considers it available. This filters out readiness that succeeds only
briefly during startup.

`progressDeadlineSeconds` marks a Rollout that stops progressing, but this chart
does not set `progressDeadlineAbort: true`. Exceeding the deadline therefore
does not promise an automatic rollback. An authorized operator must inspect the
Rollout, then explicitly promote, retry or abort it. Manual pauses are an
intentional part of the strategy and are not a metric-based rollback policy.

The configured sequence is:

1. set candidate traffic to `canary.<service>.initialWeight` (default 10%);
2. pause indefinitely;
3. after manual promotion, set candidate traffic to 100%;
4. mark the candidate stable and retain the old ReplicaSet for the configured delay.

During the pause, validate at least:

- rollout and pod readiness;
- HTTP 5xx rate and latency for the affected route;
- application errors and restart counts split by `app.kubernetes.io/track`;
- service-specific business behavior;
- for Orders, order acceptance and completion without duplicate side effects.

Use controlled synthetic traffic if natural traffic is too low to make the 10% sample meaningful.

Promote through the Argo CD Rollout `resume` action or, if the plugin is installed:

```powershell
kubectl argo rollouts promote eurotransit-orders -n eurotransit
```

Abort before promotion if validation fails:

```powershell
kubectl argo rollouts abort eurotransit-orders -n eurotransit
```

Promotion and abort mutate live Rollout state and therefore require operator authorization. They are documented here but are not run by configuration validation.

## Blue/Green operation

When the candidate becomes ready, the Rollout remains paused because `autoPromotionEnabled: false`. Test the preview Service without changing production traffic.

Example local tunnel for a backend preview:

```powershell
kubectl port-forward -n eurotransit service/eurotransit-inventory-preview 18080:8080
```

Run health and service-specific smoke tests through the preview endpoint. Promote only when the candidate digest, logs, readiness and compatibility checks are correct:

```powershell
kubectl argo rollouts promote eurotransit-inventory -n eurotransit
```

Abort if checks fail:

```powershell
kubectl argo rollouts abort eurotransit-inventory -n eurotransit
```

After promotion, the old active ReplicaSet remains scaled for 30 minutes. A Git revert to a revision inside the configured rollback window is fast-tracked by Argo Rollouts.

## Returning to standard

Do not switch directly from `canary` to `blueGreen` or from `blueGreen` to `canary`. Return to `standard`, wait for reconciliation, and only then adopt the other strategy.

Before returning to standard:

- after a successful promotion, keep the promoted digest in Git;
- after an abort, first revert Git to the stable digest and wait until the Rollout is Healthy.

Then change the enum to `standard` or the Inventory/Payments boolean to `false`. `PruneLast` ensures that the standard Deployment is restored and healthy before the Rollout is deleted.

Verify:

```powershell
kubectl get deployment,rollout,service -n eurotransit
kubectl get endpointslice -n eurotransit -l kubernetes.io/service-name=eurotransit-orders
```

Expected state: the Deployment has its configured replica count, no Rollout remains for that service, the normal Service has ready endpoints, and no canary/preview Service remains.

## Mix and match

Each workload selector is independent. For example, Frontend can run Canary while Catalog runs Blue/Green, Orders remains standard, and Inventory uses Blue/Green. This is supported technically but should be activated incrementally so capacity and failures can be attributed to one change.

Avoid changing multiple services on the synchronous Orders → Inventory → Payments path in one release unless compatibility has been verified. Argo Rollouts coordinates one workload at a time; it does not implement a distributed transaction across service promotions.

## Consistency constraints

Stable and candidate versions share production dependencies. No separate database or Kafka cluster is created for the demonstration.

- Schema changes follow expand/contract and stay backward compatible through the rollback window.
- Preview requests use the same production databases and dependencies as the stable workload. Smoke tests must therefore use controlled data and be idempotent, reversible, or read-only where possible.
- Orders and Inventory stable/candidate instances retain their existing Kafka consumer group, so one group member processes each event and the progressive configuration does not duplicate delivery.
- HTTP weighting and Blue/Green Services do not route Kafka records. While both ReplicaSets run, Kafka can assign partitions and real events to candidate consumers before HTTP promotion. The candidate must therefore be backward compatible and safe for production events from the moment it starts.
- A fully inactive Kafka preview would require an application-level consumer lifecycle control that does not currently exist. This chart does not invent a second consumer group or an undocumented environment variable because either could duplicate side effects or diverge from the application contract.
- Payments preview tests use safe/idempotent requests and the existing gateway policy.
- Notifications remains rolling; the current implementation logs notification activity rather than sending real email.

## Automated analysis status

Automatic metric promotion is intentionally not enabled. The cluster currently has monitoring CRDs, but Prometheus was observed at zero replicas and there is no validated stable-versus-candidate PromQL contract.

Before adding an `AnalysisTemplate`:

1. restore and validate Prometheus;
2. define queries using the stable/candidate track labels;
3. test success thresholds with a healthy candidate;
4. test failure thresholds with a deliberately broken candidate;
5. make missing/empty data fail or pause, never pass;
6. define minimum sample sizes and an inconclusive/manual path.

Until then, promotion is manual and evidence-based.

## Local validation only

Default rendering must contain zero progressive resources:

```powershell
helm lint deploy/charts/eurotransit
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit
```

The five progressive-capable services already have valid stable digests, so an
activation simulation needs only a temporary strategy override:

```powershell
helm template eurotransit deploy/charts/eurotransit `
  --namespace eurotransit `
  --set deploymentStrategies.orders=canary
```

Also render every supported single mode and at least one mixed configuration. Verify resource names, Service ports, selectors, Ingress path exclusivity, sync waves, and the absence of duplicate Kubernetes identities. These commands render locally; they do not apply anything to the cluster.
