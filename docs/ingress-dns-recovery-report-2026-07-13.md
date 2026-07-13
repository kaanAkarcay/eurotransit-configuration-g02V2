# Ingress DNS Recovery Report

Date: 2026-07-13

Scope: AKS, Azure Public IP / Load Balancer, Traefik, ArgoCD, Helm, cert-manager, OVH DNS, EuroTransit ingress path.

## Executive conclusion

The AKS cluster critical path has been recovered. The only remaining external cutover action is the manual OVH DNS update.

Current verified public entrypoint:

```text
Traefik Public IP: 134.112.8.66
Azure label:       g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

Current wrong public DNS:

```text
g02.cpo2026.it        -> g02-entrypoint.polandcentral.cloudapp.azure.com -> 134.112.166.65
argocd.g02.cpo2026.it -> g02-entrypoint.polandcentral.cloudapp.azure.com -> 134.112.166.65
```

Required final DNS action:

```text
g02.cpo2026.it        CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
argocd.g02.cpo2026.it CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

CNAME is preferred over an A record because it follows the Azure DNS label if the Azure Public IP object is retained but the backing IP changes later. An A record to `134.112.8.66` is acceptable only as a short-term emergency workaround.

## Root cause

The original Traefik Service did not pin a persistent Azure Public IP resource. After cluster/node recovery activity, AKS created or bound Traefik to a new Azure-managed Public IP and DNS label:

```text
kubernetes-a18745822eff349198a98b394c413147
134.112.8.66
g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

The old Azure label `g02-entrypoint.polandcentral.cloudapp.azure.com` still resolves to `134.112.166.65`, but that Public IP was not found in the accessible Azure subscription inventory.

The immediate outage persisted because OVH DNS still pointed both public hostnames at the old Azure label.

## Live recovery actions performed

No OVH DNS records were changed.

Applied Azure-native and Kubernetes recovery actions:

```text
helm upgrade traefik traefik/traefik --version 41.0.2 --namespace traefik -f platform/traefik/values.yaml --timeout 10m
kubectl apply -f platform/keycloak/keycloak-cr.yaml -f platform/keycloak/keycloak-ingress.yaml
kubectl cordon aks-cloudlab02-33508055-vms21
az vm redeploy --resource-group MC_G_06_Lab02cluster_polandcentral --name aks-cloudlab02-33508055-vms21
kubectl -n monitoring scale statefulset alertmanager-kube-prometheus-stack-alertmanager prometheus-kube-prometheus-stack-prometheus --replicas=0
kubectl -n monitoring scale deployment kube-prometheus-stack-grafana kube-prometheus-stack-kube-state-metrics kube-prometheus-stack-operator --replicas=0
kubectl -n kafka scale deployment strimzi-cluster-operator eurotransit-kafka-entity-operator --replicas=0
kubectl -n argocd scale deployment argocd-notifications-controller --replicas=0
az vm restart --resource-group MC_G_06_Lab02cluster_polandcentral --name aks-cloudlab02-33508055-vms23
az vm redeploy --resource-group MC_G_06_Lab02cluster_polandcentral --name aks-cloudlab02-33508055-vms23
kubectl uncordon aks-cloudlab02-33508055-vms21
kubectl -n eurotransit delete pod eurotransit-keycloak-0 eurotransit-orders-5496bbbbcd-htkt6
kubectl -n monitoring scale statefulset alertmanager-kube-prometheus-stack-alertmanager prometheus-kube-prometheus-stack-prometheus --replicas=1
kubectl -n monitoring scale deployment kube-prometheus-stack-grafana kube-prometheus-stack-kube-state-metrics kube-prometheus-stack-operator --replicas=1
kubectl -n kafka scale deployment strimzi-cluster-operator eurotransit-kafka-entity-operator --replicas=1
kubectl -n argocd scale deployment argocd-notifications-controller --replicas=1
```

Temporary scale-downs were restored.

## Current verified state

Nodes:

```text
aks-cloudlab02-33508055-vms21 Ready
aks-cloudlab02-33508055-vms22 Ready
aks-cloudlab02-33508055-vms23 Ready
```

Traefik:

```text
deployment.apps/traefik 1/1 available
service/traefik LoadBalancer 134.112.8.66
```

EuroTransit critical pods:

```text
frontend      1/1 Running
catalog       1/1 Running
inventory     1/1 Running
orders        1/1 Running
payments      1/1 Running
keycloak      1/1 Running
catalog-db    1/1 Running
inventory-db  2/2 Running
keycloak-db   1/1 Running
orders-db     1/1 Running
payments-db   1/1 Running
```

PostgreSQL operator status:

```text
catalog-db     Cluster in healthy state
inventory-db   Cluster in healthy state
keycloak-db    Cluster in healthy state
orders-db      Cluster in healthy state
payments-db    Cluster in healthy state
```

Kafka:

```text
Kafka CR eurotransit-kafka Ready=True
Node pool desired replicas: 3
broker pods 0, 1, 2 Ready
```

ArgoCD:

```text
Application eurotransit Synced Healthy
argocd-server pod Ready
```

cert-manager:

```text
cert-manager, cainjector, webhook Ready
argocd-server-tls certificate Pending
eurotransit-tls certificate Pending
```

The pending certificates are expected until OVH DNS points to the current Traefik endpoint, because HTTP-01 self-checks still follow public DNS.

## Direct public-path verification

All tests below forced the correct current Public IP:

```text
--resolve g02.cpo2026.it:443:134.112.8.66
--resolve argocd.g02.cpo2026.it:443:134.112.8.66
```

Results:

```text
https://g02.cpo2026.it/                         HTTP/2 200
https://g02.cpo2026.it/auth/                    HTTP/2 302
https://g02.cpo2026.it/api/v1/catalog/products  HTTP/2 200
https://g02.cpo2026.it/api/v1/orders            HTTP/2 401
https://argocd.g02.cpo2026.it/                  HTTP/2 200
```

`/api/v1/orders` returning `401` is expected for a protected API without a bearer token.

## Repository fixes

### Traefik static Public IP pinning

File: `platform/traefik/values.yaml`

```yaml
providers:
  kubernetesIngress:
    enabled: true
    ingressClass: traefik

