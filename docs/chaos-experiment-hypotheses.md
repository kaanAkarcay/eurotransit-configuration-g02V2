# EuroTransit — Chaos Experiment Hypotheses

These hypotheses are formulated before the experiments are executed. Each will be validated or invalidated during Phase 4, and a full report will be written for each.

---

## Experiment 1: Latency injection on Payments

**Failure mode:** Payments service responds with 3-second delay on all requests.

**Chaos Mesh resource:** NetworkChaos (delay) targeting pods with label `app.kubernetes.io/name: payments`.

**Hypothesis:** When Payments latency exceeds the configured timeout (2s), the circuit breaker on Orders opens within 10 seconds. Orders stops calling Payments and immediately publishes `order-failed` events for new orders. Inventory receives `order-failed` and releases any pending reservations (compensation). Catalog remains completely unaffected because it has no dependency on Payments or Orders. The latency SLO (p99 < 800ms) will be violated for Orders but not for Catalog. The circuit breaker dashboard panel shows the transition from CLOSED → OPEN.

**Steady state:** All SLOs green. Success rate > 99.5%. p99 latency < 800ms. No active alerts. Orders in PENDING reach CONFIRMED within 5 seconds.

**What we will observe:**
- Grafana: Orders error rate increases, then stabilizes when circuit breaker opens
- Grafana: Catalog metrics remain unchanged
- Grafana: circuit breaker state transitions
- Alertmanager: burn-rate alert fires for Orders checkout SLO

**Validation criteria:** Circuit breaker opens. No requests hang longer than timeout (2s). Catalog is unaffected. Compensation releases all reservations for failed orders.

---

## Experiment 2: Pod kill on Inventory mid-reservation

**Failure mode:** Inventory pod is killed (SIGKILL) while handling a synchronous `POST /reserve` call from Orders' Stage 1, mid-way through executing the atomic reservation SQL.

**Chaos Mesh resource:** PodChaos (pod-kill) targeting pods with label `app.kubernetes.io/name: inventory`, triggered during active load.

**Hypothesis:** Orders' `POST /reserve` call times out or gets a connection error when the pod dies. Orders' bounded retry-with-backoff-and-jitter re-sends the same request (same `idempotency_key` = `order_id`), landing on the ReplicaSet's replacement pod (or another existing replica). Because the reservation UPDATE and the `processed_requests` insert happen in the same database transaction, one of two things happened on the killed pod: either the transaction committed (seat reserved, idempotency key recorded) — in which case the retry hits the idempotency check and returns the existing `reservation_id` without reserving again — or the transaction rolled back (no reservation) — in which case the retry reserves normally. In neither case does a double-reservation occur. The "never oversell" invariant holds.

**Steady state:** Inventory available seats equal to expected count. No duplicate reservations in the database. All orders eventually reach a terminal state (CONFIRMED or FAILED).

**What we will observe:**
- Grafana: Inventory pod restart counter increases
- Grafana: brief spike in Orders' Stage 1 call latency (connection retry + failover to a healthy replica)
- Database query: SELECT count(*) FROM seats WHERE train_id = X confirms no oversell
- Database query: SELECT count(*) FROM processed_requests confirms no duplicate reservation for the same order_id

**Validation criteria:** Zero oversold seats. Every order reaches a terminal state. No duplicate entries in processed_requests for the same order_id.

---

## Experiment 3: Node / AZ-style disruption

**Failure mode:** One cluster node is cordoned and drained, simulating an availability zone failure.

**Chaos Mesh resource:** Not Chaos Mesh — executed manually via `kubectl cordon` + `kubectl drain` on a node, or via Azure AKS node pool operations.

**Hypothesis:** PodDisruptionBudgets (minAvailable >= 1) prevent all pods of a critical service from being evicted simultaneously. The Kubernetes scheduler reschedules evicted pods on the remaining node(s). During the transition, at least one replica of each critical-path service (Orders, Inventory, Payments) remains running. The checkout flow continues to work, possibly with briefly elevated latency due to pod rescheduling. Non-critical services (Notifications) may experience brief downtime without impacting checkout (graceful degradation).

**Steady state:** All services reachable. Checkout success rate > 99.5%. No pending orders stuck without resolution.

**What we will observe:**
- Grafana: pod count temporarily drops for affected services, then recovers
- Grafana: latency spike during rescheduling
- Grafana: success rate may briefly dip but recovers within 30 seconds
- kubectl: pods rescheduled on remaining nodes

**Validation criteria:** Checkout flow never fully down. PDB prevents simultaneous eviction of all replicas. Recovery within 60 seconds. No data loss.

---

## Experiment 4: Kafka disruption / network partition

**Failure mode:** Network partition between application pods and Kafka broker pods, simulating Kafka becoming temporarily unreachable for 60 seconds.

**Chaos Mesh resource:** NetworkChaos (partition) targeting traffic between namespace `eurotransit` and Kafka broker pods (Strimzi namespace).

