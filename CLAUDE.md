# CLAUDE.md — helm-alloy

This file provides context for AI assistants working in this repository.

---

## Repository Overview

`helm-alloy` is a Helm charts repository containing two standalone Kubernetes deployment charts:

1. **alloy-chart** — Deploys [Grafana Alloy](https://grafana.com/docs/alloy/) (v1.7.0), a vendor-neutral telemetry collector that receives OTLP signals and forwards them to an OpenTelemetry collector.
2. **nginx-chart** — Deploys an nginx (v1.26) reverse proxy that sits in front of Alloy, providing TLS termination (via HashiCorp Vault-injected certificates), basic authentication, and an OpenShift Route for ingress.

There is no source code to compile. This is a pure configuration/infrastructure repository—all artifacts are Helm templates and YAML values files.

---

## Repository Structure

```
helm-alloy/
├── CLAUDE.md                   # This file
├── alloy-chart/                # Grafana Alloy Helm chart
│   ├── Chart.yaml              # Chart metadata (name, version, appVersion)
│   ├── values.yaml             # Default values (image, resources, config, ports)
│   └── templates/
│       ├── _helpers.tpl        # Named template helpers (naming, labels)
│       ├── configmap.yaml      # Alloy River-language config
│       ├── deployment.yaml     # Pod spec, volumes, health checks, env vars
│       └── service.yaml        # ClusterIP service (ports 12345, 4317, 4318)
└── nginx-chart/                # nginx reverse proxy Helm chart
    ├── Chart.yaml              # Chart metadata (name, version, appVersion)
    ├── values.yaml             # Default values (image, resources, TLS, routes)
    └── templates/
        ├── _helpers.tpl        # Named template helpers
        ├── configmap.yaml      # nginx.conf with TLS, auth, proxy rules
        ├── deployment.yaml     # Pod spec, Vault annotations, volumes
        ├── route.yaml          # OpenShift Route resource
        └── service.yaml        # ClusterIP service (HTTPS port 443)
```

> **Note:** `alloy-chart/alloy-chart/` is a nested duplicate of the chart — treat the top-level `alloy-chart/` as the canonical chart.

---

## Chart Details

### alloy-chart

| Property | Value |
|---|---|
| Chart version | 0.1.0 |
| App version | 1.7.0 |
| Image | `grafana/alloy:v1.7.0` |
| Replica count | 1 |

**Key design decisions:**
- **Standalone** — no upstream Helm chart dependencies; all templates are hand-authored.
- **River config via ConfigMap** — Alloy's configuration (River language) is stored in a ConfigMap and mounted read-only. A checksum annotation on the Deployment triggers rolling restarts when the config changes.
- **Security hardened** — runs as UID 473 (non-root), read-only root filesystem, all Linux capabilities dropped.
- **EmptyDir volumes** — WAL and internal Alloy state use emptyDir (ephemeral, survives restarts but not pod eviction).
- **Go runtime tuning** — `GOMAXPROCS`, `GOMEMLIMIT`, and `GOGC` are set via environment variables to optimise the Go runtime inside Kubernetes.
- **Health checks** — readiness on `/-/ready`, liveness on `/-/healthy` (port 12345).

**Exposed ports:**

| Name | Port | Protocol | Purpose |
|---|---|---|---|
| alloy-ui | 12345 | TCP | Alloy web UI / debug |
| otlp-grpc | 4317 | TCP | OTLP gRPC receiver |
| otlp-http | 4318 | TCP | OTLP HTTP receiver |

**Default River config** (in `values.yaml`):
- Receives OTLP over gRPC (`:4317`) and HTTP (`:4318`)
- Exports to `http://otel-collector:4317` via OTLP exporter

### nginx-chart

| Property | Value |
|---|---|
| Chart version | 0.1.0 |
| App version | 1.26.0 |
| Image | `nginx:1.26-alpine` |
| Replica count | 1 |

**Key design decisions:**
- **TLS via HashiCorp Vault** — Vault Agent Injector annotations mount TLS certificates and an htpasswd file at runtime. No secrets are stored in the chart.
- **OpenShift Route** — a `route.yaml` template creates an OpenShift Route resource (hostname: `o11y-collector.dyn.net`).
- **EmptyDir volumes** — three emptyDir volumes handle nginx's pid file, cache, and temporary files (required for read-only root FS).
- **Proxy rules** — `/otlp/` proxied to Alloy OTLP HTTP (port 4318), `/debug/` proxied to Alloy UI (port 12345) with WebSocket upgrade support.
- **Health endpoint** — `/healthz` returns 200 without authentication, used for readiness/liveness probes.

---

## Development Conventions

### Helm templating

- **Helpers** — all reusable named templates live in `_helpers.tpl`. Use `{{ include "chart.name" . }}` (not `{{ template }}`).
- **Labels** — standard Kubernetes labels (`app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/version`, `app.kubernetes.io/managed-by`) must be present on all resources.
- **`checksum/config` annotation** — the Deployment in `alloy-chart` includes `checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}` to force rolling updates on ConfigMap changes. Preserve this pattern.
- **Values structure** — follow the existing `values.yaml` hierarchy when adding new configurable parameters. Group related settings under a common key (e.g., `service`, `resources`, `securityContext`).

### Security requirements

Both charts enforce a strict security posture. When modifying templates, preserve:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: <uid>
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
```

Do **not** relax these constraints without explicit justification.

### Secrets management

- Secrets (TLS certs, htpasswd) are **never** stored in the chart or values files.
- All secrets are injected at runtime via HashiCorp Vault Agent Injector annotations on the nginx Deployment pod spec.
- If adding new secrets, follow the existing Vault annotation pattern in `nginx-chart/templates/deployment.yaml`.

### Resource limits

Always specify both `requests` and `limits` for CPU and memory. Current defaults:

| Chart | CPU request | CPU limit | Memory request | Memory limit |
|---|---|---|---|---|
| alloy | 100m | 500m | 128Mi | 512Mi |
| nginx | 50m | 200m | 64Mi | 128Mi |

---

## Working with the Charts

### Prerequisites

- [Helm 3](https://helm.sh/docs/intro/install/) (`helm version`)
- Access to a Kubernetes cluster (or OpenShift cluster for route resources)
- HashiCorp Vault configured with the Vault Agent Injector (for nginx TLS/auth)

### Linting

Always lint before committing chart changes:

```bash
helm lint alloy-chart/
helm lint nginx-chart/
```

### Rendering templates locally

Render templates without a cluster to inspect generated YAML:

```bash
# Alloy chart
helm template my-alloy alloy-chart/ --values alloy-chart/values.yaml

# nginx chart
helm template my-nginx nginx-chart/ --values nginx-chart/values.yaml
```

### Installing / upgrading

```bash
# Install
helm install alloy alloy-chart/ -n <namespace>
helm install nginx nginx-chart/ -n <namespace>

# Upgrade
helm upgrade alloy alloy-chart/ -n <namespace>
helm upgrade nginx nginx-chart/ -n <namespace>

# Dry-run
helm upgrade --install alloy alloy-chart/ -n <namespace> --dry-run
```

### Overriding values

Supply a custom values file for environment-specific configuration:

```bash
helm upgrade --install alloy alloy-chart/ \
  -n <namespace> \
  --values alloy-chart/values.yaml \
  --values my-env-overrides.yaml
```

---

## Common Tasks

### Updating the Alloy River configuration

Edit the `alloyConfig` block in `alloy-chart/values.yaml`. The River-language config is injected into the ConfigMap via the `configmap.yaml` template. The Deployment's `checksum/config` annotation will cause a rolling restart automatically on the next `helm upgrade`.

### Changing the Alloy image version

Update `image.tag` in `alloy-chart/values.yaml` and bump `appVersion` in `alloy-chart/Chart.yaml` to match.

### Changing the nginx image version

Update `image.tag` in `nginx-chart/values.yaml` and bump `appVersion` in `nginx-chart/Chart.yaml` to match.

### Updating the OpenShift Route hostname

Edit `route.host` in `nginx-chart/values.yaml`.

### Modifying nginx proxy rules

Edit the nginx config template in `nginx-chart/values.yaml` (under the `nginxConfig` or equivalent key) or directly in `nginx-chart/templates/configmap.yaml`.

---

## What Does Not Exist (Yet)

The following are **not present** in this repository — do not assume they exist:

- No `README.md` at the repository root
- No CI/CD pipelines (no `.github/workflows/`, no `.gitlab-ci.yml`, etc.)
- No automated tests (no `ct.yaml`, no chart-testing, no helm unittest)
- No `CHANGELOG.md` or release automation
- No `helmfile.yaml` or umbrella chart
- No container image builds (this is charts-only)

---

## Branch and Commit Conventions

- Default development branch for AI-assisted work: `claude/add-claude-documentation-R9Sam`
- The upstream default branch is `main` (remote) / `master` (local alias)
- Write clear, descriptive commit messages that reference what changed (e.g., `alloy-chart: bump image to v1.8.0`)
