# Imported Grafana dashboards

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