**Hypothesis:** `POST /orders` always returns `202` immediately, partition or not — the `order-placed` event is written to Orders' own outbox table in the same transaction as saving PENDING, and Kafka is never called synchronously in the request path (see the outbox pattern, contract §3.3). During the partition, Orders' outbox poller's publish attempts fail and retry; unrelayed rows accumulate in the outbox rather than being lost. Any order already past Stage 1 (e.g. sitting RESERVED, waiting for its own `payment-authorized`/`payment-failed` self-consumption) also stalls, since Stages 2-4 are Kafka round trips too — but nothing is lost, it's just delayed. When the partition heals, the poller drains the backlog and all stalled stages resume. All PENDING/RESERVED orders eventually reach a terminal state. No events are duplicated (outbox rows are marked sent exactly once via `SELECT ... FOR UPDATE SKIP LOCKED`, plus consumer-side `processed_events` deduplication on Orders' own stage consumers). The pipeline converges to a consistent state.

**Steady state:** All PENDING orders reach CONFIRMED or FAILED within 30 seconds. No orphaned PENDING orders. Event count in Kafka matches order count.

**What we will observe:**
- Grafana: order-placed event rate drops to zero during partition
- Grafana: PENDING order count accumulates
- Grafana: after partition heals, event rate spikes as buffered events are delivered
- Grafana: PENDING orders drain to terminal states
- Database: no duplicate processed_events entries

**Validation criteria:** Zero events lost. Zero duplicate processing. All PENDING orders reach terminal state within 60 seconds of partition healing. No manual intervention required.

---

## Experiment 5: CloudNativePG primary failover

**Failure mode:** The PostgreSQL primary pod is deleted, forcing CloudNativePG to promote a standby to primary.

**Chaos Mesh resource:** PodChaos (pod-kill) targeting the pod with role `primary` in the CloudNativePG cluster, or manually via `kubectl delete pod`.

**Hypothesis:** CloudNativePG detects the primary failure and promotes a standby replica within 10-15 seconds. During failover, services that depend on PostgreSQL (Orders, Inventory, Payments) experience connection errors. The circuit breaker on Orders → Payments may open if Payments cannot reach the database. Orders that were mid-processing may fail and need to be retried by the Kafka consumer (deduplicated via processed_events). After failover completes, the `eurotransit-cluster-rw` service DNS automatically points to the new primary. Services reconnect without restart. Checkout recovers within the stated RTO. No committed data is lost (RPO = 0 for synchronous replication).

**Steady state:** Checkout success rate > 99.5%. p99 latency < 800ms. Database is writable and readable.

**What we will observe:**
- Grafana: database connection error rate spikes for 10-15 seconds
- Grafana: checkout success rate drops temporarily
- Grafana: recovery visible as success rate returns to baseline
- kubectl: CloudNativePG Cluster status shows new primary elected
- kubectl: old primary pod restarted as standby

**Validation criteria:** Failover completes within 30 seconds. No committed transactions lost. Checkout recovers without manual intervention. No stuck PENDING orders after recovery.

---

## Additional targeted experiment: Orders -> Inventory network partition

**Failure mode:** Orders pods temporarily cannot send traffic to Inventory pods because packets are dropped by a Chaos Mesh network partition.

**Chaos Mesh resource:** Suspended `NetworkChaos` Schedule in `platform/chaos-mesh/experiments/orders-inventory-network-failure-schedule.yaml`, partitioning traffic from pods with `app.kubernetes.io/name: orders` to pods with `app.kubernetes.io/name: inventory`.

**Hypothesis:** After the committed Orders image enforces an Inventory timeout, a controlled network partition causes the `inventory-client` circuit breaker to record failures and open after the configured sample size and failure-rate threshold are reached. This experiment must not be used as proof of timeout behavior or threshold tuning while the committed Orders source lacks `@TimeLimiter`, WebClient response timeout, or an equivalent timeout.

**Steady state:** Orders, Inventory, Payments, Kafka, and PostgreSQL are healthy. Checkout load is stable and high enough to produce at least `minimum-number-of-calls` for `inventory-client` inside the circuit-breaker sliding window. No active chaos objects exist before the run.

**What we will observe:**
- Grafana/Prometheus: `inventory-client` call count exceeds `minimum-number-of-calls` during the fault window
- Grafana/Prometheus: after timeout enforcement exists, `inventory-client` failure rate rises and the circuit breaker transitions CLOSED -> OPEN
- Grafana/Prometheus: not-permitted calls appear while the breaker is OPEN
- Kubernetes: Orders and Inventory pod restart counters do not increase from liveness churn
- Database/business checks: affected orders either reach terminal state or are explicitly accounted for

**Validation criteria:** `inventory-client` transitions CLOSED -> OPEN under confirmed Inventory unavailability only after Orders timeout enforcement exists. If the breaker does not open under a full partition, first diagnose missing timeout, hanging calls, missing samples, or missing Resilience4j wrapping; do not treat that as a reason to lower `failure-rate-threshold`.

Detailed runbook: `docs/resilience/orders-inventory-circuit-breaker-chaos.md`.
