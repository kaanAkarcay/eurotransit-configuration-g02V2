# EuroTransit probe resilience review

Date: 2026-07-15

This review covers the DoD requirement "Liveness probes do NOT check downstream
dependencies" and the paired requirement "Readiness probes reflect actual
ability to serve traffic." It separates repository evidence from live-cluster
proof.

## Resilience invariant

A downstream or infrastructure dependency failure must not be misclassified as
application process death.

For EuroTransit, liveness is allowed to answer only the question "is this process
alive enough for Kubernetes to keep it running?" Readiness is allowed to answer
"should this pod receive traffic right now?"

## Documentation baseline

Relevant project sources:

- `docs/dod.md`: explicitly requires liveness probes to ignore downstream
  dependencies and readiness to reflect serving ability.
- `docs/resilience/runtime-resilience-config.md`: records the same liveness
  invariant and recommends less aggressive probe timeout settings as a follow-up.
- `docs/deployment-strategies.md`: progressive Rollouts copy the pod template
  from the Deployment, so the Deployment remains the single source for probes.
- `docs/chaos-experiment-hypotheses.md`: chaos validation expects critical pods
  not to restart from liveness churn while dependencies are disrupted.

## Current repository evidence

The Helm chart points backend probes at Spring Boot Actuator probe groups:

| Service | Actuator dependency | Probe groups enabled | Helm liveness | Helm readiness | Probe port | Auth blocks health? | Liveness dependency scope | Readiness dependency scope |
|---|---|---|---|---|---|---|---|---|
| Orders | Yes | Yes | `/actuator/health/liveness` | `/actuator/health/readiness` | named port `http` -> 8080 | No; `/actuator/**` is `permitAll` | No custom liveness group and no custom health indicator found; downstream clients are not added to liveness. | Default readiness group only; no custom DB/Kafka/downstream group include found. |
| Payments | Yes | Yes | `/actuator/health/liveness` | `/actuator/health/readiness` | named port `http` -> 8080 | No; `/actuator/**` is `permitAll` | No custom liveness group and no custom health indicator found; gateway client is not added to liveness. | Default readiness group only; `management.health.circuitbreakers.enabled=true` exposes circuit-breaker health, but no readiness group includes it. |
| Inventory | Yes | Yes | `/actuator/health/liveness` | `/actuator/health/readiness` | named port `http` -> 8080 | No; `/actuator/**` is `permitAll` | No custom liveness group and no custom health indicator found; DB/Kafka/auth dependencies are not added to liveness. | Default readiness group only; no custom DB/Kafka/auth group include found. |
| Notifications | Yes | Yes | `/actuator/health/liveness` | `/actuator/health/readiness` | named port `http` -> 8080 | No security configuration found; health is public. | No custom liveness group and no custom health indicator found; Kafka is not added to liveness. | Default readiness group only; no custom Kafka group include found. |
| Catalog | Yes | Yes | `/actuator/health/liveness` | `/actuator/health/readiness` | named port `http` -> 8080 | No security configuration found; health is public. | No custom liveness group and no custom health indicator found; DB is not added to liveness. | Default readiness group only; no custom DB group include found. |
| Payment gateway simulator | Yes | Yes | `/actuator/health/liveness` | `/actuator/health/readiness` | named port `http` -> 8080 | No security configuration found; health is public. | No custom liveness group and no custom health indicator found; Stripe/local gateway mode is not added to liveness. | Default readiness group only; no custom gateway group include found. |

The application repository currently includes `spring-boot-starter-actuator` and
`management.endpoint.health.probes.enabled: true` for all six backend services
above.

No inspected application configuration defines
`management.endpoint.health.group.liveness` or
`management.endpoint.health.group.readiness`, and no custom
`HealthIndicator`/`ReactiveHealthIndicator` was found in these modules. The
static repository configuration is therefore aligned with the intended liveness
boundary: downstream dependencies are not deliberately attached to liveness.

## Live-cluster evidence collected

Read-only cluster checks on 2026-07-15 showed:

```text
kubectl get deploy -n eurotransit
eurotransit-catalog         1/1
eurotransit-frontend        1/1
eurotransit-inventory       1/1
eurotransit-notifications   1/1
eurotransit-orders          1/1
eurotransit-payments        1/1
payment-gateway-sim         1/1
```

The deployed backend probe paths matched the Helm chart:

```text
eurotransit-catalog         /actuator/health/liveness   /actuator/health/readiness   /actuator/health/liveness
eurotransit-inventory       /actuator/health/liveness   /actuator/health/readiness   /actuator/health/liveness
eurotransit-notifications   /actuator/health/liveness   /actuator/health/readiness   /actuator/health/liveness
eurotransit-orders          /actuator/health/liveness   /actuator/health/readiness   /actuator/health/liveness
eurotransit-payments        /actuator/health/liveness   /actuator/health/readiness   /actuator/health/liveness
payment-gateway-sim         /actuator/health/liveness   /actuator/health/readiness   /actuator/health/liveness
```

This proves the live Deployments are using the intended paths. It does not prove
downstream-failure behavior by itself.

Port-forward checks against the live Services returned `200 {"status":"UP"}` for
both `/actuator/health/liveness` and `/actuator/health/readiness` on Catalog,
Inventory, Notifications, Orders, Payments, and the payment gateway simulator.
Those requests were made without bearer tokens, confirming that authentication
does not block the probe endpoints.

## Runtime verification plan

The task "Verify liveness probes ignore downstream failures" is not complete
until at least one controlled dependency failure has been observed in the running
environment.

Recommended scenarios:

1. Orders -> Inventory unavailable.
2. Orders -> Payments unavailable.
3. Payments -> payment gateway simulator unavailable.
4. Kafka temporarily unavailable for Kafka-dependent services.
5. A service's own database temporarily unavailable or failing over.

For each scenario:

```bash
kubectl -n eurotransit get pods -w
kubectl -n eurotransit get deploy
kubectl -n eurotransit describe pod <pod>
kubectl -n eurotransit logs <pod> --since=10m
```

Monitor:

```promql
sum by (pod) (increase(kube_pod_container_status_restarts_total{
  namespace="eurotransit",
  pod=~"eurotransit-(orders|inventory|payments|catalog|notifications).*"
}[10m]))

sum by (pod) (kube_pod_status_ready{
  namespace="eurotransit",
  condition="true",
  pod=~"eurotransit-(orders|inventory|payments|catalog|notifications).*"
})

sum(rate(http_server_requests_seconds_count{
  namespace="eurotransit",
  uri=~"/actuator/health/(liveness|readiness)"
}[2m]))
```

Success criteria:

- affected service liveness stays healthy;
- pod restart count does not increase because of liveness failures;
- readiness is allowed to transition if the service cannot safely serve traffic;
- service recovers without manual pod restart after the dependency returns;
- business-facing failures are handled by the appropriate resilience mechanism
  rather than by Kubernetes restart churn.

## Remaining blocker

Repository evidence is now sufficient for a static review, but live downstream
failure behavior remains unverified. Running the verification scenarios requires
a controlled non-read-only action, such as a suspended Chaos Mesh experiment,
temporarily removing a dependency endpoint, or another approved failure-injection
method.

Do not mark this DoD item complete until the runtime evidence above has been
captured.
