# Imported Grafana dashboards

## Datasources

### Zipkin (distributed tracing)

- Added live via Grafana's API (`POST /api/datasources`), not a ConfigMap -
  this project's dashboards/datasources aren't sidecar-provisioned (see "How
  to import" below), so this matches that same manual-but-documented
  convention rather than introducing a new one.
- `name: Zipkin`, `type: zipkin`, `access: proxy`,
  `url: http://eurotransit-zipkin.eurotransit.svc.cluster.local:9411`
  (the Service the `zipkin.yaml` chart template creates in the `eurotransit`
  namespace - Grafana itself runs in `monitoring`, but `access: proxy` means
  the *Grafana pod*, not the browser, makes the request, so cross-namespace
  ClusterIP DNS resolves fine).
- To recreate on a fresh cluster/Grafana instance:
  ```
  kubectl exec -n monitoring deploy/kube-prometheus-stack-grafana -c grafana -- \
    curl -s -u <user>:<pass> -X POST -H "Content-Type: application/json" \
    -d '{"name":"Zipkin","type":"zipkin","access":"proxy","url":"http://eurotransit-zipkin.eurotransit.svc.cluster.local:9411","isDefault":false}' \
    http://localhost:3000/api/datasources
  ```

## EuroTransit - Orders SLO / Error Budget

- **File:** `platform/observability/dashboards/eurotransit-orders-slo.json`
- **Datasource:** Prometheus (kube-prometheus-stack)
- **What it shows:** all 3 contract §4 SLOs for Orders - gateway success
  rate vs the 99.5% objective, confirmation latency vs the 99% objective,
  and pipeline-completion staleness - each paired with an error-budget-
  consumed gauge (% of the 5-minute budget used), a table of currently
  firing SLO burn-rate alerts, and a raw order-volume panel for context.
- **Confirmation latency budget note:** the panel title/description
  reference ~7.16s, not the contract's original 800ms - see
  `eurotransit-contract.md` §4.1, revalidated 2026-07-16 against real
  order timings (1.17s-5.36s across 10 orders). If that budget changes
  again, update `orders_confirmation_latency_slo:ratio_rate5m`'s `le`
  value here to match `prometheusrule-slo.yaml`.
- **Verified against live data:** every panel's query run directly against
  Prometheus. The two ratio SLIs returned `NaN` at verification time (0/0 -
  no order traffic in the preceding 5m window, not a broken query); the
  `ALERTS` table panel correctly returned the live-firing
  `OrdersPipelineCompletionStalePending` alert, and the stale-count panel
  correctly returned the real count (35) of orders stuck past budget.

## EuroTransit - RED Signals per Service

- **File:** `platform/observability/dashboards/eurotransit-red-signals.json`
- **Datasource:** Prometheus (kube-prometheus-stack)
- **Scope:** all 5 backend services (catalog, orders, inventory, payments,
  notifications), namespace `eurotransit` (not the stale `lab05-app` from
  the older dashboard below).
- **What it shows:** a top row comparing Request Rate / Error % / p95
  Latency across all services at once, plus a `$service` variable to drill
  into one service's Rate/Errors/Duration, requests-by-route, pod restarts,
  and memory in detail.
- **Verified against live data:** every panel's query confirmed against a
  running Prometheus - required fixing a real bug found in the process:
  `orders` and `notifications` were missing the `io.micrometer:
  micrometer-registry-prometheus` runtime dependency (present in catalog/
  payments), so their `/actuator/prometheus` endpoint 404'd and Prometheus
  scraping silently failed for both. Fixed in both `build.gradle.kts`.

## EuroTransit - Infrastructure (USE / Golden Signals)

- **File:** `platform/observability/dashboards/eurotransit-infrastructure-use.json`
- **Datasource:** Prometheus (kube-prometheus-stack)
- **What it shows:** Utilization (CPU/memory %, and separately declared
  *requests* vs allocatable per node - the two numbers that diverged sharply
  during this session's node-instability incident), Saturation (CPU
  throttling, load average, Pending pods), Errors (Node Ready/
  MemoryPressure conditions, OOMKills, restarts, currently-unschedulable
  pods). Built directly from this session's real incident rather than a
  generic template.
- **Verified against live data:** every panel's query tested directly
  against Prometheus, including a genuinely complex one (declared-requests-
  vs-allocatable-per-node, a PromQL join) which returned 99.0/99.9/99.7%
  matching the exact numbers manually computed via `kubectl describe nodes`
  earlier the same session. One query was fixed after testing:
  `kube_pod_status_scheduled` is a per-condition gauge, not a counter -
  using `increase()` on it (as originally drafted) is semantically invalid;
  changed to a plain instant-value sum.

## Kubernetes / Views / Pods (community dashboard, generic)

- **Grafana ID:** 15760
- **Source:** https://grafana.com/grafana/dashboards/15760-kubernetes-views-pods/
- **Datasource:** Prometheus (kube-prometheus-stack)
- **Reason for import:** generic pod-level CPU/memory/restart drill-down,
  useful during k6 experiments. Superseded for day-to-day use by the
  purpose-built Infrastructure dashboard above, but still useful for raw
  pod-level detail the USE dashboard doesn't break out individually.

## Lab05 - Application RED Signals (stale, do not use for EuroTransit)

- **File:** `platform/observability/dashboards/lab05-application-red-signals.json`
- Leftover from an earlier, unrelated lab exercise - hardcoded to namespace
  `lab05-app`, not `eurotransit`, and aggregates across all services rather
  than breaking them out individually. Left in place rather than deleted
  (not this session's file to remove), but superseded by the RED dashboard
  above for this project.

## How to import any of the JSON files above

1. Open Grafana via port-forward: `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80`
2. Navigate to **Dashboards → New → Import**
3. Upload the `.json` file (or paste its contents) and click **Load**
4. Select the **Prometheus** datasource
5. Click **Import**

## How to import a community dashboard by ID (e.g. 15760)

1. Same port-forward as above
2. Navigate to **Dashboards → New → Import**
3. Enter the dashboard ID and click **Load**
4. Select the **Prometheus** datasource
5. Click **Import**
