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
                          │       Kafka (Strimzi)     ──  6 event topics, all owned  │
                          │                               and produced by Orders     │
                          │       PostgreSQL (CNPG)   ──  4 clusters: catalog-db,    │
                          │                               orders-db, inventory-db,   │
                          │                               payments-db                │
                          │                                                          │
                          │  Platform:                                               │
                          │       Argo CD         ──  GitOps delivery                 │
                          │       Prometheus      ──  metrics + alerts                │
                          │       Grafana         ──  dashboards                      │
                          │       Chaos Mesh      ──  fault injection                 │
                          │       Sealed Secrets  ──  encrypted secrets in Git        │
                          │       Keycloak        ──  OIDC provider (JWT issuer)      │
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
- own CloudNativePG cluster and database — Catalog, Orders, Inventory, and Payments. Notifications needs no durable dedup, so it doesn't get a CNPG cluster.

### Service responsibilities

```
┌────────────────┬────────────────────────────────────────────────────────────┐
│ Service        │ What it does                                              │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Catalog        │ GET /api/v1/catalog/products — lists trains + prices.     │
│                │ Read-only, tolerant of staleness. No Kafka. Owns own      │
│                │ CNPG cluster (catalog-db).                                │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Orders         │ POST /api/v1/orders — accepts order, returns 202 PENDING. │
│                │ GET /api/v1/orders/{id} — polling for status.             │
│                │ Orchestrator: four Kafka-driven stages, each one entered  │
│                │ by consuming an event and exited by publishing the next. │
│                │ Stage 1 (order-placed) calls Inventory synchronously to   │
│                │ reserve. Stage 2 (inventory-reserved) calls Payments      │
│                │ synchronously to authorize. Stage 3 (payment-authorized)  │
│                │ confirms. Stage 4 (payment-failed) fails the order and    │
│                │ triggers compensation. Orders is the only service that    │
│                │ both writes to its own DB and publishes to Kafka in the   │
│                │ same step — so it's the only one that needs the outbox.  │
│                │ Owns own CNPG cluster (orders-db): orders,                │
│                │ processed_requests, processed_events, outbox.            │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Inventory      │ POST /reserve — called synchronously by Orders' Stage 1.  │
│                │ Reserves seats atomically via PostgreSQL UPDATE ...       │
│                │ WHERE available >= qty; returns the decision immediately  │
│                │ (200 reserved / 409 no seats). Idempotency key dedup on   │
│                │ the request protects Orders' bounded retries. Orders,     │
│                │ not Inventory, publishes inventory-reserved/order-failed  │
│                │ based on that response. Separately consumes order-failed  │
│                │ (Kafka) to release a reservation on compensation.         │
│                │ Owns own CNPG cluster (inventory-db): seats,              │
│                │ processed_requests (sync dedup), processed_events         │
│                │ (order-failed dedup). No outbox — it never publishes.     │
├────────────────┼────────────────────────────────────────────────────────────┤
│ Payments       │ POST /authorize — called synchronously by Orders' Stage 2, │
│                │ wrapped in a circuit breaker on that edge (open/half-     │
│                │ open, fallback = treat as declined). Idempotency key      │
│                │ dedup on the request protects Orders' bounded retries.    │
│                │ Internally calls the external payment gateway — its own  │
│                │ separate synchronous call with its own smaller circuit    │
│                │ breaker. Returns the decision immediately (200/402);      │
│                │ Orders publishes payment-authorized/payment-failed based  │
│                │ on that response. No Kafka involvement at all: no         │
│                │ consumer, no producer, no outbox needed.                  │
│                │ Owns own CNPG cluster (payments-db): transactions,        │
│                │ processed_requests (sync dedup).                          │
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
│                 Orders — Stage 1 (Reservation)                           │
│                              │                                           │
│                   sync HTTP  │  POST /reserve (idempotency key,          │
│                              │   timeout + bounded retry + jitter)       │
│                              ▼                                           │
│                          Inventory                                       │
│                              │                                           │
│              ┌───────────────┴────────────────┐                          │
│              ▼ 200 reserved                   ▼ 409 no seats            │
│    (Stage 1 publishes)                (Stage 1 publishes)               │
│  Kafka: inventory-reserved            Kafka: order-failed                │
│              │                        (nothing to compensate — no       │
│              │                         reservation was ever made)        │
│              ▼                                                          │
│                 Orders — Stage 2 (Payment)                               │
│                              │                                           │
│                   sync HTTP  │  POST /authorize (idempotency key,       │
│                              │   circuit breaker: open/half-open)        │
│                              ▼                                           │
│                          Payments                                        │
│                              │                                           │
│                   sync HTTP  │  (Payments' own, separate circuit         │
│                              │   breaker: open/half-open, fallback =    │
│                              │   respond 402 without calling gateway)   │
│                              ▼                                           │
│                  external payment gateway                                │
│                              │                                           │
│                              ▼                                           │
│                          Payments                                        │
│                              │  returns 200 authorized / 402 declined   │
│              ┌───────────────┴────────────────┐                          │
│              ▼ 200 authorized                 ▼ 402 declined            │
│    (Stage 2 publishes)                (Stage 2 publishes)               │
│  Kafka: payment-authorized            Kafka: payment-failed             │
│              │                                │                          │
│              ▼                                ▼                          │
│    Orders — Stage 3                  Orders — Stage 4                   │
│    (Confirmation)                    (Failure handling)                 │
│              │                                │                          │
│    publishes │ Kafka:                publishes │ Kafka: order-failed     │
│              │ order-confirmed                 │ (WITH reservation_id   │
│              ▼                                 │  this time → compensate)│
│         Notifications                          ▼                        │
│         (logs / email)              ┌──────────┴──────────┐             │
│                                      ▼                     ▼             │
│                                  Inventory            Notifications      │
│                            (releases reservation)   (failure email)     │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘

Legend:
  ───► Kafka:    = async event. Every one of these is Orders publishing to
                   itself to move between its own four stages, or to
                   Inventory (compensation) / Notifications (fire-and-
                   forget). Inventory and Payments never touch Kafka.
  ───► sync HTTP = a real, independent synchronous call, each with its own
                   timeout/retry/circuit-breaker policy: Orders→Inventory,
                   Orders→Payments, and Payments→external gateway are three
                   separate edges, not one.
  JWT            = every inbound client API call (POST /orders,
                   GET /catalog/products) carries a Bearer JWT. Validation is
                   distributed (pattern B): each service verifies the token
                   locally via spring-boot-starter-oauth2-resource-server
                   against Keycloak's JWKS endpoint — no gateway-side auth.
```

