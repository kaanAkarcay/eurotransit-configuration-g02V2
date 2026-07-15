# Inventory HPA configuration

Date: 2026-07-14

This note records the repository-side implementation for the DoD requirement
"HPA configured for at least one service with a meaningful scaling metric." It
does not claim live autoscaling has been validated under load.

## Candidate selection

Inventory is the first HPA target.

Reasons:

- Inventory is on the checkout critical path: Orders calls it synchronously for
  reservation.
- Inventory's atomic reservation and internal idempotency are already the most
  proven consistency path in the current documentation.
- Scaling Orders first is riskier because current docs still record Orders-side
  consistency gaps around event deduplication and compensation.
- CPU is available from Metrics Server in the live AKS cluster and is a standard
  Kubernetes HPA resource metric.

## Helm configuration

Inventory now has explicit container resources:

```yaml
requests:
  cpu: 250m
  memory: 400Mi
limits:
  cpu: "1"
  memory: 800Mi
```

The CPU request gives the HPA a denominator for utilization. The memory request
is intentionally above the observed idle Inventory pod memory usage from the
2026-07-14 live check. The CPU request is deliberately higher than the original
`100m` draft so short, small CPU spikes do not look like extreme utilization.
The CPU limit keeps burst headroom available without changing the HPA
denominator.

Inventory autoscaling is disabled by default:

```yaml
autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 120
```

When autoscaling is disabled, the Deployment keeps using
`inventory.replicaCount`. When autoscaling is enabled, the Deployment omits
`.spec.replicas` and the `autoscaling/v2` HorizontalPodAutoscaler owns replica
management. The behavior policy keeps scale-out gradual, at most one additional
pod per minute, and makes scale-down more conservative after load subsides. This
avoids treating brief CPU spikes as a reason to jump immediately to
`maxReplicas`.

## Runtime prerequisites

The live AKS cluster was checked on 2026-07-14:

- `metrics-server` Deployment exists in `kube-system` and is `2/2` available.
- `v1beta1.metrics.k8s.io` APIService is `Available=True`.
- `kubectl top nodes` returns CPU and memory metrics.
- `kubectl get hpa -A` returned no existing HPAs.

Remaining live risk:

- Node memory was already high during the check, including one node near 98%.
- Earlier cluster recovery notes record Azure regional vCPU quota as a blocker
  for planned HPA-scaled replicas and larger node-pool headroom.

## Validation plan

Before merge:

```bash
helm lint deploy/charts/eurotransit
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit
helm template eurotransit deploy/charts/eurotransit --namespace eurotransit \
  --set inventory.autoscaling.enabled=true
```

After merge and Argo CD sync:

```bash
kubectl -n eurotransit get deploy eurotransit-inventory -o yaml
kubectl -n eurotransit get hpa eurotransit-inventory
kubectl -n eurotransit describe hpa eurotransit-inventory
kubectl -n eurotransit top pods -l app.kubernetes.io/name=inventory
```

Run controlled checkout/reservation load and verify:

- HPA reports current CPU utilization.
- Inventory scales above 1 replica when CPU stays above the target.
- Inventory scales back down after load stops.
- Checkout success, reservation consistency, and pod restart metrics remain
  acceptable.

Do not mark the DoD item complete until the live HPA behavior has been observed
under load and the cluster has enough capacity for the configured max replicas.
