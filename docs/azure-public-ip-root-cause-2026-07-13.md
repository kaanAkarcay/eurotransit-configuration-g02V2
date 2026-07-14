# Azure Public IP Root Cause Report

Date: 2026-07-13

Scope: AKS, Traefik Helm values, Kubernetes Service manifests, Azure Load Balancer, Azure Public IP resources, Git history.

## Executive conclusion

Azure used a different Public IP because the Traefik Kubernetes Service was not
configured to reuse a specific existing Azure Public IP.

The Service requested only:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint
```

That annotation requests an Azure DNS label on whichever Public IP the AKS cloud
provider assigns. It does not identify, reserve, or reattach a particular Public
IP resource.

No evidence was found that the project ever configured either of the persistent
IP mechanisms:

```yaml
service.beta.kubernetes.io/azure-pip-name: <existing-public-ip-name>
service.beta.kubernetes.io/azure-load-balancer-resource-group: <resource-group>
```

or:

```yaml
loadBalancerIP: <existing-ip-address>
```

Therefore Azure is behaving correctly for the configuration it was given. The
configuration allowed AKS to create or attach an automatically managed Public IP
for the Service. When the previous Azure DNS label was unavailable, changing the
label to `g02-entrypoint-2026` allowed Azure to create/configure a new
AKS-managed Public IP:

```text
134.112.8.66
g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

The engineering root cause is an infrastructure design gap: the ingress
entrypoint was not bound to a pre-created, persistent Azure Public IP.

## Repository evidence

### Current Traefik values

File: `platform/traefik/values.yaml`

Relevant lines:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

The file does not contain:

```text
service.beta.kubernetes.io/azure-pip-name
service.beta.kubernetes.io/azure-load-balancer-resource-group
loadBalancerIP
```

### Original Traefik values

The Traefik values file was introduced in commit:

```text
071fc6794483e275cd55181308220f76c6f9733a
boostrap: adapt lab05 config for eurotransit
```

Original content:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint
```

This proves the original design requested an Azure DNS label, but did not bind
the Service to a named or pre-created Public IP.

### Git history audit

Commands used:

```bash
git log --all --follow -p -- platform/traefik/values.yaml
git log --all -G "azure-(pip-name|load-balancer)|loadBalancerIP|azure-dns-label-name|g02-entrypoint" --name-status -- .
git log --all -S azure-pip-name --oneline --decorate -- .
git log --all -S loadBalancerIP --oneline --decorate -- .
```

Findings:

- `loadBalancerIP` was not found in project history.
- `azure-pip-name` was not found in any historical Traefik manifest or Helm
  values file.
- `azure-load-balancer-resource-group` was not found in any historical Traefik
  manifest or Helm values file.
- No commit was found that removed static Public IP binding from the Traefik
  Service.
- The only long-lived Traefik Service annotation in history was
  `service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint`.

Conclusion: this is not a regression caused by removing static IP configuration.
The static IP binding was never present in the actual Traefik values.

## Live Kubernetes evidence

### Traefik Service

Live object:

```text
namespace: traefik
service: traefik
type: LoadBalancer
uid: 18745822-eff3-4919-8a98-b394c4131470
external IP: 134.112.8.66
```

Live annotations:

```yaml
meta.helm.sh/release-name: traefik
meta.helm.sh/release-namespace: traefik
service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

Live Service spec does not include:

```text
spec.loadBalancerIP
azure-pip-name
azure-load-balancer-resource-group
```

This proves the live Service still does not reference an existing Public IP.

### Helm release state

Command:

```bash
helm history traefik -n traefik
```

Result:

```text
REVISION  STATUS    CHART           APP VERSION  DESCRIPTION
1         deployed  traefik-41.0.2   v3.7.6       Install complete
```

There is no Helm history evidence of an upgrade or reinstall after the Traefik
release was installed.

Command:

```bash
helm get values traefik -n traefik -o yaml
```

