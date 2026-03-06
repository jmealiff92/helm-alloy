# CLAUDE.md — helm-alloy

## Repo overview

Multi-chart Helm monorepo for a Grafana Alloy observability stack.

```
alloy-chart/        base chart (standalone + template library)
alloy-otlp/         OTLP receiver          — depends on alloy-chart
alloy-prom/         Prometheus RW receiver  — depends on alloy-chart
alloy-discovery/    k8s service discovery   — depends on alloy-chart
alloy-gateway/      nginx entry-point       — standalone, no dependency
```

## Key architectural pattern

`alloy-chart` is both a **deployable standalone chart** and a **template library**.
Child charts (`alloy-otlp`, `alloy-prom`, `alloy-discovery`) have **no `templates/` directory**.
They declare `alloy-chart` as a Helm dependency and all Kubernetes resources (Deployment/StatefulSet, Service, ConfigMap, ServiceAccount, Role, RoleBinding) are rendered by `alloy-chart`'s templates.

Overrides in child charts live entirely under the `alloy:` key in `values.yaml`:

```yaml
# alloy-prom/values.yaml
alloy:
  workloadType: StatefulSet
  config:
    content: |-
      ...river config...
```

`alloy-gateway` is **fully independent** — its own helpers, templates, and values. It has no `alloy-chart` dependency.

## Workload types

`alloy-chart` supports two workload types, controlled by `workloadType`:

- `Deployment` (default) — stateless, `emptyDir` storage
- `StatefulSet` — stateful, with three storage modes:
  - `persistence.enabled: true` → `volumeClaimTemplate` (dynamic provisioning)
  - `persistence.existingClaim: <name>` → mount a named PVC
  - both off → `emptyDir`

`alloy-prom` and `alloy-discovery` default to `StatefulSet` + `sc-ontap-nas` (10 Gi RWO).

## Before working on child charts

Run `helm dependency update` to populate the `charts/` vendor directory:

```bash
helm dependency update ./alloy-otlp
helm dependency update ./alloy-prom
helm dependency update ./alloy-discovery
```

The `charts/` directories are gitignored — never commit them.

## Lint and render

```bash
# standalone chart and gateway
helm lint ./alloy-chart
helm lint ./alloy-gateway

# child charts (after dependency update)
helm lint ./alloy-otlp
helm lint ./alloy-prom
helm lint ./alloy-discovery

# dry-run template render
helm template test ./alloy-prom
helm template test ./alloy-discovery
```

## What lives where

| Concern | Where to edit |
|---|---|
| Alloy River config | `<child>/values.yaml` → `alloy.config.content` |
| Service ports | `<child>/values.yaml` → `alloy.service.ports` |
| Storage class / PVC size | `<child>/values.yaml` → `alloy.persistence.*` |
| Workload kind | `<child>/values.yaml` → `alloy.workloadType` |
| Deployment/StatefulSet template logic | `alloy-chart/templates/deployment.yaml` |
| Shared helper templates | `alloy-chart/templates/_helpers.tpl` |
| RBAC rules | `alloy-discovery/values.yaml` → `alloy.rbac.rules` |
| nginx routing | `alloy-gateway/values.yaml` → `nginxConfig` |
| Gateway backends | `alloy-gateway/values.yaml` → `backends.otlp` / `backends.prom` |
| Vault secret paths | `alloy-gateway/values.yaml` → `vault.*` / `vaultAnnotations` |

## Adding a new child chart

1. `mkdir alloy-<name>/`
2. Write `Chart.yaml` with a dependency on `alloy` v0.1.0 at `file://../alloy-chart`
3. Write `values.yaml` with all overrides under `alloy:` — no `templates/` directory needed
4. Add `alloy-<name>/charts/` to `.gitignore`

## Do not

- Add a `templates/` directory to child charts — all resources are rendered by `alloy-chart`
- Commit `alloy-*/charts/` directories (vendor artifacts)
- Edit `alloy-chart` templates for logic that is specific to one child chart — use values overrides instead
- Push to any branch other than `claude/alloy-helm-dependency-OEflA`
