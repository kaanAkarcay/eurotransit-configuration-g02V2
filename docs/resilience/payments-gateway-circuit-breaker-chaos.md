# Payments -> Gateway circuit-breaker validation

Date: 2026-07-16

This runbook covers live validation for the `payment-gateway` circuit breaker in
Payments.

## Hypothesis

When `payment-gateway-sim` becomes slow enough that gateway calls exceed the
configured slow-call threshold, Payments records slow calls and opens the
`payment-gateway` circuit breaker after the configured sample size and threshold
are reached. While open, Payments returns the contract fallback decline reason
instead of allowing requests to pile up indefinitely.

## Repository prerequisites

- Payments uses `HttpPaymentGateway` with a Reactor Netty response timeout.
- Payments wraps the suspend gateway call with Resilience4j
  `executeSuspendFunction`.
- Helm renders `payments.springApplicationJson.resilience4j.circuitbreaker.instances.payment-gateway`.
- `payment-gateway-sim` is deployed and selected by
  `app.kubernetes.io/name=payment-gateway-sim`.
- Chaos Mesh CRDs exist for `networkchaos.chaos-mesh.org`.

## Experiment manifest

Use the one-shot manifest:

```bash
kubectl apply -f platform/chaos-mesh/experiments/payments-gateway-network-latency.yaml
```

It injects 3s latency from Payments pods to `payment-gateway-sim` pods for 60s.
This exceeds the configured 2s slow-call threshold while remaining below the 5s
transport timeout, so it validates slow-call breaker behavior rather than only
connection failure behavior.

Two consequences of staying below the transport timeout — both intended, both
worth knowing before the first run:

- The gateway call **succeeds**. Until the breaker opens
  (`minimum-number-of-calls: 5`), the first calls reach Stripe and authorize for
  real. This experiment moves money; it is not a dry run.
- Orders must already be running with
  `resilience4j.timelimiter.instances.payments-client.timeout-duration: 6s`
  (added in this PR). With the previous effective value of 2s, Orders abandons
  the call at 2s and marks the order FAILED while the gateway authorizes at ~3s
  — an authorized payment against a failed order, which nothing reconciles.
  Apply this manifest only after Argo CD has synced and the Orders pod restarted.

Pre-flight check:

```bash
kubectl -n eurotransit exec deploy/eurotransit-orders -- \
  printenv SPRING_APPLICATION_JSON \
  | grep -o '"payments-client":{"timeout-duration":"[^"]*"'
```

## Load generation

Payments is not exposed through the public Ingress. Use a port-forward:

```bash
kubectl -n eurotransit port-forward svc/eurotransit-payments 18081:8080
PAYMENTS_AUTH_TOKEN='<payments-audience-token>' \
  BASE_URL='http://localhost:18081' \
  k6 run tools/k6/payments-gateway-circuit-breaker.js
```

## Metrics to monitor

```promql
resilience4j_circuitbreaker_state{name="payment-gateway"}
rate(resilience4j_circuitbreaker_calls_seconds_count{name="payment-gateway"}[1m])
rate(http_server_requests_seconds_count{service="eurotransit-payments", uri="/api/v1/payments/authorize"}[1m])
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{service="eurotransit-payments", uri="/api/v1/payments/authorize"}[5m])))
increase(kube_pod_container_status_restarts_total{namespace="eurotransit", pod=~"eurotransit-payments.*|payment-gateway-sim.*"}[10m])
```

## Success criteria

- `payment-gateway` transitions CLOSED -> OPEN during the fault window.
- Authorization requests return expected business responses, not elevated 5xx.
- Payments and `payment-gateway-sim` pods do not restart due to liveness churn.
- The breaker transitions back toward HALF_OPEN/CLOSED after the fault ends and
  healthy calls resume.

## Rollback

The manifest self-limits with `duration: 60s`. To stop earlier:

```bash
kubectl -n chaos-mesh delete networkchaos payments-gateway-network-latency
```
