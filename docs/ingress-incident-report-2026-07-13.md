# EuroTransit Ingress Incident Report

Date: 2026-07-13  
Environment: Azure AKS, Traefik ingress controller, Helm, ArgoCD, cert-manager  
Application: EuroTransit

## Executive Summary

Traefik is reachable through the current Azure LoadBalancer IP `134.112.8.66`.
The `404 Not Found` returned by:

```text
http://g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

is expected behavior because the EuroTransit Ingress is host-based and only
matches:

```text
g02.cpo2026.it
```

The main production issue is DNS drift. The real application hostname still
resolves to the old Azure DNS label and old public IP:

```text
g02.cpo2026.it
  -> g02-entrypoint.polandcentral.cloudapp.azure.com
  -> 134.112.166.65
```

but the active Traefik LoadBalancer is:

```text
134.112.8.66
```

As a result, normal client traffic and cert-manager HTTP-01 validation for
`g02.cpo2026.it` do not reach the current Traefik instance.

## Confirmed Traffic Path

The current live path is functional when the request uses the expected Host
header:

```text
Internet
-> Azure Public IP 134.112.8.66
-> Azure Load Balancer
-> Traefik
-> EuroTransit Ingress
-> Service
-> Pod
```

Verified behavior:

```bash
curl -I http://134.112.8.66/
# HTTP/1.1 404 Not Found
```

This is expected because no Ingress rule matches a bare IP Host header.

```bash
curl -I -H 'Host: g02.cpo2026.it' http://134.112.8.66/
# HTTP/1.1 308 Permanent Redirect
# Location: https://g02.cpo2026.it/
```

This proves Traefik sees and matches the EuroTransit Ingress rule.

```bash
curl -k -I --resolve g02.cpo2026.it:443:134.112.8.66 https://g02.cpo2026.it/
# HTTP/2 200
# server: nginx/1.31.2
```

This proves the full HTTPS route to the frontend Pod works when DNS is bypassed.

## DNS Findings

Current Azure temporary DNS label:

```bash
dig +short g02-entrypoint-2026.polandcentral.cloudapp.azure.com
# 134.112.8.66
```

Current EuroTransit DNS:

```bash
dig +short g02.cpo2026.it
# g02-entrypoint.polandcentral.cloudapp.azure.com.
# 134.112.166.65
```

This is the primary external access problem.

The incident text also referenced:

```text
g02.cp02026.it
argocd.g02.cp02026.it
```

Those names did not resolve during validation. The repository and live cluster
use:

```text
g02.cpo2026.it
argocd.g02.cpo2026.it
```

## Why the Azure cloudapp Hostname Returns 404

EuroTransit is configured with an explicit host rule:

File: `deploy/charts/eurotransit/templates/ingress.yaml`

```yaml
spec:
  ingressClassName: traefik
  rules:
    - host: g02.cpo2026.it
```

Therefore this works only if the HTTP Host header is `g02.cpo2026.it`.

The Azure hostname:

```text
g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

does not match the Ingress host rule, so Traefik returns its default 404.

This is normal Traefik/Kubernetes Ingress behavior.

## Repository Findings

### Traefik LoadBalancer DNS Label Drift

File: `platform/traefik/values.yaml`

Current committed value:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint
```

Live Service value:

```yaml
service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

This live change is not reflected in Git or Helm values. A future Helm upgrade
using the repository values can revert the Service back to `g02-entrypoint`,
re-triggering the Azure `DnsRecordInUse` failure.

### No Static Azure Public IP Configuration

No static public IP binding was found in the Traefik values. The current design
lets AKS dynamically create and manage a Public IP for the LoadBalancer.

Missing production-grade settings include:

```yaml
service.beta.kubernetes.io/azure-pip-name
service.beta.kubernetes.io/azure-load-balancer-resource-group
```

This means the deployment is vulnerable to public IP changes after Service
recreation or cluster lifecycle events.

### EuroTransit Ingress Routing

File: `deploy/charts/eurotransit/templates/ingress.yaml`

Routes:

```yaml
/api/v1/orders  -> eurotransit-orders:8080
/api/v1/catalog -> eurotransit-catalog:8080
/               -> eurotransit-frontend:80
```

