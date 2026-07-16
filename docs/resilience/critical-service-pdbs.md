# Critical service PodDisruptionBudgets

Date: 2026-07-16

This document covers the task "Configure PodDisruptionBudget for Orders,
Inventory and Payments".

## Repository implementation

The Helm chart renders `policy/v1` PodDisruptionBudgets for the three
critical-path services:

- `eurotransit-orders`
- `eurotransit-inventory`
- `eurotransit-payments`

Each PDB is controlled by the matching service values block:

```yaml
pdb:
  enabled: true
  minAvailable: 1
```

The selector uses the same stable labels as the Deployments:

```yaml
app.kubernetes.io/name: <service>
app.kubernetes.io/instance: eurotransit
```

## Important validation caveat

The current default replica count for Orders, Inventory and Payments is still
`1`. With one replica and `minAvailable: 1`, Kubernetes will correctly report
`ALLOWED DISRUPTIONS = 0`.

That is protective, but it means a voluntary eviction test cannot prove
continued availability during a node drain yet. Safe node-drain validation needs
at least two available replicas for each service being tested, either by:

- temporarily setting `replicaCount: 2`, or
- enabling HPA with `minReplicas >= 2`.

Do not mark the PDB runtime task complete from the mere existence of PDB
objects. Runtime completion requires an approved disruption test with enough
replicas to keep one pod available.

## Live validation plan

After Argo CD sync:

```bash
kubectl -n eurotransit get pdb eurotransit-orders eurotransit-inventory eurotransit-payments
kubectl -n eurotransit get deploy eurotransit-orders eurotransit-inventory eurotransit-payments
kubectl -n eurotransit get pods -l app.kubernetes.io/name=orders -o wide
kubectl -n eurotransit get pods -l app.kubernetes.io/name=inventory -o wide
kubectl -n eurotransit get pods -l app.kubernetes.io/name=payments -o wide
```

For a real node-drain proof:

1. Scale the tested critical services to at least two replicas.
2. Confirm each PDB has at least one allowed disruption where expected.
3. Generate checkout traffic.
4. Cordon and drain one selected node with normal safety flags.
5. Confirm at least one pod for Orders, Inventory and Payments remains ready.
6. Confirm checkout recovers and no pod restarts are caused by liveness churn.
7. Uncordon the node and return replica settings to the GitOps-approved values.

## Rollback

Revert the PDB values or set `pdb.enabled: false` for the affected service, then
let Argo CD sync. If a drain is blocked during an operational emergency, use the
normal Kubernetes break-glass process and document the reason.
