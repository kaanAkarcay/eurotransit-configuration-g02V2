# Orders HTTP 429 load shedding

Date: 2026-07-15

This note records the repository-side implementation for the DoD requirement
"Backpressure / load shedding: HTTP 429 when overloaded." It does not claim the
live threshold has been tuned under production-like load.

## Scope

Orders is the first load-shedding target.

Reasons:

- `POST /api/v1/orders` is the checkout entry point measured by the gateway
  success-rate SLO in `docs/eurotransit-contract.md`.
- Orders owns the client-facing transition from request acceptance to the
  asynchronous order pipeline.
- Returning `429 Too Many Requests` at the inbound edge is safer than accepting
  unbounded work and letting pressure accumulate in the database pool, Kafka
  publishing path, or coroutine scheduler.

The guard applies only to:

```text
POST /api/v1/orders
```

Status polling, listing, Actuator probes, Prometheus scraping, and internal
downstream client calls are intentionally outside this load-shedding filter.

## Application behavior

The Orders application has an inbound WebFlux filter controlled by:

```yaml
app:
  backpressure:
    orders:
      enabled: true
      max-concurrent-requests: 20
      retry-after-seconds: 1
```

When enabled, the filter uses a local semaphore around concurrent order-create
requests:

- if a permit is available, the request continues normally;
- if no permit is available, Orders immediately returns
  `HTTP 429 Too Many Requests`;
- the response includes `Retry-After: 1`;
- rejected requests increment the Micrometer counter
  `orders.backpressure.rejected`.

The configured limit is intentionally close to the existing Orders R2DBC pool
shape (`max-size: 10` in the application defaults) while leaving a small amount
of burst headroom. It is a starting threshold, not a final capacity claim.

## Helm configuration

The configuration repository renders the same policy through
`orders.springApplicationJson`, so Argo CD owns the runtime value:

```yaml
orders:
  springApplicationJson:
    app:
      backpressure:
        orders:
          enabled: true
          max-concurrent-requests: 20
          retry-after-seconds: 1
```

This follows the existing chart pattern used for Orders runtime resilience
settings: application code supplies safe defaults, while the configuration repo
defines cluster policy through `SPRING_APPLICATION_JSON`.

## Validation before merge

Application repository:

```bash
cd backend/orders
./gradlew test
```

Configuration repository:

```bash
helm lint deploy/charts/eurotransit
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit
```

The Helm render should include `app.backpressure.orders` inside the Orders
`SPRING_APPLICATION_JSON` environment value.

The application repository also provides a k6 script at:

```text
tools/k6/orders-load-shedding.js
```

It intentionally does not store credentials or fetch live tokens. Pass a valid
Orders-audience bearer token through `AUTH_TOKEN`:

```bash
k6 run \
  -e BASE_URL=https://g02.cpo2026.it \
  -e AUTH_TOKEN="$AUTH_TOKEN" \
  -e VUS=40 \
  -e DURATION=2m \
  -e TRAIN_ID=TR-MIL-GEN-20260710-1616 \
  tools/k6/orders-load-shedding.js
```

If k6 is not installed locally, run the same script through Docker:

```bash
docker run --rm \
  -e BASE_URL=https://g02.cpo2026.it \
  -e AUTH_TOKEN="$AUTH_TOKEN" \
  -e VUS=40 \
  -e DURATION=2m \
  -e TRAIN_ID=TR-MIL-GEN-20260710-1616 \
  -v "$PWD:/workspace" \
  -w /workspace \
  grafana/k6:latest run tools/k6/orders-load-shedding.js
```

## Runtime validation

After the application image and configuration have been deployed:

1. Confirm the deployed Orders pod has the expected runtime property:

   ```bash
   kubectl -n eurotransit get deploy eurotransit-orders -o yaml
   ```

2. Generate controlled authenticated load against `POST /api/v1/orders`.

   The authenticated k6 run is currently blocked until the runner has a valid
   Orders-audience bearer token supplied out of band. Dockerized k6 is usable,
   and the script has been checked to fail fast when `AUTH_TOKEN` is absent.

   The committed Keycloak realm keeps `frontend.directAccessGrantsEnabled:
   false`, so the script must not use the demo user's password grant to mint
   tokens. Use an already-issued frontend token, a CI secret, or another approved
   secure token handoff.

3. Monitor:

   ```promql
   sum(rate(http_server_requests_seconds_count{
     namespace="eurotransit",
     service="eurotransit-orders",
     uri="/api/v1/orders",
     method="POST",
     status="429"
   }[2m]))

   sum(rate(orders_backpressure_rejected_total{
     namespace="eurotransit",
     service="eurotransit-orders"
   }[2m]))

   histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{
     namespace="eurotransit",
     service="eurotransit-orders",
     uri="/api/v1/orders",
     method="POST"
   }[5m])))

   sum(rate(container_cpu_cfs_throttled_periods_total{
     namespace="eurotransit",
     pod=~"eurotransit-orders-.*"
   }[5m]))
   ```

4. Verify:

   - overload produces `429`, not rising `5xx`;
   - Orders pod restart count does not increase;
   - p95/p99 latency stays bounded once 429 begins;
   - accepted orders still progress to terminal states;
   - liveness remains healthy during overload.

## Tuning guide

- If `429` appears while CPU, memory, DB pool, Kafka publishing, and latency are
  all healthy, increase `max-concurrent-requests` gradually.
- If p95/p99 latency climbs before any `429` appears, decrease
  `max-concurrent-requests`.
- If `5xx` appears during overload, investigate the failing component first; do
  not raise the threshold to hide failures.
- If Orders CPU throttling is the first bottleneck, tune resource requests and
  limits before raising concurrency.
- If database pool wait time or DB saturation is the first bottleneck, keep the
  threshold at or below the value where pool wait becomes visible.

## Rollback

Fast runtime rollback:

```yaml
orders:
  springApplicationJson:
    app:
      backpressure:
        orders:
          enabled: false
```

Full rollback:

- revert the application commit that adds the filter;
- revert the configuration commit that enables `app.backpressure.orders`;
- let Argo CD sync the configuration rollback;
- redeploy the previous Orders image if the application rollback is required.

Do not mark the DoD item complete until the behavior has been observed in the
running environment under controlled load.