The Service and Deployment ports match:

```text
frontend:  Service 80   -> containerPort 80
catalog:   Service 8080 -> containerPort 8080
orders:    Service 8080 -> containerPort 8080
```

Live endpoints were present:

```text
eurotransit-frontend -> 10.244.1.186:80
eurotransit-catalog  -> 10.244.0.202:8080
eurotransit-orders   -> 10.244.0.88:8080
```

All EuroTransit Pods were `1/1 Running` at the time of review.

## cert-manager Findings

cert-manager created Certificates for:

```text
eurotransit-tls
argocd-server-tls
```

but both were `Ready=False`.

The HTTP-01 Challenges were pending because self-checks timed out:

```text
http://g02.cpo2026.it/.well-known/acme-challenge/...
http://argocd.g02.cpo2026.it/.well-known/acme-challenge/...
```

This is consistent with the DNS drift: Let's Encrypt and cert-manager are
checking the old IP, not the current Traefik LoadBalancer.

ClusterIssuer HTTP-01 solver is correct:

```yaml
solvers:
  - http01:
      ingress:
        ingressClassName: traefik
```

## ArgoCD Findings

EuroTransit app is GitOps-managed by ArgoCD:

File: `platform/argocd/eurotransit-application.yaml`

```yaml
source:
  repoURL: https://github.com/CPO-G02/eurotransit-configuration-g02
  targetRevision: main
  path: deploy/charts/eurotransit
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

Live ArgoCD status for the EuroTransit application was:

```text
Healthy
Synced
```

Important: ArgoCD manages the EuroTransit application chart only. Traefik,
cert-manager, ArgoCD itself, and Keycloak platform resources are Helm/manual
managed unless separate ArgoCD Applications are added for them.

### ArgoCD Ingress Issue

File: `platform/argocd/values.yaml`

Current value:

```yaml
server:
  ingress:
    className: traefik
```

The live rendered ArgoCD Ingress did not contain:

```yaml
spec:
  ingressClassName: traefik
```

As a result, forcing traffic to the current Traefik IP still returned 404 for
`argocd.g02.cpo2026.it`.

Likely fix:

```yaml
server:
  ingress:
    enabled: true
    ingressClassName: traefik
```

## Keycloak Hidden Issue

The backend Helm values refer to:

File: `deploy/charts/eurotransit/values.yaml`

```yaml
keycloak:
  issuerUri: https://g02.cpo2026.it/auth/realms/eurotransit
  tokenUri: http://eurotransit-keycloak-service:8080/auth/realms/eurotransit/protocol/openid-connect/token
  jwkSetUri: http://eurotransit-keycloak-service:8080/auth/realms/eurotransit/protocol/openid-connect/certs
```

However, the live cluster did not have a Service named:

```text
eurotransit-keycloak-service
```

This can break JWT/JWKS validation for authenticated backend requests even after
Ingress and DNS are fixed.

There was also no live Keycloak Ingress in the `eurotransit` namespace, despite
the Keycloak CR enabling ingress.

## Required Fixes

### 1. Fix External DNS

Update DNS so both hostnames point to the current Traefik endpoint:

```text
g02.cpo2026.it         -> g02-entrypoint-2026.polandcentral.cloudapp.azure.com
argocd.g02.cpo2026.it  -> g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

or point both directly to:

```text
134.112.8.66
```

### 2. Commit the Current Traefik DNS Label

File: `platform/traefik/values.yaml`

Change:

```yaml
service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint
```

to:

```yaml
service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

Then apply with:

```bash
helm upgrade traefik traefik/traefik \
  -n traefik \
  -f platform/traefik/values.yaml
```

### 3. Preferred Production Fix: Use a Static Azure Public IP

Create or reuse a static Standard Public IP and bind Traefik to it:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: mc_g_06_lab02cluster_polandcentral
    service.beta.kubernetes.io/azure-pip-name: pip-traefik-g02
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint
```

This avoids dynamic IP churn and makes the DNS target stable.

### 4. Clean Up the Old Azure DNS Label Conflict

Find the Public IP currently holding the old DNS label:

