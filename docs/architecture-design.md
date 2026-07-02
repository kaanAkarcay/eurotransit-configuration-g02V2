# EuroTransit — Architecture Design

## 1. System overview

```
                          ┌──────────────────────────────────────────────────────────┐
                          │                    AKS Cluster                           │
                          │                                                          │
  Browser ──── HTTPS ────►│  ┌──────────┐                                            │
                          │  │ Traefik  │ (Ingress Controller / API Gateway)          │
                          │  └────┬─────┘                                            │
                          │       │                                                  │
                          │       ├── /                  ──► Frontend (nginx, :80)    │
                          │       ├── /api/v1/catalog    ──► Catalog  (:8080)         │
                          │       └── /api/v1/orders     ──► Orders   (:8080)         │
                          │                                                          │
                          │  Internal services (no Ingress route):                   │
                          │       Inventory (:8080)                                  │
                          │       Payments  (:8080)                                  │
                          │       Notifications (:8080)                              │
                          │                                                          │
                          │  Data layer:                                             │
                          │       Kafka (Strimzi)     ──  8 event topics             │
                          │       PostgreSQL (CNPG)   ──  3 clusters: orders-db,     │
                          │                               inventory-db, payments-db  │
                          │                                                          │
                          │  Platform:                                               │
                          │       Argo CD         ──  GitOps delivery                 │
                          │       Prometheus      ──  metrics + alerts                │
                          │       Grafana         ──  dashboards                      │
                          │       Chaos Mesh      ──  fault injection                 │
                          │       Sealed Secrets  ──  encrypted secrets in Git        │
                          │                                                          │
                          └──────────────────────────────────────────────────────────┘
```

## 2. Backend services

Each service is an independent Spring Boot (Kotlin) application with its own:
- codebase (folder in the app repo)
- Dockerfile
- Docker image on ACR
- Kubernetes Deployment + Service
- ServiceMonitor (Prometheus scraping via /actuator/prometheus)
- own CloudNativePG cluster and database — Orders, Inventory, and Payments only. Catalog is stateless/read-only and Notifications needs no durable dedup, so neither gets a CNPG cluster.

### Service responsibilities

```
┌────────────────┬────────────────────────────────────────────────────────────┐
│ Service        │ What it does                                              │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Catalog        │ GET /api/v1/catalog/products — lists trains + prices.     │
│                │ Read-only, tolerant of staleness. No Kafka, no DB.        │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Orders         │ POST /api/v1/orders — accepts order, returns 202 PENDING. │
│                │ GET /api/v1/orders/{id} — polling for status.             │
│                │ Orchestrator: publishes order-placed and payment-         │
│                │ requested; consumes inventory-reserved/-reservation-      │
│                │ failed and payment-authorized/-failed to drive the        │
│                │ order state machine. No synchronous calls to Inventory    │
│                │ or Payments — every cross-service hop is Kafka.           │
│                │ Owns own CNPG cluster (orders-db): orders,                │
│                │ processed_requests, processed_events.                    │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Inventory      │ Consumes order-placed, reserves seats atomically via      │
│                │ PostgreSQL UPDATE ... WHERE available >= qty.             │
│                │ Publishes inventory-reserved or inventory-reservation-     │
│                │ failed. Consumes order-failed for compensation (release). │
│                │ Owns own CNPG cluster (inventory-db): seats,              │
│                │ processed_events.                                         │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Payments       │ Consumes payment-requested. Calls the external payment    │
│                │ gateway — the one remaining synchronous remote call in    │
│                │ the whole system — wrapped in a circuit breaker (open /   │
│                │ half-open, safe fallback = publish payment-failed).       │
│                │ Publishes payment-authorized or payment-failed. Same      │
│                │ idempotency pattern as every other consumer (see §3.2 of  │
│                │ the contract): processed_events keyed on event_id,        │
│                │ checked in the same transaction as the business write.    │
│                │ Owns own CNPG cluster (payments-db): transactions,        │
│                │ processed_events.                                         │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Notifications  │ Consumes order-confirmed and order-failed.                │
│                │ Fully async, fire-and-forget. Logs confirmation.          │
│                │ Graceful degradation: if down, checkout still works.      │
│                │ No CNPG cluster (best-effort, no durable dedup needed).   │
└────────────────┴────────────────────────────────────────────────────────────┘
```

