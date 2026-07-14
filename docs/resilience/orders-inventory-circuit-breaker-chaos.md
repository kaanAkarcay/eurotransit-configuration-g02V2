# Orders -> Inventory circuit breaker chaos plan

Date: 2026-07-14

This note defines the repository-side plan for tuning the Orders -> Inventory
circuit breaker with Chaos Mesh. It does not claim that the thresholds are tuned
in the live environment; the experiment has not been run.

## Prerequisite findings

### Orders timeout effectiveness

The configuration repo renders this block into the Orders Deployment through
`SPRING_APPLICATION_JSON`:

```yaml
resilience4j:
  timelimiter:
    instances:
      inventory-client:
        timeout-duration: 2s
```

The committed Orders application source inspected in the sibling application
repo at `HEAD` on 2026-07-14 has:

- `@CircuitBreaker(name = "inventory-client")` on `InventoryClient.reserveSeats`.
- No committed `@TimeLimiter` on `InventoryClient.reserveSeats`.
- No committed `@Retry` on `InventoryClient.reserveSeats`.
- `timeout-duration` still present in `backend/orders/src/main/resources/application.yaml`.

Therefore `timeout-duration` is configuration-bound but not currently effective
for the committed Orders Inventory call through Resilience4j annotations. It
creates a TimeLimiter instance configuration if the application asks for it, but
it does not by itself wrap a suspend function or enforce a response deadline.
Latency-only Chaos Mesh experiments must not be used to tune timeout-sensitive
thresholds until the Orders image enforces an Inventory timeout through
`@TimeLimiter`, a programmatic TimeLimiter, or an HTTP client response timeout.

### Resilience4j minimum call default

Resilience4j 2.2.0 documents `minimumNumberOfCalls` with a default value of
`100`. The EuroTransit Helm values intentionally override the
`inventory-client` instance to `minimum-number-of-calls: 5`, which makes small
controlled experiments observable without requiring 100 failed calls.

### Chaos Mesh deployment workflow

The repository contains `platform/argocd/chaos-mesh-application.yaml`, an Argo CD
Application for the official Chaos Mesh Helm chart. Existing Chaos Mesh
experiments are stored under `platform/chaos-mesh/experiments` as suspended draft
Schedules with hypotheses, rollback notes, and validation steps.

The live cluster check on 2026-07-14 found:

```text
kubectl get ns chaos-mesh
Error from server (NotFound): namespaces "chaos-mesh" not found

kubectl get crd schedules.chaos-mesh.org networkchaos.chaos-mesh.org podchaos.chaos-mesh.org
Error from server (NotFound): ... not found

kubectl -n argocd get applications.argoproj.io chaos-mesh eurotransit -o wide
eurotransit   Synced   Healthy   0a8fa28879632e81c2284753c264509714d9813f
Error from server (NotFound): applications.argoproj.io "chaos-mesh" not found
```

Chaos Mesh is absent because the live Argo CD cluster has no `chaos-mesh`
Application, and the Chaos Mesh namespace/CRDs are not installed. This repo has
the desired Application manifest, but it is not currently part of the live
`eurotransit` Application path (`deploy/charts/eurotransit`) and must be
bootstrapped separately or included in an app-of-apps flow before experiments can
run.

## Repository change

`platform/chaos-mesh/experiments/orders-inventory-network-failure-schedule.yaml`
adds a suspended `NetworkChaos` Schedule. It partitions traffic from Orders pods
to Inventory pods for 60 seconds and is deliberately inert by default:

```yaml
spec:
  suspend: true
  type: NetworkChaos
  networkChaos:
    action: partition
    direction: to
```

This follows the existing project pattern for Chaos Mesh experiments:

- Store experiment manifests under `platform/chaos-mesh/experiments`.
- Use `Schedule` resources with `suspend: true`.
- Add hypothesis, metrics, rollback, and validation comments at the top of the
  manifest.
- Do not auto-execute chaos from Git.

No circuit breaker thresholds are changed in this branch. Threshold changes must
be driven by runtime observations, not guessed from static configuration.

## Success criteria

Run the experiment only after Chaos Mesh is installed and the Orders Inventory
timeout prerequisite is satisfied. A successful tuning run must show:

- `inventory-client` transitions from CLOSED to OPEN during the injected fault.
- Failed calls rise until the breaker opens.
- Not-permitted calls appear while the breaker is OPEN.
- Orders pods do not restart due to liveness failures.
- Inventory returns to normal RED metrics after the partition ends.
- Orders stuck in non-terminal states drain or are explicitly accounted for.
- No oversell or duplicate reservation is observed.

## Metrics to monitor