```bash
az network public-ip list \
  -g mc_g_06_lab02cluster_polandcentral \
  --query "[?dnsSettings.fqdn=='g02-entrypoint.polandcentral.cloudapp.azure.com'].[name,ipAddress,dnsSettings.fqdn]" \
  -o table
```

Then either remove its DNS label or delete the orphaned Public IP if it is no
longer used.

### 5. Refresh cert-manager After DNS Is Correct

If cert-manager does not recover automatically:

```bash
kubectl delete challenge,order -n eurotransit --all
kubectl delete challenge,order -n argocd --all
kubectl get certificate,challenge,order -A
```

Expected final state:

```text
eurotransit-tls     Ready=True
argocd-server-tls   Ready=True
```

### 6. Fix ArgoCD Ingress Class

File: `platform/argocd/values.yaml`

Change to:

```yaml
server:
  ingress:
    enabled: true
    ingressClassName: traefik
```

Then upgrade:

```bash
helm upgrade argocd argo/argo-cd \
  -n argocd \
  -f platform/argocd/values.yaml
```

### 7. Add or Correct Keycloak Service

If the backend should use `eurotransit-keycloak-service`, add this Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: eurotransit-keycloak-service
  namespace: eurotransit
spec:
  selector:
    app: keycloak
    app.kubernetes.io/instance: eurotransit-keycloak
    app.kubernetes.io/managed-by: keycloak-operator
  ports:
    - name: http
      port: 8080
      targetPort: http
```

Also ensure `/auth` is routed publicly if Keycloak must be available at:

```text
https://g02.cpo2026.it/auth
```

## Final Conclusion

The application is not down behind Traefik. The current `404` on the Azure
cloudapp hostname is expected because the Ingress is host-based.

The real incident is a combination of:

1. stale public DNS pointing to the old Azure IP,
2. live Traefik Service drift from committed Helm values,
3. cert-manager HTTP-01 blocked by DNS drift,
4. missing static Public IP design,
5. separate ArgoCD ingressClass mismatch,
6. missing Keycloak Service for backend JWKS/token URLs.

The fastest recovery path is:

1. repoint `g02.cpo2026.it` and `argocd.g02.cpo2026.it` to the current
   `g02-entrypoint-2026` Azure hostname,
2. commit the Traefik DNS label change,
3. allow or refresh cert-manager issuance,
4. then replace the temporary dynamic-IP design with a pre-created static Azure
   Public IP.
---

## Independent Re-Audit Update - 2026-07-13 14:22 Europe/Rome

This update challenges the original conclusion that "only public DNS remains".
That conclusion was incomplete.

### Current Conclusion

Updating public DNS is necessary, but it was not sufficient at the time of the
live audit.

Three independent issues were found:

1. Public DNS still points to the old Azure endpoint.
2. The repository still had the old Traefik Azure DNS label and could overwrite
   the live hotfix on a future Helm upgrade.
3. The live cluster had hidden routing failures after DNS/LB repair:
   - Traefik was scheduled on a NotReady AKS node.
   - EuroTransit application pods were also scheduled on the same NotReady node.
   - ArgoCD Ingress referenced a Traefik Middleware that was not present in the
     live `argocd` namespace.

The live cluster was partially repaired during this audit by rescheduling
Deployment-managed pods off the NotReady node and applying the missing ArgoCD
Middleware.

### Repository Findings

#### Traefik Azure Annotation Drift

File: `platform/traefik/values.yaml`

Before this audit, the repo still had:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint
```

Live Service had:

```yaml
service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

Required fix applied in repo:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

This prevents a future `helm upgrade traefik ... -f platform/traefik/values.yaml`
from reverting the label to `g02-entrypoint` and triggering `DnsRecordInUse`
again.

The same file also used older logging keys:

```yaml
log:
  level: DEBUG
accessLog:
  enabled: true
```

Rendering the current `traefik/traefik` chart failed schema validation with
those keys. The repo was updated to the supported structure:

```yaml
logs:
  general:
    level: DEBUG
  access:
    enabled: true
```

Validation after the change:

```bash
helm template traefik traefik/traefik --namespace traefik -f platform/traefik/values.yaml
```

Result: passed, and the rendered Service contains:

```yaml
service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

#### Application Ingress

File: `deploy/charts/eurotransit/templates/ingress.yaml`

