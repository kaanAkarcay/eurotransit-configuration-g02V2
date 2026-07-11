# EuroTransit Node Disruption Runbook

## Scope

This runbook covers Experiment 3 from `docs/chaos-experiment-hypotheses.md`:
one AKS node is cordoned and drained to simulate a node or availability-zone
style disruption.

This is intentionally not implemented as a Chaos Mesh manifest. The project
hypothesis states that this experiment is executed through Kubernetes node
operations or AKS node-pool operations.

## Preconditions

- The cluster has at least three schedulable worker nodes.
- EuroTransit workloads are deployed and healthy.
- Critical-path services have at least two replicas before the experiment.
- PodDisruptionBudgets exist for critical-path services with `minAvailable >= 1`.
- Prometheus and Grafana are available.
- A rollback owner is watching the experiment.

## Fault

Drain exactly one non-control-plane AKS worker node.

```bash
kubectl get nodes -o wide
kubectl cordon <node-name>
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --timeout=10m
```

## Expected Behavior

- Kubernetes prevents voluntary eviction from removing all replicas of a
  critical-path service at once.
- Evicted pods reschedule to remaining nodes.
- Orders, Inventory, and Payments keep at least one ready replica or recover
  within the documented recovery window.
- Checkout may see a short latency spike, but the system does not require
  manual pod restarts.
- Notifications may be temporarily unavailable without blocking checkout.

## Evidence to Collect

```bash
kubectl get nodes
kubectl get pods -n eurotransit -o wide
kubectl get pdb -n eurotransit
kubectl get events -A --sort-by=.lastTimestamp
kubectl get deploy,statefulset -A
kubectl get clusters.postgresql.cnpg.io -A
kubectl get kafka,kafkatopic -n kafka
```

Collect Grafana evidence for:

- Orders availability SLO.
- Checkout latency SLO.
- Pending order age.
- Pod restart counts.
- Kafka broker health and consumer lag.
- CNPG cluster status.

## Pass Criteria

- No critical-path service loses all ready replicas due to voluntary eviction.
- Checkout recovers without manual pod restarts.
- Kafka and CNPG recover or remain healthy.
- No order remains stuck beyond the agreed pipeline completion SLO.

## Fail Criteria

- A critical-path service loses all ready replicas because PDB or replica
  topology is insufficient.
- Pods remain Pending due to capacity or scheduling constraints.
- Orders, Inventory, or Payments enters CrashLoopBackOff.
- Manual pod restart is required to recover dependency connections.
- Kafka, CNPG, or Argo CD fails to reconcile after the node returns.

## Rollback

```bash
kubectl uncordon <node-name>
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp
```

If the node does not recover, stop the experiment and use the normal AKS
node-pool recovery procedure. Record the failure in the chaos report before
attempting another run.
