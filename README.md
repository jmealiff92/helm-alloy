# helm-alloy

Helm monorepo for a [Grafana Alloy](https://grafana.com/docs/alloy/latest/) observability stack on Kubernetes / OpenShift.

## Repository structure

```
helm-alloy/
├── alloy-chart/        # Base chart — standalone deployable + shared template library
├── alloy-otlp/         # Alloy as an OTLP receiver        (depends on alloy-chart)
├── alloy-prom/         # Alloy as a Prometheus RW receiver (depends on alloy-chart)
├── alloy-discovery/    # Alloy for k8s service discovery   (depends on alloy-chart)
└── alloy-gateway/      # nginx reverse proxy entry-point   (standalone, no dependency)
```

## Architecture

```
                        ┌─────────────────────┐
  external clients      │    alloy-gateway     │
  ──────────────────►   │  nginx :443 (TLS)    │
                        │  OpenShift Route     │
                        └──────────┬──────────┘
                                   │  path-based routing
                    ┌──────────────┼──────────────┐
                    │              │              │
             /otlp/*│   /prom/…/push│        (future)
                    ▼              ▼
           ┌────────────┐  ┌─────────────┐
           │ alloy-otlp │  │  alloy-prom │
           │ :4317/:4318│  │    :9009    │
           │ Deployment │  │ StatefulSet │
           └────────────┘  └─────────────┘

           ┌──────────────────┐
           │  alloy-discovery │   scrapes pods/services in-namespace
           │    StatefulSet   │──────────────────────────────────────►
           └──────────────────┘
```

## Charts

### `alloy-chart` — base library

Grafana Alloy v1.7.0. Serves two roles simultaneously:

- **Standalone**: `helm install my-alloy ./alloy-chart` deploys a Deployment + Service + optional OpenShift Route directly.
- **Library**: `alloy-otlp`, `alloy-prom`, and `alloy-discovery` declare it as a Helm dependency. The child chart sets overrides under the `alloy:` key and all Kubernetes resources are rendered by this chart.

Child charts have no `templates/` directory of their own — only `Chart.yaml` and `values.yaml`.

Key values:

| Value | Default | Description |
|---|---|---|
| `workloadType` | `Deployment` | `Deployment` or `StatefulSet` |
| `config.content` | OTLP passthrough | Alloy River config rendered into a ConfigMap |
| `service.ports` | UI + OTLP gRPC + OTLP HTTP | Ports exposed on the ClusterIP Service |
| `serviceAccountName` | `""` | Creates a ServiceAccount when set |
| `rbac.enabled` | `false` | Creates Role + RoleBinding for the ServiceAccount |
| `rbac.rules` | `[]` | RBAC policy rules |
| `route.enabled` | `false` | Render an OpenShift Route |
| `persistence.*` | see below | Persistent storage (StatefulSet only) |

#### Persistent storage (`workloadType: StatefulSet`)

Three modes — select exactly one:

| Mode | Config | Behaviour |
|---|---|---|
| Dynamic PVC | `persistence.enabled: true` | `volumeClaimTemplate` created by the StatefulSet |
| Existing PVC | `persistence.existingClaim: <name>` | Named PVC mounted directly as a volume |
| Ephemeral | `persistence.enabled: false` (default) | `emptyDir` — data lost on pod restart |

```yaml
# Dynamic PVC from NetApp ONTAP NAS StorageClass
persistence:
  enabled: true
  storageClass: sc-ontap-nas   # "" = cluster default
  accessMode: ReadWriteOnce
  size: 10Gi
```

---

### `alloy-otlp`

Receives OpenTelemetry traces, metrics, and logs via OTLP (gRPC :4317, HTTP :4318) and forwards them to a downstream collector.

- Workload: **Deployment** (stateless receiver)
- Runs as an `alloy-chart` dependency — overrides `alloy.config.content` and `alloy.service.ports`
- Gateway routes `/otlp/*` → this service on port 4318

Override the upstream exporter endpoint:

```yaml
# alloy-otlp/values.yaml
alloy:
  config:
    content: |-
      otelcol.receiver.otlp "default" {
        grpc { endpoint = "0.0.0.0:4317" }
        http { endpoint = "0.0.0.0:4318" }
        output {
          traces  = [otelcol.exporter.otlp.default.input]
          metrics = [otelcol.exporter.otlp.default.input]
          logs    = [otelcol.exporter.otlp.default.input]
        }
      }
      otelcol.exporter.otlp "default" {
        client {
          endpoint = "http://my-otel-collector:4317"
          tls { insecure = true }
        }
      }
```

---

### `alloy-prom`

Receives Prometheus remote write on HTTP :9009 and forwards to a Prometheus-compatible backend.

- Workload: **StatefulSet** with persistent storage (WAL survives restarts)
- Runs as an `alloy-chart` dependency — overrides `alloy.config.content`, `alloy.service.ports`, `alloy.workloadType`, and `alloy.persistence`
- Gateway routes `/prometheus/api/v1/push` → this service on port 9009, rewriting the path to `/api/v1/write`
- Default PVC: `sc-ontap-nas`, 10 Gi, RWO

Override the remote write endpoint:

```yaml
# alloy-prom/values.yaml
alloy:
  config:
    content: |-
      prometheus.receive_http "default" {
        http { listen_address = "0.0.0.0"  listen_port = 9009 }
        output { metrics = [prometheus.remote_write.default.receiver] }
      }
      prometheus.remote_write "default" {
        endpoint { url = "http://mimir:9009/api/v1/push" }
      }
```

---

### `alloy-discovery`

Runs in-namespace Kubernetes service discovery, scrapes pods and services, and remote-writes metrics to a Prometheus-compatible backend.

- Workload: **StatefulSet** with persistent storage (scrape state and WAL)
- Dedicated ServiceAccount `alloy-discovery` with a namespace-scoped Role granting read access to pods, services, endpoints, deployments, and ingresses
- Runs as an `alloy-chart` dependency — overrides `alloy.config.content`, `alloy.serviceAccountName`, `alloy.rbac`, `alloy.workloadType`, and `alloy.persistence`
- Default PVC: `sc-ontap-nas`, 10 Gi, RWO

For cluster-wide scraping, replace the namespace Role with a ClusterRole externally and set `alloy.rbac.enabled: false`.

Override the remote write endpoint:

```yaml
# alloy-discovery/values.yaml
alloy:
  config:
    content: |-
      discovery.kubernetes "pods" { role = "pod" }
      prometheus.scrape "kubernetes" {
        targets         = discovery.kubernetes.pods.targets
        scrape_interval = "30s"
        forward_to      = [prometheus.remote_write.default.receiver]
      }
      prometheus.remote_write "default" {
        endpoint { url = "http://mimir:9009/api/v1/push" }
      }
```

---

### `alloy-gateway`

Standalone nginx (:443 TLS) reverse proxy. Completely independent of `alloy-chart` — its own helpers, templates, and values.

- TLS cert, key, and htpasswd are injected at runtime by the **Vault Agent Injector**
- Exposed externally via an OpenShift Route (TLS passthrough)
- `readOnlyRootFilesystem: true` with emptyDirs for nginx runtime directories

Routing table:

| Path | Backend | Notes |
|---|---|---|
| `/otlp/*` | `alloy-otlp:4318` | prefix stripped by nginx |
| `/prometheus/api/v1/push` | `alloy-prom:9009` | rewritten to `/api/v1/write` |
| `/healthz` | nginx (200 OK) | no auth — used by k8s probes |

Key values to override:

```yaml
# alloy-gateway/values.yaml
route:
  hostname: o11y-collector.example.com

backends:
  otlp:
    service: alloy-otlp
    port: 4318
    # namespace: monitoring   # cross-namespace override
  prom:
    service: alloy-prom
    port: 9009
```

---

## Installing

### Prerequisites

- Helm 3.x
- `helm dependency update` must be run for each child chart before install/upgrade

```bash
helm dependency update ./alloy-otlp
helm dependency update ./alloy-prom
helm dependency update ./alloy-discovery
```

### Install all charts

```bash
NS=monitoring

helm upgrade --install alloy-gateway   ./alloy-gateway   -n $NS
helm upgrade --install alloy-otlp      ./alloy-otlp      -n $NS
helm upgrade --install alloy-prom      ./alloy-prom      -n $NS
helm upgrade --install alloy-discovery ./alloy-discovery -n $NS
```

### Standalone alloy-chart (no gateway)

```bash
helm upgrade --install alloy ./alloy-chart -n $NS
```

### Override values at install time

```bash
helm upgrade --install alloy-prom ./alloy-prom -n $NS \
  --set alloy.persistence.size=20Gi \
  --set alloy.persistence.storageClass=sc-ontap-nas
```

---

## Developing

### Changing the Alloy config

Edit `config.content` in the relevant child chart's `values.yaml`. All config is rendered into a ConfigMap; pods roll automatically on change via a `checksum/config` annotation.

### Adding a new child chart

1. Create a directory `alloy-<name>/`
2. Write `Chart.yaml` declaring `alloy-chart` as a dependency (version `0.1.0`, repo `file://../alloy-chart`)
3. Write `values.yaml` with all overrides nested under `alloy:`
4. No `templates/` directory needed — `alloy-chart` renders everything

### Switching storage class

Set `alloy.persistence.storageClass` in the child chart's `values.yaml`. If you need to reuse an existing PVC:

```yaml
alloy:
  persistence:
    existingClaim: my-pvc-name
    enabled: false   # existingClaim takes precedence regardless
```

### Linting

```bash
helm lint ./alloy-chart
helm lint ./alloy-gateway
helm dependency update ./alloy-otlp      && helm lint ./alloy-otlp
helm dependency update ./alloy-prom      && helm lint ./alloy-prom
helm dependency update ./alloy-discovery && helm lint ./alloy-discovery
```

### Dry-run template render

```bash
helm template test ./alloy-prom
helm template test ./alloy-discovery
```