Verified:

```yaml
ingressClassName: traefik
tls:
  - hosts:
      - g02.cpo2026.it
    secretName: eurotransit-tls
rules:
  - host: g02.cpo2026.it
```

This means requests to the Azure hostname
`g02-entrypoint-2026.polandcentral.cloudapp.azure.com` are not expected to match
the application Ingress. A 404 on the Azure hostname is valid Host-header
routing behavior.

#### ArgoCD Ingress

File: `platform/argocd/values.yaml`

Verified:

```yaml
global:
  domain: argocd.g02.cpo2026.it
server:
  ingress:
    enabled: true
    className: traefik
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
      traefik.ingress.kubernetes.io/router.middlewares: argocd-redirect-https@kubernetescrd
    host: argocd.g02.cpo2026.it
    tls:
      enabled: true
      secretName: argocd-server-tls
```

The annotation is valid only if `platform/argocd/middleware.yaml` is applied.
Live cluster did not have that Middleware, so Traefik logged:

```text
middleware "argocd-redirect-https@kubernetescrd" does not exist
```

That produced a hidden 404 for `argocd.g02.cpo2026.it` even after Traefik became
reachable.

Live fix applied:

```bash
kubectl apply -f platform/argocd/middleware.yaml
```

Result:

```text
middleware.traefik.io/redirect-https created
```

#### cert-manager

Files:

- `platform/cert-manager/letsencrypt-prod.yaml`
- `deploy/charts/eurotransit/templates/ingress.yaml`
- `platform/argocd/values.yaml`

Repository solver configuration is correct:

```yaml
solvers:
  - http01:
      ingress:
        ingressClassName: traefik
```

Live `letsencrypt-prod` ClusterIssuer is Ready, but differs from repo metadata:

```text
Repo email: s349024@studenti.polito.it
Live email: akarcaykr@gmail.com
Repo privateKeySecretRef: letsencrypt-prod
Live privateKeySecretRef: letsencrypt-prod-account-key
```

This does not block HTTP-01 routing, but it is Git/live drift that should be
standardized.

### Live Cluster Evidence

#### Traefik Service

Command:

```bash
kubectl -n traefik get svc traefik -o wide
```

Observed:

```text
TYPE           EXTERNAL-IP    PORT(S)
LoadBalancer   134.112.8.66   80:31483/TCP,443:32142/TCP
```

Live annotation:

```text
service.beta.kubernetes.io/azure-dns-label-name=g02-entrypoint-2026
```

Azure DNS:

```bash
dig +short g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

Observed:

```text
134.112.8.66
```

Azure Public IP audit:

```text
name: kubernetes-a18745822eff349198a98b394c413147
resourceGroup: mc_g_06_lab02cluster_polandcentral
ipAddress: 134.112.8.66
fqdn: g02-entrypoint-2026.polandcentral.cloudapp.azure.com
allocation: Static
```

The current Public IP is static in Azure, but it is AKS-created and generated
name based. It is not a deliberately pre-created named platform asset.

#### Public DNS

Commands:

```bash
dig +short g02.cpo2026.it
dig +short argocd.g02.cpo2026.it
```

Observed:

```text
g02-entrypoint.polandcentral.cloudapp.azure.com.
134.112.166.65

