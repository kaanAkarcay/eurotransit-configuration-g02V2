# AI Interaction Log

This file records significant AI-assisted development sessions, as required by
`docs/ai-guidelines.md` §16. Newest entries first.

---

### 2026-07-09 11:20

**Agent**

Codex — Resilience Engineering agent

**Task**

Install Chaos Mesh through the existing GitOps/configuration repository.

**Files Modified**

- platform/argocd/chaos-mesh-application.yaml
- docs/ai-logs.md

**Summary**

Added a GitOps-managed Argo CD Application for the official Chaos Mesh Helm
chart. The configuration installs Chaos Mesh into the `chaos-mesh` namespace,
uses AKS/containerd runtime settings, keeps the dashboard internal, and supports
the documented `PodChaos` and `NetworkChaos` experiment hypotheses.

**Potential Risks**

- Live installation depends on the Argo CD instance being able to reach
  `https://charts.chaos-mesh.org` and `ghcr.io`.
- `ServerSideApply=true` is used to reduce CRD apply issues; this assumes the
  deployed Argo CD version supports that sync option.
- The team should converge on one log filename convention:
  `docs/ai-guidelines.md` uses `docs/ai-logs.md`, while `docs/dod.md` mentions
  `docs/agent-log.md`.

**Confidence**

Medium

**Notes**

This change installs the Chaos Mesh platform prerequisite only. It does not
define or run any chaos experiments. During implementation, Codex initially
mistook `docs/ai-logs.md` as missing because it had inspected an older branch;
after switching to `origin/dev`, the file existed. The overwrite was detected
with `git diff`/`git show HEAD:docs/ai-logs.md` and corrected.

---

### 2026-07-08 20:07

**Agent**

Claude (Opus 4.8) via Claude Code

**Task**

Update the Architecture Design and Definition of Done to reflect two approved
architectural decisions: (1) Catalog now owns a CloudNativePG database
(database-per-service), and (2) Keycloak is introduced for authentication
(pattern B — distributed JWT validation).

**Files Modified**

- docs/architecture-design.md
- docs/dod.md
- docs/ai-logs.md (created)

**Summary**

- Catalog DB: system overview updated from 3 to 4 CNPG clusters (added
  catalog-db); the "own CNPG cluster" bullet and the service table row for
  Catalog now state it owns catalog-db (removed "No DB"); config-repo structure
  gained platform/cnpg/catalog-db-cluster.yaml; the "Shared database" item under
  "What is NOT needed" now lists Catalog.
- Keycloak: removed "Authentication / JWT / OAuth" from "What is NOT needed";
  added Keycloak to the Platform components in the system overview; added a JWT
  entry to the communication-diagram legend and a new "Authentication
  (Keycloak)" subsection describing pattern B (each service validates Bearer
  tokens locally via spring-boot-starter-oauth2-resource-server against
  Keycloak's JWKS endpoint, no gateway-side auth).
- Frontend description updated: it now authenticates against Keycloak and
  attaches the Bearer JWT (previously "no auth").
- DoD: added an "Authentication (Keycloak)" section with four acceptance
  criteria; refreshed the "Last updated" date.

**Potential Risks**

- Documentation-only change. The real config-repo manifests do not yet exist:
  platform/cnpg/catalog-db-cluster.yaml, the Keycloak Deployment/Service, and
  the CNPG wiring for Catalog still need to be created and reconciled by Argo CD.
- The eurotransit-contract.md was intentionally left unchanged (it carries no DB
  topology, "What is NOT needed" section, or auth references); if API-level auth
  semantics (e.g. 401 responses) should be codified in the contract, that is a
  follow-up.
- Naming inconsistency across project docs: ai-guidelines.md §16 refers to
  docs/ai-logs.md (created here), while dod.md and the app-repo structure refer
  to docs/agent-log.md. Team should converge on one name.

**Confidence**

High — edits faithfully implement the human-approved decisions; ASCII-box
alignment was verified by character count.

**Notes**

Changes were explicitly approved by the human developer before implementation,
per ai-guidelines.md §5 and §19. Scope was kept to the two architecture
documents plus this log, with follow-up items surfaced rather than actioned.
