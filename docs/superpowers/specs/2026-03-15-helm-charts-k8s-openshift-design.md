# Helm Charts for Kubernetes & OpenShift — Design Spec

## Goal

Add Kubernetes and OpenShift deployment options to the kodus-installer alongside the existing Docker Compose setup. Users should be able to `helm install` the Kodus stack on vanilla Kubernetes or OpenShift with a single command.

## Architecture

### Chart Structure

Three Helm charts in `charts/`:

```
charts/
├── kodus-common/          # Library chart (type: library)
│   └── templates/
│       ├── _helpers.tpl   # Names, labels, selectors
│       ├── _env.tpl       # Shared env var blocks (DB, RabbitMQ, auth, git)
│       └── _pod.tpl       # Shared PodSpec (image, resources, probes, securityContext)
│
├── kodus/                 # Kubernetes vanilla chart
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-example.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── configmap.yaml
│       ├── secrets.yaml
│       ├── ingress.yaml
│       ├── hpa.yaml
│       ├── pdb.yaml
│       └── NOTES.txt
│
└── kodus-openshift/       # OpenShift chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values-example.yaml
    └── templates/
        ├── _helpers.tpl
        ├── deployment.yaml
        ├── service.yaml
        ├── configmap.yaml
        ├── secrets.yaml
        ├── route.yaml
        ├── scc.yaml
        ├── hpa.yaml
        ├── pdb.yaml
        └── NOTES.txt
```

### Design Decisions

1. **Two separate charts** (`kodus/` and `kodus-openshift/`) instead of a single chart with conditionals. This keeps each chart focused and avoids OpenShift users needing to understand K8s Ingress flags and vice versa.

2. **Shared library chart** (`kodus-common/`) to avoid duplicating helpers, env var templates, and PodSpec logic. Referenced as `file://../kodus-common` dependency.

3. **Generic iteratable templates.** A single `deployment.yaml` iterates over `services` in values.yaml to generate all Deployments. Same for `service.yaml`. Adding a new service means adding an entry to `values.yaml` — no new template files needed.

4. **Bitnami sub-charts** for PostgreSQL, MongoDB, and RabbitMQ with `condition` toggle. When disabled, users point to external instances via `externalPostgresql`, `externalMongodb`, `externalRabbitmq` values.

## Dependencies

| Chart | Version | App Version | Notes |
|---|---|---|---|
| bitnami/postgresql | 18.5.6 | PostgreSQL 17 | Image override: `pgvector/pgvector:0.8.2-pg17` |
| bitnami/mongodb | 18.6.11 | MongoDB 8.x | |
| bitnami/rabbitmq | 16.0.14 | RabbitMQ 4.1.3 | `communityPlugins` for delayed_message_exchange |
| kodus-common | 0.1.0 | — | Local library chart (`file://`) |

### RabbitMQ Delayed Message Exchange — Deprecation Notice

The `rabbitmq_delayed_message_exchange` plugin was **archived in January 2026**. It is Mnesia-based and will become incompatible with RabbitMQ 4.3+. The Kodus codebase currently depends on it, so the charts include it, but this will require a codebase-level refactor in the future.

## Services

Six Kodus services defined in `values.yaml` under a `services` map:

```yaml
services:
  web:
    image:
      repository: ghcr.io/kodustech/kodus-ai-web
      tag: latest
    port: 3000
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  api:
    image:
      repository: ghcr.io/kodustech/kodus-ai-api
      tag: latest
    port: 3001
    resources:
      requests: { cpu: 250m, memory: 512Mi }
      limits:   { cpu: "1", memory: 1Gi }

  worker:
    image:
      repository: ghcr.io/kodustech/kodus-ai-worker
      tag: latest
    port: null  # no exposed port
    resources:
      requests: { cpu: 250m, memory: 512Mi }
      limits:   { cpu: "1", memory: 1Gi }

  webhooks:
    image:
      repository: ghcr.io/kodustech/kodus-ai-webhook
      tag: latest
    port: 3332
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  service-ast:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-service-ast
      tag: latest
    port: 3002
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  mcp-manager:
    enabled: false
    image:
      repository: ghcr.io/kodustech/kodus-mcp-manager
      tag: latest
    port: 3101
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
```

The template `deployment.yaml` iterates `range $name, $svc := .Values.services` and skips entries where `enabled` is explicitly `false`.

## Configuration

### ConfigMap (non-sensitive)

Generated from `global` values: node env, log levels, feature flags, webhook URLs, cron schedules, service URLs.

### Secrets (sensitive)

Two modes:

- **Inline** (dev/test): passwords and keys set directly in `values.yaml`
- **existingSecret** (production): reference a pre-created Kubernetes Secret

```yaml
global:
  existingSecret: ""  # when set, all inline secrets are ignored
  auth:
    jwtSecret: ""
    jwtRefreshSecret: ""
    nextAuthSecret: ""
    jwtSecretKey: ""
    cryptoKey: ""
  webhooks:
    codeManagementSecret: ""
    codeManagementWebhookToken: ""
```

Sub-charts also support `existingSecret` for their own credentials.

