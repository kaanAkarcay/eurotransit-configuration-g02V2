# Orders -> Inventory circuit breaker chaos plan

Date: 2026-07-14

This note defines the repository-side plan for a future Orders -> Inventory
network-partition experiment with Chaos Mesh. It does not claim that thresholds
are tuned in the live environment; the experiment has not been run, and the
current committed Orders image cannot yet produce reliable evidence from this
partition fault.

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
Chaos Mesh `partition` faults must not be used to tune thresholds until the
Orders image enforces an Inventory timeout through `@TimeLimiter`, a
programmatic TimeLimiter, or an HTTP client response timeout. A partition drops
packets instead of returning a fast connection refusal; without a timeout, Orders
calls can hang rather than record completed failures in the circuit breaker.

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
run. The experiment manifests under `platform/chaos-mesh/experiments` are also
outside the current `eurotransit` Application path, so merging this branch does
not automatically apply them.

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

The `duration: 60s` value is a fault-injection window, not a guarantee that the
circuit breaker had enough samples to make a decision. A run is useful only if
checkout load produces at least `minimum-number-of-calls` for `inventory-client`
inside the sliding window. If QPS is low, increase controlled load or run a
longer experiment rather than interpreting a no-open result as a tuned threshold.

The manifest currently uses `action: partition` and `mode: all`. This is a full
network blackhole, not a hard connection-refused failure. It is useful for a
future binary network-isolation validation after timeout enforcement exists. It
is not useful for current threshold tuning by itself, because the committed
Orders code can hang on dropped packets instead of producing fast failed calls.
For finer threshold tuning after the timeout prerequisite is fixed, run a
follow-up partial-failure experiment, for example with Chaos Mesh `fixed-percent`
against a subset of Inventory pods, so the observed failure rate can calibrate
`failure-rate-threshold` more gradually.

The project currently stores its Chaos Mesh experiments as suspended `Schedule`
resources. If the team standardizes on one-shot manual experiments later, a
Chaos Mesh `Workflow` can be cleaner than a suspended recurring Schedule. Do not
switch this artifact to `Workflow` until the live Chaos Mesh CRDs and supported
version are confirmed.

No circuit breaker thresholds are changed in this branch. Threshold changes must
be driven by runtime observations, not guessed from static configuration.

## Blast-radius risk

With the committed Orders code inspected on 2026-07-14, this partition can
saturate Orders rather than produce a clean circuit-breaker transition:

- no effective Orders -> Inventory timeout is applied;
- the configured Resilience4j bulkhead is not enforced unless the application
  wraps the call with `@Bulkhead` or equivalent;
- the configured `app.inventory.connection-pool` settings are not read by the
  committed Orders client code.

Therefore this manifest must stay suspended until timeout enforcement is in the
deployed Orders image. Run it only with controlled load, active monitoring, and a
clear abort path.

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

1. Treat this branch as repository preparation, not a live tuning result. The
   current `eurotransit` Argo CD Application tracks `deploy/charts/eurotransit`;
   it does not apply `platform/chaos-mesh` experiment manifests. Merging to
   `dev` also does not deploy to the current live Argo CD target (`main`).
2. Install or enable Chaos Mesh through the platform path:

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

4. Verify that the selectors match the intended pods before any fault is
   triggered:

   ```bash
   kubectl -n eurotransit get pods -l app.kubernetes.io/name=orders,app.kubernetes.io/instance=eurotransit
   kubectl -n eurotransit get pods -l app.kubernetes.io/name=inventory,app.kubernetes.io/instance=eurotransit
   ```

5. Verify the Orders runtime prerequisite before unsuspending. Do not continue
   unless the deployed Orders image enforces an Inventory timeout through
   `@TimeLimiter`, WebClient `responseTimeout`, or equivalent:

   ```bash
   kubectl -n eurotransit exec deploy/eurotransit-orders -- printenv SPRING_APPLICATION_JSON
   kubectl -n eurotransit port-forward deploy/eurotransit-orders 18080:8080
   curl -s http://localhost:18080/actuator/prometheus | grep 'resilience4j_circuitbreaker.*inventory-client'
   ```

   Confirm from the deployed application revision that Inventory timeout
   enforcement is implemented. Do not infer this only from
   `SPRING_APPLICATION_JSON`.

6. Run a short smoke check before the full load experiment. Use a 10-15 second
   one-shot/manual run or temporarily patch a copy of the Schedule duration to
   `15s`, then confirm that only the intended Orders -> Inventory traffic is
   affected. Resuspend or delete the smoke object before continuing.
7. Generate controlled checkout load from outside the cluster or from a temporary
   load pod. Keep the load steady enough to exceed `minimum-number-of-calls: 5`
   in the circuit breaker sliding window during the fault. Record the actual
   request rate; if fewer than 5 Inventory calls are observed in the window, the
   experiment did not test breaker opening.
8. Unsuspend for one controlled run:

   ```bash
   kubectl -n chaos-mesh patch schedule orders-inventory-network-failure --type=merge -p '{"spec":{"suspend":false}}'
   ```

9. Watch metrics and events during the 60 second partition and for at least 2
   minutes after it ends.
10. Resuspend immediately after the run:

   ```bash
   kubectl -n chaos-mesh patch schedule orders-inventory-network-failure --type=merge -p '{"spec":{"suspend":true}}'
   kubectl get schedule,networkchaos,podchaos -A
   ```

## Threshold decision guide

Do not modify thresholds until at least one controlled run has evidence.

- If the breaker does not open during this full partition, do not lower
  `failure-rate-threshold`. A full partition should produce a 100% failure rate
  only after calls actually complete as failures. Diagnose timeout enforcement,
  recorded-call count, Resilience4j annotations/wrapping, metrics labels, and
  load duration first.
- If the breaker opens on a very small transient blip and causes unnecessary
  fail-fast behavior, raise `minimum-number-of-calls` from `5` toward `10` before
  changing the failure-rate threshold.
- If the breaker opens correctly but recovery probes fail after Inventory is
  healthy, increase `permitted-number-of-calls-in-half-open-state` from `3` to
  `5` so half-open has a better sample.
- If the breaker stays OPEN too long after Inventory recovers, reduce
  `wait-duration-in-open-state` from `10s` to `5s`.
- If latency, rather than completed failed calls, is the dominant symptom after
  timeout enforcement is added, add or tune `slow-call-duration-threshold` and
  `slow-call-rate-threshold` for `inventory-client` based on observed p95/p99
  Inventory call latency.
- If the full partition only proves the binary failure path, run a partial
  `fixed-percent` experiment before changing `failure-rate-threshold`; threshold
  tuning is stronger when based on graded failure rates rather than one
  all-down scenario.

## Rollback

Repository rollback:

- Revert the commit that adds the experiment manifest and this runbook.
- Argo CD will remove the desired draft manifest only if it is later added to a
  reconciled path. With the current repository layout, `platform/chaos-mesh`
  experiment manifests are applied manually or by a separate platform GitOps
  flow.

Runtime rollback:

```bash
kubectl -n chaos-mesh patch schedule orders-inventory-network-failure --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n chaos-mesh delete schedule orders-inventory-network-failure
kubectl get networkchaos,podchaos -A
```

If a threshold change is later made and causes regressions, revert the Helm value
commit and let Argo CD reconcile the previous `SPRING_APPLICATION_JSON`.