Use the exact labels exposed by the live `/actuator/prometheus` endpoint, but
start with these Prometheus families when present:

```promql
resilience4j_circuitbreaker_state{name="inventory-client"}
resilience4j_circuitbreaker_calls_seconds_count{name="inventory-client"}
resilience4j_circuitbreaker_failure_rate{name="inventory-client"}
resilience4j_circuitbreaker_slow_call_rate{name="inventory-client"}
resilience4j_circuitbreaker_not_permitted_calls_total{name="inventory-client"}
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{namespace="eurotransit", uri!~"/actuator.*"}[5m])))
sum(rate(http_server_requests_seconds_count{namespace="eurotransit", status=~"5..", uri!~"/actuator.*"}[2m]))
kube_pod_container_status_restarts_total{namespace="eurotransit", pod=~"eurotransit-(orders|inventory).*"}
```

Also inspect Orders logs for `CallNotPermittedException`, WebClient connection
errors, and Stage 1 retry/terminal-state behavior.

## Runtime execution plan

1. Merge this branch to the Argo CD target branch used by the configuration
   repository.
2. Install or enable Chaos Mesh:

   ```bash
   kubectl apply -f platform/argocd/chaos-mesh-application.yaml
   kubectl -n argocd wait application/chaos-mesh --for=jsonpath='{.status.health.status}'=Healthy --timeout=10m
   kubectl get crd schedules.chaos-mesh.org networkchaos.chaos-mesh.org podchaos.chaos-mesh.org
   ```

3. Apply the draft experiment manifest only after the CRDs exist:

   ```bash
   kubectl apply -f platform/chaos-mesh/experiments/orders-inventory-network-failure-schedule.yaml
   kubectl -n chaos-mesh get schedule orders-inventory-network-failure
   ```

4. Verify the Orders runtime prerequisite before unsuspending:

   ```bash
   kubectl -n eurotransit exec deploy/eurotransit-orders -- printenv SPRING_APPLICATION_JSON
   kubectl -n eurotransit port-forward deploy/eurotransit-orders 18080:8080
   curl -s http://localhost:18080/actuator/prometheus | grep 'resilience4j_circuitbreaker.*inventory-client'
   ```

   Then confirm from the deployed application revision that Inventory timeout
   enforcement is implemented. Do not infer this only from
   `SPRING_APPLICATION_JSON`.

5. Generate controlled checkout load from outside the cluster or from a temporary
   load pod. Keep the load steady enough to exceed `minimum-number-of-calls: 5`
   in the circuit breaker sliding window.
6. Unsuspend for one controlled run:

   ```bash
   kubectl -n chaos-mesh patch schedule orders-inventory-network-failure --type=merge -p '{"spec":{"suspend":false}}'
   ```

7. Watch metrics and events during the 60 second partition and for at least 2
   minutes after it ends.
8. Resuspend immediately after the run:

   ```bash
   kubectl -n chaos-mesh patch schedule orders-inventory-network-failure --type=merge -p '{"spec":{"suspend":true}}'
   kubectl get schedule,networkchaos,podchaos -A
   ```

## Threshold decision guide

Do not modify thresholds until at least one controlled run has evidence.

- If the breaker does not open during confirmed Inventory unavailability and at
  least 5 calls occurred in the sliding window, lower
  `failure-rate-threshold` from `50` to `40` or increase load/test duration if
  the sample was too small.
- If the breaker opens on a very small transient blip and causes unnecessary
  fail-fast behavior, raise `minimum-number-of-calls` from `5` toward `10` before
  changing the failure-rate threshold.
- If the breaker opens correctly but recovery probes fail after Inventory is
  healthy, increase `permitted-number-of-calls-in-half-open-state` from `3` to
  `5` so half-open has a better sample.
- If the breaker stays OPEN too long after Inventory recovers, reduce
  `wait-duration-in-open-state` from `10s` to `5s`.
- If latency, rather than hard failure, is the dominant symptom after timeout
  enforcement is added, add or tune `slow-call-duration-threshold` and
  `slow-call-rate-threshold` for `inventory-client` based on observed p95/p99
  Inventory call latency.

## Rollback

Repository rollback:

- Revert the commit that adds the experiment manifest and this runbook.
- Argo CD will remove the desired draft manifest if it is part of the reconciled
  path.

Runtime rollback:

```bash
kubectl -n chaos-mesh patch schedule orders-inventory-network-failure --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n chaos-mesh delete schedule orders-inventory-network-failure
kubectl get networkchaos,podchaos -A
```

If a threshold change is later made and causes regressions, revert the Helm value
commit and let Argo CD reconcile the previous `SPRING_APPLICATION_JSON`.
