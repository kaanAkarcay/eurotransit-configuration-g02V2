# Deployment Strategies

## Context

EuroTransit uses GitOps: application CI builds and pushes images, then updates the configuration repository. Argo CD watches the configuration repository and reconciles the cluster state from Helm manifests. CI must not hold cluster credentials.

The critical user-facing path is `POST /api/v1/orders`, backed by Orders and its synchronous calls to Inventory and Payments. Deployment strategies on this path must preserve rollback capability and make failures observable through SLOs before full promotion.

## Canary

Canary deployment gradually shifts a small percentage of traffic from the stable Orders service to a canary Orders service. The configuration repository contains a disabled-by-default TraefikService scaffold for `/api/v1/orders`.

Recommended use:

1. Deploy the canary Orders workload and service with the candidate image.
2. Enable `canary.orders.enabled`.
3. Start with a low canary weight, for example 10%.
4. Observe Orders RED metrics, checkout latency, non-5xx rate, and pending-order completion.
5. Promote by moving traffic to the candidate and updating the stable deployment, or abort by disabling the canary route.

This strategy fits EuroTransit because it limits blast radius on the money path while preserving fast rollback through Git revert.

## Blue/Green

Blue/green deployment keeps two complete versions of a workload available at the same time: the active color receives production traffic, while the inactive color is deployed and validated before the switch.

Recommended use:

1. Keep the current Orders version as the active color.
2. Deploy the candidate Orders version as the inactive color.
3. Run smoke checks and internal validation against the inactive service.
4. Switch traffic in Git by changing the route target.
5. Roll back by switching the route back to the previous color.

This strategy is useful when the team wants a binary traffic switch with immediate rollback. It costs more capacity than rolling deployment because both colors run during the transition.

## Rolling

Rolling deployment replaces pods gradually behind the same Kubernetes Service. It is simple and resource-efficient, and it is the default Kubernetes behavior when a Deployment image changes.

Rolling is acceptable for low-risk services or routine changes, but it gives less control than canary on the Orders path because old and new pods receive traffic during the rollout without an explicit SLI-based promotion gate.

## All-at-Once

All-at-once deployment replaces the running version in a single step. It has the smallest operational complexity but the largest blast radius.

This is not recommended for the Orders path because a bad release can affect all checkout traffic immediately. It may be acceptable for non-critical internal components only when rollback is well rehearsed and the change is low risk.

## Human Decisions Required

The team must still decide the exact blue/green scope before implementation:

- Whether blue/green applies only to Orders or to the whole money path.
- Naming conventions for blue and green Deployments and Services.
- Whether promotion is manual Git change, pull request approval, or an Argo CD operation.
- Which smoke checks must pass before switching traffic.

