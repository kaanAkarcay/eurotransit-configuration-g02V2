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

**Failure mode:** Inventory pod is killed (SIGKILL) while processing an `order-placed` event and executing the atomic reservation SQL.

**Chaos Mesh resource:** PodChaos (pod-kill) targeting pods with label `app.kubernetes.io/name: inventory`, triggered during active load.

**Hypothesis:** The killed pod is restarted by the ReplicaSet controller. The Kafka consumer group rebalances and the unacknowledged `order-placed` event is re-delivered to the new pod. Because the reservation and the `processed_events` insert happen in the same database transaction, one of two things happened: either the transaction committed (seat reserved, event_id recorded) and the re-delivery is deduplicated, or the transaction rolled back (no reservation) and the re-delivery processes normally. In neither case does a double-reservation occur. The "never oversell" invariant holds.

**Steady state:** Inventory available seats equal to expected count. No duplicate reservations in the database. All orders eventually reach a terminal state (CONFIRMED or FAILED).

**What we will observe:**
- Grafana: Inventory pod restart counter increases
- Grafana: brief spike in order processing latency (consumer rebalance takes a few seconds)
- Database query: SELECT count(*) FROM seats WHERE train_id = X confirms no oversell
- Database query: SELECT count(*) FROM processed_events confirms no duplicate processing

**Validation criteria:** Zero oversold seats. Every order reaches a terminal state. No duplicate entries in processed_events for the same event_id.

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

**Hypothesis:** During the partition, Orders cannot publish `order-placed` events. POST /orders either returns 500 (if the publish is in the request path) or successfully saves PENDING but the event is buffered by the Kafka producer and not delivered. No events are lost because Kafka producers retry with idempotent delivery enabled. When the partition heals, buffered events are delivered. Consumers resume processing. All PENDING orders eventually reach a terminal state. No events are duplicated (Kafka idempotent producer + consumer-side processed_events deduplication). The pipeline converges to a consistent state.

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