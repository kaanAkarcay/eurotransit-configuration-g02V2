# Runtime resilience configuration

Date: 2026-07-13

This note records the configuration-side work for the two active resilience tasks:

- Configure timeout + retry + backoff + jitter for Orders -> Inventory.
- Configure bulkhead isolation through separate downstream connection pools.

## Source requirements

- `docs/dod.md` requires timeout, bounded retry, and circuit breaker on Orders -> Inventory; circuit breaker and fallback on Orders -> Payments; an independent circuit breaker on Payments -> gateway; isolated connection pools for Orders -> Inventory, Orders -> Payments, and Payments -> gateway; and timeout + exponential backoff + jitter on every remote call.
- `docs/architecture-design.md` and `docs/eurotransit-contract.md` define three separate synchronous failure domains: Orders -> Inventory, Orders -> Payments, and Payments -> gateway.

## Configuration now owned by Helm

`deploy/charts/eurotransit/values.yaml` now declares runtime resilience settings for:

- `orders.springApplicationJson.resilience4j.circuitbreaker.instances.inventory-client`
- `orders.springApplicationJson.resilience4j.timelimiter.instances.inventory-client`
- `orders.springApplicationJson.resilience4j.retry.instances.inventory-client`
- `orders.springApplicationJson.resilience4j.bulkhead.instances.inventory-client`
- `orders.springApplicationJson.app.inventory.connection-pool`
- `orders.springApplicationJson.resilience4j.circuitbreaker.instances.payments-client`
- `orders.springApplicationJson.resilience4j.timelimiter.instances.payments-client`
- `orders.springApplicationJson.resilience4j.retry.instances.payments-client`
- `orders.springApplicationJson.resilience4j.bulkhead.instances.payments-client`
- `orders.springApplicationJson.app.payments.connection-pool`
- `payments.springApplicationJson.resilience4j.circuitbreaker.instances.payment-gateway`
- `payments.springApplicationJson.resilience4j.bulkhead.instances.payment-gateway`
- `payments.springApplicationJson.app.gateway.connection-pool`

The Orders Deployment renders these values into `SPRING_APPLICATION_JSON`, so ArgoCD owns the circuit breaker, timeout, retry, backoff, and jitter policy instead of relying only on defaults bundled inside the container image.

The Payments Deployment also renders `SPRING_APPLICATION_JSON` for the gateway circuit breaker/bulkhead policy and sets `GATEWAY_URL` from Helm values.

## Bulkhead configuration boundary

This branch now defines the configuration-side bulkhead contract for the three
synchronous downstream edges:

- `orders-inventory`
- `orders-payments`
- `payments-gateway`

Each pool has explicit GitOps-owned limits:

```yaml
max-connections: 20
pending-acquire-max-count: 50
pending-acquire-timeout: 500ms
```

The same downstream edges also have Resilience4j semaphore bulkheads:

```yaml
max-concurrent-calls: 20
max-wait-duration: 0ms
```

The configuration repo can define these runtime limits, but true connection-pool
isolation is enforced only if the application process creates distinct HTTP
client connection pools per downstream edge.

For the DoD line "Bulkhead: isolated connection pools for each downstream service", the application image must bind the pool settings for:

- Orders -> Inventory
- Orders -> Payments
- Payments -> gateway

The current application source was inspected before closing the configuration
work:

- Orders `InventoryClient` builds from the injected shared `WebClient.Builder`.
- Orders `PaymentClient` builds from the injected shared `WebClient.Builder`.
- Payments `HttpPaymentGateway` uses `HttpClient.create()` and only binds
  `app.gateway.timeout`.

Therefore this branch completes the configuration-side task, but current images
will enforce only the properties already consumed by the application and
Resilience4j annotations. Full separate Reactor Netty pool enforcement requires
the matching application change to bind the `connection-pool` settings and build
named `ConnectionProvider` instances per downstream edge.

## Validation commands

Render the chart locally:

```bash
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit
```

Confirm the rendered Orders Deployment contains:

```bash
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit \
  | yq '. | select(.kind == "Deployment" and .metadata.name == "eurotransit-orders") | .spec.template.spec.containers[0].env[] | select(.name == "SPRING_APPLICATION_JSON")'
```

Confirm the rendered Payments Deployment contains:

```bash
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit \
  | yq '. | select(.kind == "Deployment" and .metadata.name == "eurotransit-payments") | .spec.template.spec.containers[0].env[] | select(.name == "SPRING_APPLICATION_JSON" or .name == "GATEWAY_URL")'
```

After ArgoCD sync:

```bash
kubectl -n eurotransit get deploy eurotransit-orders eurotransit-payments
kubectl -n eurotransit exec deploy/eurotransit-orders -- printenv SPRING_APPLICATION_JSON
kubectl -n eurotransit exec deploy/eurotransit-payments -- printenv SPRING_APPLICATION_JSON
```