g02-entrypoint.polandcentral.cloudapp.azure.com.
134.112.166.65
```

Therefore public DNS still points to the old endpoint, not to the current
Traefik IP.

The hostname variant from the incident prompt, `g02.cp02026.it`, did not resolve
during this audit. The repository and live cluster use `g02.cpo2026.it`.

#### Node and Pod Health

Command:

```bash
kubectl get nodes -o wide
```

Observed:

```text
aks-cloudlab02-33508055-vms21   Ready
aks-cloudlab02-33508055-vms22   Ready
aks-cloudlab02-33508055-vms23   NotReady
```

Traefik and most EuroTransit pods were initially on `vms23`, the NotReady node.
This caused external curls to `134.112.8.66` to time out even with correct Host
headers.

Live fix applied:

```bash
kubectl -n traefik delete pod traefik-646bff88f6-gxjbd
kubectl -n traefik delete pod traefik-646bff88f6-gxjbd --force --grace-period=0
kubectl -n eurotransit delete pod eurotransit-frontend-785f6d5f97-hm85t --force --grace-period=0
kubectl -n eurotransit delete pod eurotransit-catalog-77d9675cbc-59bmc --force --grace-period=0
kubectl -n eurotransit delete pod eurotransit-orders-5496bbbbcd-km2m8 --force --grace-period=0
kubectl -n eurotransit delete pod eurotransit-payments-7496f7d9b9-4n4b4 --force --grace-period=0
kubectl -n eurotransit delete pod eurotransit-inventory-84dd487584-bt85d --force --grace-period=0
kubectl -n eurotransit delete pod eurotransit-notifications-57d4b64d-t7j4b --force --grace-period=0
```

After rescheduling:

```text
traefik                    1/1 Available
eurotransit-frontend       1/1 Available
eurotransit-catalog        1/1 Available
eurotransit-orders         1/1 Available
eurotransit-payments       1/1 Available
eurotransit-inventory      1/1 Available
```

#### Current Route Tests Against 134.112.8.66

Application HTTP:

```bash
curl -I --max-time 10 -H 'Host: g02.cpo2026.it' http://134.112.8.66/
```

Observed:

```text
HTTP/1.1 308 Permanent Redirect
Location: https://g02.cpo2026.it/
```

Application HTTPS:

```bash
curl -k -I --resolve g02.cpo2026.it:443:134.112.8.66 https://g02.cpo2026.it/
```

Observed:

```text
HTTP/2 200
server: nginx/1.31.2
```

Catalog HTTPS:

```bash
curl -k -I --resolve g02.cpo2026.it:443:134.112.8.66 https://g02.cpo2026.it/api/v1/catalog/products
```

Observed:

```text
HTTP/2 200
content-type: application/json
```

ArgoCD HTTP after applying missing Middleware:

```bash
curl -I --max-time 10 -H 'Host: argocd.g02.cpo2026.it' http://134.112.8.66/
```

Observed:

```text
HTTP/1.1 308 Permanent Redirect
Location: https://argocd.g02.cpo2026.it/
```

ArgoCD HTTPS after applying missing Middleware:

```bash
curl -k -I --resolve argocd.g02.cpo2026.it:443:134.112.8.66 https://argocd.g02.cpo2026.it/
```

Observed:

```text
HTTP/2 200
content-type: text/html; charset=utf-8
```

### cert-manager Recovery Assessment

Live certificates remain pending:

```text
argocd/argocd-server-tls    Ready=False
eurotransit/eurotransit-tls Ready=False
```

Challenge reason:

```text
Waiting for HTTP-01 challenge propagation:
failed to perform self check GET request
context deadline exceeded
```

This is consistent with public DNS still resolving to old IP `134.112.166.65`.
cert-manager self-check uses the public DNS name, so it will not pass until DNS
for `g02.cpo2026.it` and `argocd.g02.cpo2026.it` reaches `134.112.8.66`.

After DNS is updated, cert-manager should retry automatically. If it remains
stuck after DNS TTL and propagation, refresh the pending ACME state:

```bash
kubectl delete challenge,order -n eurotransit --all
kubectl delete challenge,order -n argocd --all
kubectl describe certificate -n eurotransit eurotransit-tls
kubectl describe certificate -n argocd argocd-server-tls
```

### Is DNS Update Sufficient?

DNS update is now likely sufficient for the public application and ArgoCD routes
because the other hidden live issues were fixed during this audit:

- Traefik is on a Ready node and Available.
- App pods are rescheduled and Available.
- ArgoCD Middleware exists.
- Direct Host/SNI tests against `134.112.8.66` return expected HTTP/HTTPS
  responses.

Before those live fixes, DNS update alone was not sufficient.

Required DNS changes:

```text
g02.cpo2026.it        -> g02-entrypoint-2026.polandcentral.cloudapp.azure.com
argocd.g02.cpo2026.it -> g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

Direct A records to `134.112.8.66` would also work now, but CNAME to the Azure
FQDN is operationally cleaner while this IP is managed by the AKS Service.

### Static Public IP Architecture

The current Public IP is Static, but it was AKS-created with generated name:

```text
kubernetes-a18745822eff349198a98b394c413147
```

Better long-term architecture:

1. Pre-create a named static Public IP, for example `pip-traefik-g02`.
2. Assign the DNS label intentionally.
3. Configure Traefik Service with:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: mc_g_06_lab02cluster_polandcentral
    service.beta.kubernetes.io/azure-pip-name: pip-traefik-g02
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint
```

Do not add `azure-pip-name: pip-traefik-g02` until that Public IP actually
exists. Adding a non-existent PIP name would break LoadBalancer reconciliation.

### End-to-End Request Flow

| Hop | Current state | Verified | Potential issue | Required fix |
| --- | --- | --- | --- | --- |
| Internet client | Public requests use `g02.cpo2026.it` / `argocd.g02.cpo2026.it`. | Partially | Public DNS still points to old IP. | Update external DNS to `g02-entrypoint-2026.polandcentral.cloudapp.azure.com`. |
| DNS | `g02.cpo2026.it` and `argocd.g02.cpo2026.it` resolve to old `g02-entrypoint` / `134.112.166.65`. | Yes | cert-manager and users hit old endpoint. | Change both records to current Azure FQDN or `134.112.8.66`. |
| Azure Public IP | Current Traefik PIP is `134.112.8.66`, FQDN `g02-entrypoint-2026...`, allocation Static. | Yes | PIP name is generated, not intentionally pre-created. | Short term: use current PIP. Long term: pre-create named static PIP. |
| Azure Load Balancer | Kubernetes Service reports `LoadBalancer Ingress: 134.112.8.66`. | Yes | Was routing to pod on NotReady node until reschedule. | Completed: rescheduled Traefik pod to Ready node. |
| Traefik Service | `traefik/traefik` LoadBalancer, ports 80/443, DNS label `g02-entrypoint-2026`. | Yes | Repo previously had old label. | Completed in repo: updated `platform/traefik/values.yaml`. |
| Traefik Pod | Now running on Ready node `vms21`, Deployment `1/1`. | Yes | Old pod on NotReady node created timeouts. | Completed: deleted stale pod. |
| Ingress | App and ArgoCD Ingress use class `traefik`, expected hosts, address `134.112.8.66`. | Yes | ArgoCD missing Middleware caused 404. | Completed: applied `platform/argocd/middleware.yaml`. |
| TLS/cert-manager | ClusterIssuer Ready; Certificates still `Ready=False`; HTTP-01 Challenges pending. | Yes | DNS still points to old IP, so self-check times out. | Update DNS, then wait or refresh Challenges/Orders. |
| Middleware | EuroTransit redirect middleware exists through Helm chart; ArgoCD middleware was missing. | Yes | ArgoCD router failed while middleware absent. | Completed live; keep applying platform middleware with ArgoCD install/upgrade. |
| Services | Frontend/catalog/orders/payments/inventory Services target correct ports. | Yes | Endpoints were stale on NotReady node. | Completed for Deployment pods; DB pods on NotReady still need platform attention. |
| Pods | App Deployment pods rescheduled and `1/1 Available`. | Yes | DB pods and some platform pods still exist on NotReady node. | Follow up with node recovery/drain and CNPG health validation. |

### Final Required Actions

1. Update public DNS:

   ```text
   g02.cpo2026.it        CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
   argocd.g02.cpo2026.it CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
   ```

2. Keep `platform/traefik/values.yaml` aligned with
   `g02-entrypoint-2026` until a named static PIP migration is performed.

3. Ensure `platform/argocd/middleware.yaml` is applied whenever ArgoCD is
   installed/upgraded.

4. After DNS propagates, verify:

   ```bash
   dig +short g02.cpo2026.it
   dig +short argocd.g02.cpo2026.it
   curl -I http://g02.cpo2026.it/
   curl -I http://argocd.g02.cpo2026.it/
   kubectl get certificates -A
   ```

5. Follow up on `aks-cloudlab02-33508055-vms23` being NotReady. Several database
   and platform pods are still associated with that node, and this can cause new
   hidden failures after the ingress path is fixed.

## Scheduling Evidence Update - 2026-07-13 14:45 Europe/Rome

This update records the final read-only investigation after the node scheduling
incident review. It is included to separate the DNS root cause from the
independent AKS scheduling/capacity symptoms observed during remediation.

### Current node state

```text
aks-cloudlab02-33508055-vms21   NotReady,SchedulingDisabled
aks-cloudlab02-33508055-vms22   Ready
aks-cloudlab02-33508055-vms23   Ready
```

Interpretation:

- `vms21` is not schedulable. It is `NotReady`, `Unschedulable: true`, and has
  `node.kubernetes.io/unreachable` plus `node.kubernetes.io/unschedulable`
  taints.
- `vms22` is schedulable but was full during the incident window:
  `Non-terminated Pods: 30`, with node capacity `pods: 30`.
- `vms23` became schedulable again after node recovery. New pending pods were
  scheduled there once it was available.

### Evidence for the temporary Pending pod root cause

The Kubernetes scheduler reported the same reason across Traefik,
cert-manager, EuroTransit, monitoring, Kafka operator, and sealed-secrets pods:

```text
0/3 nodes are available: 1 Too many pods, 2 node(s) were unschedulable.
preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod,
2 Preemption is not helpful for scheduling.
```

This proves the temporary Pending state was caused by node scheduling capacity,
not by DNS, not by image pull, and not by PVC binding.

Examples:

```text
traefik/traefik-646bff88f6-r6kd9
cert-manager/cert-manager-7d8d96978d-vt6c9
cert-manager/cert-manager-cainjector-69dfd57466-2l5l9
cert-manager/cert-manager-webhook-56d97f58cb-5swtc
eurotransit/eurotransit-frontend-785f6d5f97-vm7jp
eurotransit/eurotransit-catalog-77d9675cbc-gzqzn
eurotransit/eurotransit-inventory-84dd487584-w8qqp
eurotransit/eurotransit-orders-5496bbbbcd-z5wck
eurotransit/eurotransit-payments-7496f7d9b9-z2vf6
```

### Current pod state after node recovery

At final read-only verification:

```text
kubectl get pods -A --field-selector=status.phase=Pending
No resources found
```

Traefik is running and serving from `vms23`:

```text
traefik-646bff88f6-r6kd9   1/1 Running   10.244.0.94   aks-cloudlab02-33508055-vms23
```

cert-manager is running:

```text
cert-manager              1/1 Running
cert-manager-cainjector   1/1 Running
cert-manager-webhook      1/1 Running
```

EuroTransit Deployments are available:

```text
eurotransit-catalog         1/1
eurotransit-frontend        1/1
eurotransit-inventory       1/1
eurotransit-notifications   1/1
eurotransit-orders          1/1
eurotransit-payments        1/1
```

### DNS remains a separate unresolved issue

Direct Host/SNI routing to the current Traefik IP works:

```text
curl -H 'Host: g02.cpo2026.it' http://134.112.8.66/
HTTP/1.1 308 Permanent Redirect

