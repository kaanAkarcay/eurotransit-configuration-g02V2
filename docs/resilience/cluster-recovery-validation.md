# EuroTransit Cluster Recovery Validation

## Scope

This document defines the Resilience Owner validation for a full AKS cluster
stop/start or equivalent platform recovery cycle.

It does not claim runtime completion. It is the runbook and evidence checklist
to use once EuroTransit workloads, Argo CD, Strimzi, CloudNativePG, Chaos Mesh,
and observability are deployed.

## Current Live Check - 2026-07-11

The AKS cluster `Lab02cluster` in resource group `G_06` was started from the
Stopped state and reached `Running`.

Observed recovery evidence:

- `az aks show -g G_06 -n Lab02cluster --query powerState.code -o tsv` returned
  `Running`.
- `kubectl get nodes -o wide` showed 3 worker nodes, all `Ready`.
- CloudNativePG recovered all currently deployed clusters:
  `catalog-db`, `orders-db`, `inventory-db`, `payments-db`, and `keycloak-db`
  were reported as `Cluster in healthy state`.
- Strimzi recovered `eurotransit-kafka`; all six Kafka topics were `Ready`.
- Keycloak recovered in the `eurotransit` namespace.

Capacity finding:

An attempt to scale the AKS node pool `cloudlab02` from 3 nodes to 5 nodes was
blocked by Azure quota:

```text
ErrCode_InsufficientVCPUQuota
left regional vcpu quota 0, requested quota 4
```

Impact:

- The cluster remains at 3 nodes.
- The current 3-node cluster is enough for the observed CNPG, Kafka, and
  Keycloak recovery state.
- The planned 5-node headroom for full application workloads, observability,
  Chaos Mesh, HPA-scaled replicas, and node disruption experiments is blocked
  until the Azure regional vCPU quota is increased, a smaller VM size is used,
  or other regional resources are reduced.

Current runtime blockers:

- Argo CD CRDs were not present in the live cluster during this check.
- Chaos Mesh CRDs were not present, so server-side dry-run validation of the
  draft Chaos Mesh schedules is blocked until Chaos Mesh is installed.
- EuroTransit application workloads were not deployed; only Keycloak was
  present in the `eurotransit` namespace.

Assessment:

Cluster start recovery for the currently deployed platform dependencies is
partially verified. Full Resilience Owner validation remains blocked by missing
application workloads, missing Argo CD/Chaos Mesh runtime components, and Azure
regional vCPU quota.

## Architecture Baseline

- Argo CD reconciles the configuration repository into the cluster.
- EuroTransit application workloads are rendered from
  `deploy/charts/eurotransit`.
- Chaos Mesh is installed by `platform/argocd/chaos-mesh-application.yaml`.
- Kafka is provided by Strimzi manifests under `platform/strimzi`.
- PostgreSQL is provided by CloudNativePG manifests under `platform/cnpg`.
- Observability is provided through kube-prometheus-stack values and the
  ServiceMonitor/PrometheusRule templates in the Helm chart.

## Objective Health Criteria

A cluster recovery test passes only when all of the following are true:

- No critical workload remains in CrashLoopBackOff.
- Orders, Inventory, Payments, and Catalog become Ready.
- Kafka and Strimzi components recover.
- CloudNativePG clusters recover and expose a writable primary where expected.
- Services reconnect to databases, Kafka, and downstream HTTP dependencies
  without manual pod restarts.
- Logs do not show repeated fatal startup or reconnection failures after the
  recovery window.
- Critical services stabilize after startup.
- Argo CD reaches Synced/Healthy or exposes a clear drift requiring a Git fix.
- Chaos Mesh has no orphaned active experiment after recovery.

## Baseline Capture

Run before the stop/start cycle:

```bash
kubectl get nodes -o wide
kubectl get ns
kubectl get pods -A -o wide
kubectl get deploy,statefulset,daemonset -A
kubectl get applications.argoproj.io -n argocd
kubectl get clusters.postgresql.cnpg.io -A
kubectl get kafka,kafkatopic -n kafka
kubectl get servicemonitor,prometheusrule -A
kubectl get events -A --sort-by=.lastTimestamp
```

Record application-level evidence:

```bash
kubectl logs -n eurotransit deploy/eurotransit-orders --tail=200
kubectl logs -n eurotransit deploy/eurotransit-inventory --tail=200
kubectl logs -n eurotransit deploy/eurotransit-payments --tail=200
kubectl logs -n eurotransit deploy/eurotransit-catalog --tail=200
```

## Stop/Start Procedure

Use the normal team-approved AKS procedure. If the Azure CLI is used, capture
the exact commands and timestamps in the validation report.

The Resilience Owner must not treat an Azure operation as successful until the
Kubernetes and application evidence below is collected after restart.

## Post-Start Recovery Observation

Run immediately after the cluster becomes reachable:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get deploy,statefulset,daemonset -A
kubectl get applications.argoproj.io -n argocd
kubectl get events -A --sort-by=.lastTimestamp
```

Watch critical namespaces:

```bash
kubectl get pods -n eurotransit -w
kubectl get pods -n kafka -w
kubectl get pods -n cnpg-system -w
kubectl get pods -n chaos-mesh -w
kubectl get pods -n monitoring -w
```

Inspect dependency recovery:

```bash
kubectl get clusters.postgresql.cnpg.io -A
kubectl describe clusters.postgresql.cnpg.io -n cnpg-system inventory-db
kubectl get kafka,kafkatopic -n kafka
kubectl describe kafka -n kafka eurotransit-kafka
kubectl get applications.argoproj.io -n argocd
```

Inspect application logs after stabilization:

```bash
kubectl logs -n eurotransit deploy/eurotransit-orders --since=30m
kubectl logs -n eurotransit deploy/eurotransit-inventory --since=30m
kubectl logs -n eurotransit deploy/eurotransit-payments --since=30m
kubectl logs -n eurotransit deploy/eurotransit-catalog --since=30m
kubectl logs -n eurotransit deploy/eurotransit-notifications --since=30m
```

## Recovery Time Measurement

Measure from the first successful `kubectl get nodes` after cluster start to:

- all critical Deployments Available,
- Kafka Ready,
- all CNPG clusters Ready,
- Argo CD Applications Healthy,
- critical checkout smoke test passes,
- logs stop showing repeated fatal reconnection errors.

Record both platform recovery time and critical-path recovery time.

## Chaos Cleanup Check

```bash
kubectl get schedule,networkchaos,podchaos -A
```

Pass only if no unexpected active chaos object remains. Draft suspended
Schedules may exist, but active `NetworkChaos` or `PodChaos` objects must be
explained or removed.

## PASS Criteria

- All objective health criteria are met.
- A checkout smoke test reaches a terminal state.
- No manual application pod restart is required.
- Recovery time is recorded with command evidence.

## FAIL Criteria

- A critical workload remains unavailable or in CrashLoopBackOff.
- Kafka or CNPG does not recover.
- Services require manual pod restarts to reconnect.
- Argo CD cannot reconcile without out-of-band changes.
- Repeated fatal dependency errors remain after the recovery window.

## Report Template

For each recovery validation run, record:

- date and time,
- branch and commit of the configuration repository,
- cluster name and node count,
- baseline evidence commands,
- stop/start commands or operator actions,
- observed recovery sequence,
- approximate recovery time,
- issues found,
- PASS/FAIL result,
- follow-up fixes or documentation changes.
