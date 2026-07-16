# Orders -> Payments circuit-breaker tuning

Date: 2026-07-16

This runbook covers live validation and tuning evidence for the
`payments-client` circuit breaker in Orders.

## Hypothesis

When Payments becomes slower than Orders' configured payment timeout, Orders
records timeout failures for `payments-client` and opens the circuit breaker
after the configured minimum sample size and failure-rate threshold are reached.
New affected orders should fail through the payment fallback path instead of
hanging indefinitely.

## Repository prerequisites

- Orders `PaymentClient` uses Reactor Netty connect/response timeouts.
- Orders wraps the real suspend payment call with Resilience4j
  `executeSuspendFunction`.
- HTTP 402 from Payments remains a business decline and is not counted as an
  infrastructure failure.
- Helm renders `resilience4j.timelimiter.instances.payments-client.timeout-duration`.
- Helm renders `resilience4j.circuitbreaker.instances.payments-client`.
- Orders service-token configuration is enabled so Orders can call Payments.
- Chaos Mesh CRDs exist for `networkchaos.chaos-mesh.org`.

## Experiment manifest

Use the one-shot manifest:

```bash
kubectl apply -f platform/chaos-mesh/experiments/orders-payments-network-latency.yaml
```

It injects 7s latency from Orders pods to Payments pods for 60s. The latency is
intentionally above the 6s Orders payment timeout configured in Helm, so the
breaker sees bounded timeout failures instead of indefinitely hanging calls.

## Load generation

```bash
ORDERS_AUTH_TOKEN='<orders-audience-token>' \
  BASE_URL='https://g02.cpo2026.it' \
  k6 run tools/k6/orders-payments-circuit-breaker.js
```

The generated checkout load must create at least
`minimum-number-of-calls` samples inside the circuit-breaker sliding window.

## Metrics to monitor

```promql
resilience4j_circuitbreaker_state{name="payments-client"}
rate(resilience4j_circuitbreaker_calls_seconds_count{name="payments-client"}[1m])
rate(http_server_requests_seconds_count{service="eurotransit-orders", uri="/api/v1/orders", method="POST"}[1m])
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{service="eurotransit-orders", uri="/api/v1/orders", method="POST"}[5m])))
increase(kube_pod_container_status_restarts_total{namespace="eurotransit", pod=~"eurotransit-orders.*|eurotransit-payments.*"}[10m])
```

## Threshold decision guide

- If the breaker does not open and call count is below
  `minimum-number-of-calls`, increase load or duration. Do not tune thresholds
  from insufficient samples.
- If the breaker does not open while failure rate is clearly below 50% under a
  partial fault, consider lowering `failure-rate-threshold` gradually.
- If the breaker opens too aggressively during normal healthy traffic, increase
  `minimum-number-of-calls` or the sliding window before raising the failure
  threshold.
- If calls hang longer than the configured timeout, fix timeout binding before
  tuning circuit-breaker thresholds.

## Rollback

The manifest self-limits with `duration: 60s`. To stop earlier:

```bash
kubectl -n chaos-mesh delete networkchaos orders-payments-network-latency
```