Result:

```yaml
service:
  annotations:
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint
  type: LoadBalancer
```

This shows live Helm values still contain the old DNS label, while the live
Service has been manually changed to `g02-entrypoint-2026`. A future Helm
upgrade using the current live release values would attempt to restore
`g02-entrypoint`.

## Azure resource evidence

### Current Public IP used by Traefik

Azure resource:

```text
type: Microsoft.Network/publicIPAddresses
name: kubernetes-a18745822eff349198a98b394c413147
resource group: mc_g_06_lab02cluster_polandcentral
location: polandcentral
ipAddress: 134.112.8.66
allocation: Static
sku: Standard
dns label: g02-entrypoint-2026
fqdn: g02-entrypoint-2026.polandcentral.cloudapp.azure.com
```

Relevant tags:

```text
k8s-azure-service: traefik/traefik
k8s-azure-dns-label-service: traefik/traefik
k8s-azure-cluster-name: kubernetes
aks-managed-cluster-name: lab02cluster
aks-managed-cluster-rg: g_06
```

The generated name and Kubernetes tags prove this is an AKS-managed Public IP
for the Kubernetes Service, not a deliberately named persistent ingress IP.

### Azure Load Balancer

Azure resource:

```text
type: Microsoft.Network/loadBalancers
name: kubernetes
resource group: mc_g_06_lab02cluster_polandcentral
```

Frontend configuration used by Traefik:

```text
frontendIPConfiguration: a18745822eff349198a98b394c413147
publicIPAddress: kubernetes-a18745822eff349198a98b394c413147
```

Load balancing rules:

```text
a18745822eff349198a98b394c413147-TCP-80
a18745822eff349198a98b394c413147-TCP-443
```

Health probes:

```text
a18745822eff349198a98b394c413147-TCP-80  -> nodePort 31483
a18745822eff349198a98b394c413147-TCP-443 -> nodePort 32142
```

### Old Public IP / DNS label

Command:

```bash
az network public-ip list \
  --query "[?ipAddress=='134.112.166.65' || dnsSettings.domainNameLabel=='g02-entrypoint' || dnsSettings.fqdn=='g02-entrypoint.polandcentral.cloudapp.azure.com']"
```

Result:

```json
[]
```

The old Public IP `134.112.166.65` and old DNS label `g02-entrypoint` are not
present in the current subscription's Public IP inventory.

## Why Azure did not reuse the previous IP

The Service did not tell Azure which Public IP to reuse.

AKS had this information:

```yaml
type: LoadBalancer
azure-dns-label-name: g02-entrypoint
```

AKS did not have this information:

```yaml
azure-pip-name: <stable-public-ip-resource-name>
azure-load-balancer-resource-group: <resource-group-containing-that-ip>
loadBalancerIP: <stable-ip-address>
```

Because no stable Public IP reference existed, the cloud provider was free to
create or attach an AKS-managed Public IP for the Service. The Azure DNS label
is metadata on the Public IP resource; it is not a durable identity for the
load balancer frontend.

When the previous label `g02-entrypoint` was unavailable, Azure could not assign
that label to the newly reconciled Public IP. Changing the label to
`g02-entrypoint-2026` allowed reconciliation to complete, but naturally produced
a different Azure FQDN and IP.

## Configuration regression assessment

No evidence was found that a static Public IP configuration was removed.

This is not a regression from:

```text
azure-pip-name
azure-load-balancer-resource-group
loadBalancerIP
```

The actual regression is architectural: the original configuration assumed the
Azure DNS label would remain stable across cluster or Service recreation, but
did not create and reference a persistent Azure Public IP resource to make that
assumption true.

## Azure-native recommended fix

Immediate incident fix: preserve the current working Public IP and bind Traefik
to it explicitly by Azure Public IP resource name.

The current Public IP is already Standard, Static, attached to the Traefik Load
Balancer frontend, and tagged for `traefik/traefik`:

```text
resource group: MC_G_06_Lab02cluster_polandcentral
name: kubernetes-a18745822eff349198a98b394c413147
ip: 134.112.8.66
fqdn: g02-entrypoint-2026.polandcentral.cloudapp.azure.com
sku: Standard
allocation: Static
tags: k8s-azure-service=traefik/traefik
```

### 1. Bind Traefik Service to the current Public IP

Update `platform/traefik/values.yaml`:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: MC_G_06_Lab02cluster_polandcentral
    service.beta.kubernetes.io/azure-pip-name: kubernetes-a18745822eff349198a98b394c413147
    service.beta.kubernetes.io/azure-dns-label-name: g02-entrypoint-2026
```

Do not rely on `azure-dns-label-name` alone. Microsoft AKS documentation
recommends service annotations for static public IP binding, specifically
`service.beta.kubernetes.io/azure-pip-name` and
`service.beta.kubernetes.io/azure-load-balancer-resource-group`.

### 2. Validate before applying

```bash
helm template traefik traefik/traefik \
  --version 41.0.2 \
  --namespace traefik \
  -f platform/traefik/values.yaml

helm template traefik traefik/traefik \
  --version 41.0.2 \
  --namespace traefik \
  -f platform/traefik/values.yaml \
  | kubectl -n traefik apply --dry-run=server -f -
```

The validated render keeps `replicas: 1` during incident recovery and changes
only the Traefik Service annotations relevant to the Public IP binding.

### 3. Apply with Helm after approval

```bash
helm upgrade traefik traefik/traefik \
  --version 41.0.2 \
  --namespace traefik \
  -f platform/traefik/values.yaml \
  --timeout 10m
```

### 4. Verify Azure binding

```bash
kubectl -n traefik get svc traefik -o wide
kubectl -n traefik describe svc traefik

az network public-ip show \
  --resource-group MC_G_06_Lab02cluster_polandcentral \
  --name kubernetes-a18745822eff349198a98b394c413147 \
  --query "{ip:ipAddress,fqdn:dnsSettings.fqdn,attached:ipConfiguration.id,provisioning:provisioningState}"
```

Expected:

```text
Traefik Service external IP remains 134.112.8.66
Azure Public IP fqdn remains g02-entrypoint-2026.polandcentral.cloudapp.azure.com
Azure Load Balancer frontend still references kubernetes-a18745822eff349198a98b394c413147
No DnsRecordInUse event appears
```

### Longer-term option

After the incident, the cleaner design is to create a deliberately named static
Public IP such as `pip-traefik-g02`, bind Traefik to that name, and make the
domain CNAME point to the Azure DNS label on that stable resource. Do not do
that during the incident unless reusing the current IP is proven unsafe,
because creating a replacement PIP would introduce another public endpoint
change.

```bash
az network public-ip create \
  --resource-group MC_G_06_Lab02cluster_polandcentral \
  --name pip-traefik-g02 \
  --sku Standard \
  --allocation-method Static \
  --dns-name g02-entrypoint
```

If `g02-entrypoint` is still unavailable, first locate and release the Azure
Public IP that currently owns that label. If it is inaccessible from the current
Azure tenant/subscriptions, the existing authoritative CNAMEs must be updated to
the current reachable Azure FQDN.

## Final root cause

The root cause is not Traefik routing, ingress rules, service ports, or
cert-manager.

The root cause is that the Traefik LoadBalancer Service was configured with only
an Azure DNS label and no persistent Azure Public IP reference. This allowed AKS
to manage the Public IP lifecycle automatically. After cluster or Service
reconciliation, Azure could not reuse the old label/IP because the Service did
not reference a specific Public IP resource, and the old label was unavailable.

Azure behaved correctly for the provided configuration. The infrastructure was
not designed to survive cluster or Service recreation while preserving the same
ingress Public IP.