### Service communication

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│  Client ──POST /orders──► Orders ──202 PENDING──► Client                 │
│                              │                                           │
│                    publishes │ Kafka: order-placed                        │
│                              ▼                                           │
│                          Inventory                                       │
│                           │    │                                         │
│              ┌────────────┘    └──────────────┐                          │
│              ▼                                ▼                          │
│     Kafka: inventory-reserved      Kafka: inventory-reservation-failed   │
│              │                                │                          │
│              ▼                                ▼                          │
│           Orders                           Orders                        │
│              │                          (sets FAILED,                     │
│    publishes │ Kafka: payment-requested   publishes order-failed)         │
│              ▼                                                           │
│          Payments                                                        │
│              │                                                           │
│   sync HTTP  │  (circuit breaker: open/half-open,                        │
│              │   fallback = publish payment-failed)                      │
│              ▼                                                           │
│  external payment gateway                                                │
│              │                                                           │
│              ▼                                                           │
│          Payments                                                        │
│           │    │                                                         │
│  ┌────────┘    └──────────┐                                              │
│  ▼                        ▼                                              │
│ Kafka:                    Kafka:                                          │
│ payment-authorized        payment-failed                                 │
│  │                        │                                              │
│  ▼                        ▼                                              │
│ Orders                   Orders                                          │
│ (sets CONFIRMED,         (sets FAILED,                                   │
│  publishes                publishes order-failed)                        │
│  order-confirmed)                                                        │
│  │                                                                       │
│  ▼                                                                       │
│ Notifications (logs / email)                                             │
│                                                                          │
│  order-failed (from either the inventory stage or the payment stage):    │
│     ──► Inventory consumes order-failed, releases reservation if one     │
│         was held (compensation)                                          │
│     ──► Notifications consumes order-failed, sends failure notice        │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

Legend:
  ───► Kafka:    = async event via Kafka topic (every cross-service hop)
  ───► sync HTTP = the one remaining synchronous remote call in the system:
                   Payments' own outbound call to the external payment
                   gateway. It is not a call between our own services.
```

### Kafka topics

```
Topic                                  Producer       Consumer(s)
─────────────────────────────────────  ─────────────  ──────────────────────
eurotransit.order-placed               Orders         Inventory
eurotransit.inventory-reserved         Inventory      Orders
eurotransit.inventory-reservation-     Inventory      Orders
  failed
eurotransit.payment-requested          Orders         Payments
eurotransit.payment-authorized         Payments       Orders
eurotransit.payment-failed             Payments       Orders
eurotransit.order-confirmed            Orders         Notifications
eurotransit.order-failed               Orders         Inventory, Notifications
```

### Order state machine

```
PENDING ──► RESERVED ──► CONFIRMED
   │            │
   ▼            ▼
 FAILED       FAILED (+ release reservation)
```

## 3. Frontend

A simple SPA (React, Vue, or plain HTML) served by nginx on port 80.

Pages:
- Product listing (calls GET /api/v1/catalog/products)
- Buy button (calls POST /api/v1/orders with idempotency_key)
- Order status (polls GET /api/v1/orders/{id} until CONFIRMED or FAILED)

The frontend is a thin client. No business logic, no auth, no state management beyond the current order. It runs in a container with nginx, served through Traefik at path `/`.

## 4. CI pipeline (application repo)

Lives in the **application repo** as a GitHub Actions workflow.

```
Developer pushes code
        │
        ▼
┌─ GitHub Actions ──────────────────────────────────────────────────┐
│                                                                    │
│  On PR to dev:                                                     │
│    1. ./gradlew build                                              │
│    2. ./gradlew test                                               │
│    ──► PR gets green check or red X. No image built. No deploy.    │
│                                                                    │
│  On merge to dev:                                                  │
│    1. ./gradlew build                                              │
│    2. ./gradlew test                                               │
│    3. docker build → tag with commit SHA                           │
│    4. docker push → lab02clusterregistry.azurecr.io/eurotransit/XXX │
│    5. git clone config repo                                        │
│    6. update values.yaml with new image tag                        │
│    7. git commit + push to config repo (main)                      │
│    ──► Config repo is updated. CI is done. No kubectl, no deploy.  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘

Important: CI has NO cluster credentials. It only pushes images and updates YAML.
```

### App repo structure

```
eurotransit-application/
├── catalog/
│   ├── src/
│   ├── build.gradle.kts
│   └── Dockerfile
├── orders/
│   ├── src/
│   ├── build.gradle.kts
│   └── Dockerfile
├── inventory/
│   ├── src/
│   ├── build.gradle.kts
│   └── Dockerfile
├── payments/
│   ├── src/
│   ├── build.gradle.kts
│   └── Dockerfile
├── notifications/
│   ├── src/
│   ├── build.gradle.kts
│   └── Dockerfile
├── frontend/
│   ├── src/
│   ├── Dockerfile
│   └── nginx.conf
├── .github/workflows/
│   └── ci.yaml
├── docs/
│   ├── eurotransit-contract.md
│   ├── capstone-dod.md
│   ├── agent-log.md
│   └── chaos-reports/
└── justfile
```

## 5. CD pipeline (configuration repo + Argo CD)

Lives in the **configuration repo**. Argo CD runs inside the cluster, watches this repo.

```
Config repo updated (by CI or manually)
        │
        ▼