### Authentication (Keycloak)

Keycloak runs as a Pod in the `eurotransit` namespace and is the OIDC provider /
JWT issuer for the system. Authentication follows **pattern B — distributed JWT
validation**: there is no authentication step at the gateway. Instead, every
Spring Boot service validates incoming Bearer tokens locally using
`spring-boot-starter-oauth2-resource-server`, fetching Keycloak's public signing
keys from its JWKS endpoint and caching them. A token issued by Keycloak is
therefore accepted and verified independently by whichever service receives the
request, with no per-request round trip back to Keycloak.

### Kafka topics

```
Topic                                  Producer       Consumer(s)
─────────────────────────────────────  ─────────────  ──────────────────────
eurotransit.order-placed               Orders         Orders (Stage 1)
eurotransit.inventory-reserved         Orders         Orders (Stage 2)
eurotransit.payment-authorized         Orders         Orders (Stage 3)
eurotransit.payment-failed             Orders         Orders (Stage 4)
eurotransit.order-confirmed            Orders         Notifications
eurotransit.order-failed               Orders         Inventory, Notifications

Note: Orders is the sole producer of every topic. Inventory and Payments never
publish — Orders publishes the outcome after receiving their synchronous HTTP
response. Orders consuming its own order-placed/inventory-reserved/payment-
authorized/payment-failed events (via separate consumer stages) is a
deliberate pattern: it decouples the fast client-facing HTTP response from
the actual processing work, which can run on a different replica, retry
independently, and be load-shed under backpressure.
```