service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: MC_G_06_Lab02cluster_polandcentral
    service.beta.kubernetes.io/azure-pip-name: kubernetes-a18745822eff349198a98b394c413147
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

This prevents Helm/GitOps from reverting the live Traefik Service back to the stale `g02-entrypoint` label and pins the Service to the current Azure Public IP object.

### Explicit Keycloak `/auth` ingress

File: `platform/keycloak/keycloak-cr.yaml`

```yaml
spec:
  ingress:
    enabled: false
```

File: `platform/keycloak/keycloak-ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: eurotransit-keycloak-auth
  namespace: eurotransit
spec:
  ingressClassName: traefik
  rules:
    - host: g02.cpo2026.it
      http:
        paths:
          - path: /auth
            pathType: Prefix
            backend:
              service:
                name: eurotransit-keycloak-service
                port:
                  name: http
```

This prevents `/auth` from falling through to the frontend ingress.

## Final manual DNS step

Update OVH records:

```text
g02.cpo2026.it        CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
argocd.g02.cpo2026.it CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

Recommended TTL: `60` seconds during recovery. Increase to `300` or `600` after validation.

After DNS propagation, verify without `--resolve`:

```bash
dig +short g02.cpo2026.it
dig +short argocd.g02.cpo2026.it
curl -I https://g02.cpo2026.it/
curl -I https://g02.cpo2026.it/auth/
curl -I https://g02.cpo2026.it/api/v1/orders
curl -I https://argocd.g02.cpo2026.it/
kubectl get certificates,orders,challenges -A
```

Expected after DNS propagation:

```text
g02.cpo2026.it and argocd.g02.cpo2026.it resolve to the new Azure label/IP path.
cert-manager HTTP-01 challenges pass.
eurotransit-tls and argocd-server-tls become Ready=True.
```