┌─ Argo CD ─────────────────────────────────────────────────────────┐
│                                                                    │
│  1. Detects new commit on main branch of config repo               │
│  2. Renders Helm chart with new values (including new image tag)   │
│  3. Compares desired state (Git) with live state (cluster)         │
│  4. Applies the diff: rolling update of the changed Deployment     │
│  5. Pod pulls new image from ACR, starts, passes health checks     │
│  6. Old pod is terminated                                          │
│                                                                    │
│  If something breaks:                                              │
│    - Rollback = revert the commit in config repo                   │
│    - Argo CD reconciles back to the previous state                 │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘

Important: Argo CD has cluster credentials. It NEVER builds images.
```

### Config repo structure

```
eurotransit-configuration/
├── deploy/charts/eurotransit/
│   ├── Chart.yaml
│   ├── values.yaml              ← CI updates image tags here
│   └── templates/
│       ├── _helpers.tpl
│       ├── orders-deployment.yaml
│       ├── orders-service.yaml
│       ├── catalog-deployment.yaml
│       ├── catalog-service.yaml
│       ├── inventory-deployment.yaml
│       ├── inventory-service.yaml
│       ├── payments-deployment.yaml
│       ├── payments-service.yaml
│       ├── notifications-deployment.yaml
│       ├── notifications-service.yaml
│       ├── frontend-deployment.yaml
│       ├── frontend-service.yaml
│       ├── ingress.yaml
│       ├── middleware-redirect-https.yaml
│       ├── servicemonitor-backend.yaml
│       └── prometheusrule-backend.yaml
├── platform/
│   ├── argocd/
│   │   ├── eurotransit-application.yaml
│   │   ├── private-config-repo-sealedsecret.yaml
│   │   ├── middleware.yaml
│   │   └── values.yaml
│   ├── cert-manager/
│   ├── cnpg/
│   │   ├── operator-values.yaml
│   │   ├── orders-db-cluster.yaml
│   │   ├── inventory-db-cluster.yaml
│   │   └── payments-db-cluster.yaml
│   ├── observability/
│   │   ├── dashboards/
│   │   └── kube-prometheus-stack-values.yaml
│   ├── strimzi/
│   └── traefik/
├── docs/
└── README.md
```

## 6. Full CI/CD flow (end to end)

```
 Developer          App Repo          GitHub Actions        ACR           Config Repo        Argo CD          Cluster
    │                  │                   │                  │                │                │                │
    │─ push branch ──►│                   │                  │                │                │                │
    │                  │─ PR to dev ──────►│                  │                │                │                │
    │                  │                   │─ build + test    │                │                │                │
    │                  │                   │─ ✓ or ✗ ────────►│                │                │                │
    │                  │                   │                  │                │                │                │
    │─ merge PR ──────►│                   │                  │                │                │                │
    │                  │─ push to dev ────►│                  │                │                │                │
    │                  │                   │─ build + test    │                │                │                │
    │                  │                   │─ docker build    │                │                │                │
    │                  │                   │─ docker push ───►│                │                │                │
    │                  │                   │─ update tag ─────────────────────►│                │                │
    │                  │                   │                  │                │─ new commit ──►│                │
    │                  │                   │                  │                │                │─ helm render   │
    │                  │                   │                  │                │                │─ diff state    │
    │                  │                   │                  │                │                │─ apply ───────►│
    │                  │                   │                  │                │                │                │─ pull image
    │                  │                   │                  │                │                │                │─ start pod
    │                  │                   │                  │                │                │                │─ health ✓
    │                  │                   │                  │                │                │                │
```

## 7. What is NOT needed

- Authentication / JWT / OAuth — not in the capstone requirements
- Real email sending — Notifications just logs
- Complex frontend — a simple page with catalog, buy button, and status polling
- API gateway software (Kong, etc.) — Traefik covers routing
- Shared database across services — Orders, Inventory, and Payments each own a separate CloudNativePG cluster on purpose, so a DB failover or chaos experiment on one doesn't take the others down with it. No cross-service joins or shared schemas.
- Staging environment — one namespace, one cluster