curl -k --resolve g02.cpo2026.it:443:134.112.8.66 https://g02.cpo2026.it/
HTTP/2 200

curl -k --resolve argocd.g02.cpo2026.it:443:134.112.8.66 https://argocd.g02.cpo2026.it/
HTTP/2 200
```

But public DNS still points to the old endpoint:

```text
g02.cpo2026.it        -> g02-entrypoint.polandcentral.cloudapp.azure.com -> 134.112.166.65
argocd.g02.cpo2026.it -> g02-entrypoint.polandcentral.cloudapp.azure.com -> 134.112.166.65
```

Therefore the remaining public ingress fix is still:

```text
g02.cpo2026.it        CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
argocd.g02.cpo2026.it CNAME g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

### cert-manager status

Certificates are still pending because HTTP-01 self-checks follow public DNS and
therefore still reach the old endpoint:

```text
argocd/argocd-server-tls    Ready=False
eurotransit/eurotransit-tls Ready=False
```

Challenge reason:

```text
Waiting for HTTP-01 challenge propagation:
failed to perform self check GET request ... context deadline exceeded
```

Once DNS is updated and propagated, cert-manager should retry automatically. If
it remains stuck after DNS propagation, delete the pending Orders/Challenges for
the two Certificates and allow cert-manager to recreate them.