Every Kafka event payload includes `event_id` for deduplication and
`event_timestamp` as the UTC instant when the producer created the event payload.

### Order state machine

```
PENDING ──► RESERVED ──► CONFIRMED
   │            │
   ▼            ▼
 FAILED       FAILED (+ release reservation)
```

### Reliable event publishing (Outbox pattern)

The dual-write problem — a local DB write followed by a Kafka publish, with a pod killed in between leaving the local state saying "done" while nothing downstream ever finds out — only exists where a service does **both** a DB write and a Kafka publish for the same operation. With Inventory and Payments now reduced to pure synchronous services (no Kafka producer at all), **Orders is the only service with this problem**: every one of its four stages writes to its own DB (e.g., marking the order RESERVED) and immediately publishes the next event (e.g., `inventory-reserved`).

- Orders writes the outgoing event to its own `outbox` table in the **same local transaction** as the business write (e.g., updating the order row and inserting into `outbox` commit together, atomically, in `orders-db`).
- A polling relay — a scheduled loop inside Orders — periodically reads un-relayed `outbox` rows, publishes them to Kafka, and marks them sent.
- The relay query uses `SELECT ... FOR UPDATE SKIP LOCKED` so that if Orders is scaled to multiple replicas (HPA), two replica pollers can never grab and double-publish the same row.

Inventory and Payments don't need an outbox: Inventory's atomic reservation is a single transaction in its own database with no second system to coordinate with (it answers Orders synchronously, in the same request — nothing to lose between a commit and a publish that doesn't happen). Payments likewise never publishes anything.

This does not change the consistency model: the business decision (e.g., the reservation) is still made atomically and instantly in the same transaction as before. The outbox only affects how quickly that already-durable decision is relayed to Kafka — a pipeline-latency concern, not a correctness concern.

## 3. Frontend

A simple SPA (React, Vue, or plain HTML) served by nginx on port 80.

Pages:
- Product listing (calls GET /api/v1/catalog/products)
- Buy button (calls POST /api/v1/orders with idempotency_key)
- Order status (polls GET /api/v1/orders/{id} until CONFIRMED or FAILED)

The frontend is a thin client. No business logic, no state management beyond the current order. It authenticates users against Keycloak (OIDC) and attaches the resulting Bearer JWT to its API calls. It runs in a container with nginx, served through Traefik at path `/`.

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
│   ├── ai-logs.md
│   ├── ai-mistake-log.md
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

Important: Argo CD has cluster credentials. It NEVER builds images. The
EuroTransit Argo CD Application uses automated sync with `prune` and `selfHeal`
enabled.
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
│       ├── orders-canary-ingressroute.yaml
│       ├── orders-canary-traefikservice.yaml
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
│   │   ├── catalog-db-cluster.yaml
│   │   ├── orders-db-cluster.yaml
│   │   ├── inventory-db-cluster.yaml
│   │   └── payments-db-cluster.yaml
│   ├── observability/
│   │   ├── dashboards/
│   │   └── kube-prometheus-stack-values.yaml
│   ├── strimzi/
│   └── traefik/
├── docs/
│   └── deployment-strategies.md
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

- Real email sending — Notifications just logs
- Complex frontend — a simple page with catalog, buy button, and status polling
- API gateway software (Kong, etc.) — Traefik covers routing
- Shared database across services — Catalog, Orders, Inventory, and Payments each own a separate CloudNativePG cluster on purpose, so a DB failover or chaos experiment on one doesn't take the others down with it. No cross-service joins or shared schemas.
- Staging environment — one namespace, one cluster