## Networking

### Kubernetes — Ingress

```yaml
ingress:
  enabled: true
  className: nginx
  annotations: {}
  tls:
    enabled: false
    secretName: ""
  hosts:
    web:
      host: kodus.example.com
      path: /
    api:
      host: api.kodus.example.com
      path: /
    webhooks:
      host: api.kodus.example.com
      path: /webhooks
    mcp-manager:
      host: api.kodus.example.com
      path: /mcp
```

Single `ingress.yaml` iterates over `hosts` map.

### OpenShift — Route

```yaml
route:
  enabled: true
  tls:
    termination: edge
    insecureEdgePolicy: Redirect
  hosts:
    web:
      host: kodus.apps.cluster.example.com
    api:
      host: api.kodus.apps.cluster.example.com
    webhooks:
      host: api.kodus.apps.cluster.example.com
      path: /webhooks
```

Single `route.yaml` iterates over `hosts` map.

## Security

### Kubernetes (both charts)

```yaml
podSecurityContext:
  runAsNonRoot: true
  fsGroup: 1001

containerSecurityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  allowPrivilegeEscalation: false
```

### OpenShift-specific

The `kodus-openshift` chart defaults to the `restricted-v2` SCC. Sub-chart overrides:

```yaml
postgresql:
  primary:
    podSecurityContext: { enabled: true, fsGroup: null }
    containerSecurityContext: { runAsNonRoot: true, allowPrivilegeEscalation: false }
  volumePermissions: { enabled: false }

mongodb:
  podSecurityContext: { enabled: true, fsGroup: null }
  containerSecurityContext: { runAsNonRoot: true }
  volumePermissions: { enabled: false }

rabbitmq:
  podSecurityContext: { enabled: true, fsGroup: null }
  containerSecurityContext: { runAsNonRoot: true }
  volumePermissions: { enabled: false }
```

`fsGroup: null` because OpenShift manages UIDs/GIDs via SCCs. `volumePermissions: false` to avoid privileged initContainers.

Optional custom SCC (`scc.create: false` by default):

```yaml
scc:
  create: false
  name: kodus-scc
```

## Probes

Default probes applied to all HTTP services:

```yaml
defaultProbes:
  startup:
    httpGet: { path: /health, port: http }
    failureThreshold: 30
    periodSeconds: 5
  liveness:
    httpGet: { path: /health, port: http }
    initialDelaySeconds: 30
    periodSeconds: 10
  readiness:
    httpGet: { path: /health, port: http }
    initialDelaySeconds: 10
    periodSeconds: 5
```

Worker uses exec probe (no HTTP port):

```yaml
services:
  worker:
    probes:
      liveness:
        exec:
          command: ["node", "-e", "process.exit(0)"]
```

Startup probe allows up to 2.5 minutes for container initialization (Node.js + migrations).

## Optional Features

### HPA (HorizontalPodAutoscaler)

```yaml
autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 5
  targetCPU: 80
  targetMemory: 80
```

### PDB (PodDisruptionBudget)

```yaml
pdb:
  enabled: false
  minAvailable: 1
```

Both are disabled by default. When enabled, they apply to all services in the `services` map.

## Usage

```bash
# Kubernetes
cd charts/kodus
helm dependency update
helm install kodus . -f values.yaml -n kodus --create-namespace

# OpenShift
cd charts/kodus-openshift
helm dependency update
helm install kodus . -f values.yaml -n kodus --create-namespace
```

## PostgreSQL with pgvector

The Bitnami PostgreSQL chart uses `bitnami/postgresql` image by default, which does not include pgvector. The chart overrides the image:

```yaml
postgresql:
  image:
    repository: pgvector/pgvector
    tag: 0.8.2-pg17
  primary:
    initdb:
      scripts:
        init.sql: |
          CREATE EXTENSION IF NOT EXISTS vector;
```

## RabbitMQ with Delayed Message Exchange

The Bitnami `extraPlugins` does not download external plugins. Configuration:

```yaml
rabbitmq:
  communityPlugins: >-
    https://github.com/rabbitmq/rabbitmq-delayed-message-exchange/releases/download/v4.2.0/rabbitmq_delayed_message_exchange-4.2.0.ez
  extraPlugins: "rabbitmq_delayed_message_exchange rabbitmq_prometheus"
```

## External Services

When sub-charts are disabled, external service connection details are provided:

```yaml
postgresql:
  enabled: false
externalPostgresql:
  host: your-postgres-host
  port: 5432
  username: kodusdev
  password: ""
  database: kodus_db
  disableSsl: "true"

mongodb:
  enabled: false
externalMongodb:
  host: your-mongodb-host
  port: 27017
  username: kodusdev
  password: ""
  database: kodus

rabbitmq:
  enabled: false
externalRabbitmq:
  uri: amqp://user:pass@your-rabbitmq-host:5672/kodus-ai
```

## Files Not Changed

The existing Docker Compose setup (`docker-compose.yml`, `scripts/`, `.env.example`, `docker/`) remains untouched. The Helm charts are a parallel deployment option.