## Validation report - 2026-07-13

### Local checks

The Helm chart was linted locally:

```bash
helm lint deploy/charts/eurotransit
```

Result:

```text
1 chart(s) linted, 0 chart(s) failed
```

The chart also rendered successfully:

```bash
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit
```

The rendered Orders Deployment includes `SPRING_APPLICATION_JSON` with the
`inventory-client` and `payments-client` Resilience4j settings, including
bulkhead limits and separate connection-pool configuration blocks.

The rendered Payments Deployment includes `GATEWAY_URL` and
`SPRING_APPLICATION_JSON` with the `payment-gateway` circuit-breaker, bulkhead,
and connection-pool configuration.

### Cluster-side dry-run

The rendered Helm output was validated against the live AKS API server without
applying it:

```bash
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit \
  | kubectl -n eurotransit apply --dry-run=server -f -
```

Result: passed. The API server accepted all rendered resources as
`configured (server dry run)`:

- Services
- Deployments
- Ingress
- Traefik Middleware
- PrometheusRule
- ServiceMonitors

This proves the current branch's Kubernetes manifests are accepted by the live
cluster API, including the CRDs already installed in the cluster.

### Live ArgoCD state

The live ArgoCD Application was checked:

```bash
kubectl -n argocd get applications.argoproj.io eurotransit \
  -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}{.status.sync.revision}{"\n"}{.spec.source.targetRevision}{"\n"}{.spec.source.path}{"\n"}'
```

Observed state:

```text
Synced
Healthy
5f5ede195b2f83930b8bdcbcd0affab1044e075c
main
deploy/charts/eurotransit
```

Important: the resilience configuration changes in this branch are not yet live
because ArgoCD is currently synced to `main`, not to this feature branch.

### Live Deployment state before merge

The live Deployments are currently available:

```bash
kubectl -n eurotransit get deploy eurotransit-orders eurotransit-payments
```

Observed:

```text
NAME                   READY   UP-TO-DATE   AVAILABLE
eurotransit-orders     1/1     1            1
eurotransit-payments   1/1     1            1
```

However, the live Deployment YAML still does not include this branch's new
environment variables:

- `eurotransit-orders` does not yet contain `SPRING_APPLICATION_JSON`.
- `eurotransit-payments` does not yet contain `GATEWAY_URL`.
- `eurotransit-payments` does not yet contain `SPRING_APPLICATION_JSON`.

This is expected before merge/sync, because the live ArgoCD revision is still
`main`.

### Hidden issue found during live check

The live pods were ready at the time of re-check, but recent restarts were
observed:

```text
eurotransit-orders     Restart Count: 3
eurotransit-payments   Restart Count: 7
```

Pod events showed liveness/readiness failures:

```text
Liveness probe failed: context deadline exceeded
Readiness probe failed: context deadline exceeded
Startup probe failed: connect: connection refused
```

The previous container logs showed graceful shutdown after the probes caused a
restart. This is separate from the resilience configuration change, but it is a
production-relevant risk: the current probe timeout is very short (`timeoutSeconds:
1` by Kubernetes default because the Helm probes do not set it explicitly), and
the services can take long enough to respond that kubelet restarts them.

Recommended follow-up:

- Explicitly set a less aggressive probe timeout, for example `timeoutSeconds: 3`.
- Consider raising `failureThreshold` or `startupProbe.failureThreshold` for the
  slower Spring Boot services.
- Keep liveness probes limited to local process health; do not add downstream
  dependencies to liveness.

### Post-merge verification

After this branch is merged to the ArgoCD target branch and synced, verify the
new environment variables are live:

```bash
kubectl -n eurotransit describe deploy eurotransit-orders
kubectl -n eurotransit describe deploy eurotransit-payments
kubectl -n eurotransit exec deploy/eurotransit-orders -- printenv SPRING_APPLICATION_JSON
kubectl -n eurotransit exec deploy/eurotransit-payments -- printenv GATEWAY_URL
kubectl -n eurotransit exec deploy/eurotransit-payments -- printenv SPRING_APPLICATION_JSON
```

Expected:

- Orders contains Resilience4j settings for `inventory-client` and
  `payments-client`, including `bulkhead.instances`.
- Orders contains `app.inventory.connection-pool.name=orders-inventory` and
  `app.payments.connection-pool.name=orders-payments`.
- Payments contains `GATEWAY_URL=http://payment-gateway-sim:8080`.
- Payments contains Resilience4j settings for `payment-gateway`, including
  `bulkhead.instances`.
- Payments contains `app.gateway.connection-pool.name=payments-gateway`.
