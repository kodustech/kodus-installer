# Helm Charts for Kubernetes & OpenShift — Design Spec

## Goal

Add Kubernetes and OpenShift deployment options to the kodus-installer alongside the existing Docker Compose setup. Users should be able to `helm install` the Kodus stack on vanilla Kubernetes or OpenShift with a single command.

## Architecture

### Chart Structure

Three Helm charts in `charts/`:

```
charts/
├── kodus-common/          # Library chart (type: library)
│   ├── Chart.yaml
│   └── templates/
│       ├── _helpers.tpl   # Names, labels, selectors
│       ├── _env.tpl       # Shared env var blocks (DB, RabbitMQ, auth, git)
│       └── _pod.tpl       # Shared PodSpec (image, resources, probes, securityContext)
│
├── kodus/                 # Kubernetes vanilla chart
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-example.yaml
│   ├── values-dev.yaml    # Dev overlay (low resources, single replica)
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── configmap.yaml
│       ├── secrets.yaml
│       ├── ingress.yaml
│       ├── serviceaccount.yaml
│       ├── networkpolicy.yaml
│       ├── migration-job.yaml
│       ├── hpa.yaml
│       ├── pdb.yaml
│       └── NOTES.txt
│
└── kodus-openshift/       # OpenShift chart
    ├── Chart.yaml
    ├── values.yaml
    ├── values-example.yaml
    ├── values-dev.yaml
    └── templates/
        ├── _helpers.tpl
        ├── deployment.yaml
        ├── service.yaml
        ├── configmap.yaml
        ├── secrets.yaml
        ├── route.yaml
        ├── scc.yaml
        ├── serviceaccount.yaml
        ├── networkpolicy.yaml
        ├── migration-job.yaml
        ├── hpa.yaml
        ├── pdb.yaml
        └── NOTES.txt
```

### Chart Versioning

All three charts start at `0.1.0` and follow semver independently. The `appVersion` in `Chart.yaml` tracks the Kodus application version (matching the Docker image tags).

### Design Decisions

1. **Two separate charts** (`kodus/` and `kodus-openshift/`) instead of a single chart with conditionals. This keeps each chart focused and avoids OpenShift users needing to understand K8s Ingress flags and vice versa.

2. **Shared library chart** (`kodus-common/`) to avoid duplicating helpers, env var templates, and PodSpec logic. Referenced as `file://../kodus-common` dependency.

3. **Generic iteratable templates.** A single `deployment.yaml` iterates over `services` in values.yaml to generate all Deployments. Same for `service.yaml`. Adding a new service means adding an entry to `values.yaml` — no new template files needed.

4. **Bitnami sub-charts** for PostgreSQL, MongoDB, and RabbitMQ with `condition` toggle. When disabled, users point to external instances via `externalPostgresql`, `externalMongodb`, `externalRabbitmq` values.

5. **Database migrations via Helm hook Job.** Migrations run as a pre-install/pre-upgrade Job (not inside every pod replica) to avoid race conditions with multiple replicas.

## Dependencies

| Chart | Version | App Version | Notes |
|---|---|---|---|
| bitnami/postgresql | 18.5.6 | PostgreSQL 16 | Image override: `pgvector/pgvector:0.8.2-pg16` (matches docker-compose parity) |
| bitnami/mongodb | 18.6.11 | MongoDB 8.x | |
| bitnami/rabbitmq | 16.0.14 | RabbitMQ 4.1.3 | `communityPlugins` for delayed_message_exchange |
| kodus-common | 0.1.0 | — | Local library chart (`file://`) |

**Note on PostgreSQL version:** The docker-compose uses `pgvector/pgvector:pg16`. The Helm charts match this to ensure data compatibility. Users who want to upgrade to pg17 can override `postgresql.image.tag`.

### RabbitMQ Delayed Message Exchange — Deprecation Notice

The `rabbitmq_delayed_message_exchange` plugin was **archived in January 2026**. It is Mnesia-based and will become incompatible with RabbitMQ 4.3+. The Kodus codebase currently depends on it, so the charts include it, but this will require a codebase-level refactor in the future.

## Services

Six Kodus services defined in `values.yaml` under a `services` map. All services have an explicit `enabled` field:

```yaml
services:
  web:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-ai-web
      tag: latest
    port: 3000
    probes:
      path: /
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  api:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-ai-api
      tag: latest
    port: 3001
    probes:
      path: /health
    resources:
      requests: { cpu: 250m, memory: 512Mi }
      limits:   { cpu: "1", memory: 1Gi }

  worker:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-ai-worker
      tag: latest
    port: null  # no exposed port
    probes:
      # Worker has no HTTP endpoint. Uses a script that verifies
      # the Node.js process is alive and connected to RabbitMQ.
      type: exec
      command: ["node", "-e", "require('amqplib').connect(process.env.API_RABBITMQ_URI).then(() => process.exit(0)).catch(() => process.exit(1))"]
    resources:
      requests: { cpu: 250m, memory: 512Mi }
      limits:   { cpu: "1", memory: 1Gi }

  webhooks:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-ai-webhook
      tag: latest
    port: 3332
    probes:
      path: /health
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  service-ast:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-service-ast
      tag: latest
    port: 3002
    probes:
      path: /health
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  mcp-manager:
    enabled: false
    image:
      repository: ghcr.io/kodustech/kodus-mcp-manager
      tag: latest
    port: 3101
    probes:
      path: /health
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
```

The template `deployment.yaml` iterates `range $name, $svc := .Values.services` and skips entries where `enabled` is `false`.

## Image Pull

Images are hosted on `ghcr.io/kodustech/` (potentially private). The chart supports `imagePullSecrets`:

```yaml
imagePullSecrets: []
# - name: ghcr-credentials
```

When set, all Deployments and the migration Job include the pull secret reference.

## Database Migrations

Migrations run as a **Helm hook Job** instead of inside every pod replica to avoid race conditions:

```yaml
migrations:
  enabled: true
  image:
    repository: ghcr.io/kodustech/kodus-ai-api
    tag: latest
  env:
    RUN_MIGRATIONS: "true"
    RUN_SEEDS: "true"
```

The Job uses Helm annotations:

```yaml
annotations:
  "helm.sh/hook": pre-install,pre-upgrade
  "helm.sh/hook-weight": "0"
  "helm.sh/hook-delete-policy": before-hook-creation
```

This ensures migrations complete before any application pods start. The API pods run with `RUN_MIGRATIONS=false`.

## Configuration

### ConfigMap (non-sensitive)

Complete environment variable mapping, grouped by concern:

```yaml
global:
  config:
    # -- Web
    WEB_NODE_ENV: "self-hosted"
    WEB_HOSTNAME_API: "localhost"
    WEB_PORT_API: "3001"
    WEB_PORT: "3000"
    NEXTAUTH_URL: "http://localhost:3000"
    WEB_SUPPORT_DOCS_URL: "https://docs.kodus.io"
    WEB_SUPPORT_DISCORD_INVITE_URL: "https://discord.gg/CceCdAke"
    WEB_SUPPORT_TALK_TO_FOUNDER_URL: "https://cal.com/gabrielmalinosqui/30min"

    # -- API General
    API_NODE_ENV: "production"
    API_LOG_LEVEL: "error"
    API_LOG_PRETTY: "false"
    API_HOST: "0.0.0.0"
    API_PORT: "3001"
    API_RATE_MAX_REQUEST: "100"
    API_RATE_INTERVAL: "1000"
    API_CLOUD_MODE: "false"
    API_JWT_EXPIRES_IN: "365d"
    API_JWT_REFRESH_EXPIRES_IN: "7d"
    API_WEBHOOKS_PORT: "3332"
    GLOBAL_API_CONTAINER_NAME: "kodus-api"

    # -- Database
    API_DATABASE_ENV: "production"
    API_DATABASE_DISABLE_SSL: "true"

    # -- RabbitMQ
    API_RABBITMQ_ENABLED: "true"

    # -- Cron
    API_CRON_SYNC_CODE_REVIEW_REACTIONS: "* 5 * * *"
    API_CRON_KODY_LEARNING: "0 0 * * 6"
    API_CRON_CHECK_IF_PR_SHOULD_BE_APPROVED: "*/2 * * * *"

    # -- AST Service
    API_ENABLE_CODE_REVIEW_AST: "true"
    API_SERVICE_AST_URL: "http://{{ .Release.Name }}-service-ast:3002"
    AST_NODE_ENV: "production"
    AST_LOG_PRETTY: "false"
    AST_LOG_LEVEL: "info"
    AST_PORT: "3002"
    DB_SSL: "false"
    RABBIT_RETRY_QUEUE: "ast.jobs.retry.q"
    RABBIT_RETRY_TTL_MS: "60000"
    RABBIT_PREFETCH: "1"
    RABBIT_PUBLISH_TIMEOUT_MS: "5000"
    RABBIT_SAC: "false"
    ENABLE_INCREMENTAL_GRAPH: "false"
    ENABLE_GRAPH_BENCHMARK: "false"
    ENABLE_LIGHTWEIGHT_GRAPH: "false"

    # -- MCP
    API_MCP_SERVER_ENABLED: "false"
    API_KODUS_SERVICE_MCP_MANAGER: "http://{{ .Release.Name }}-mcp-manager:3101"
    API_KODUS_MCP_SERVER_URL: "http://{{ .Release.Name }}-api:3001/mcp"
    API_MCP_MANAGER_LOG_LEVEL: "info"
    API_MCP_MANAGER_PORT: "3101"
    API_MCP_MANAGER_NODE_ENV: "production"
    API_MCP_MANAGER_DATABASE_ENV: "production"
    API_MCP_MANAGER_CORS_ORIGINS: "*"
    API_MCP_MANAGER_COMPOSIO_BASE_URL: "https://backend.composio.dev/api/v3"
    API_MCP_MANAGER_MCP_PROVIDERS: "kodusmcp,composio,custom"
    API_MCP_MANAGER_REDIRECT_URI: "http://localhost:3000/setup/mcp/oauth"
    API_MCP_MANAGER_PG_DB_SCHEMA: "mcp-manager"

    # -- Git Provider Webhooks (fill only the one in use)
    API_GITHUB_CODE_MANAGEMENT_WEBHOOK: ""
    API_GITLAB_CODE_MANAGEMENT_WEBHOOK: ""
    GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK: ""
    GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK: ""
    API_FORGEJO_CODE_MANAGEMENT_WEBHOOK: ""
```

### Secrets (sensitive)

Two modes:

- **Inline** (dev/test): passwords and keys set directly in `values.yaml`
- **existingSecret** (production): reference a pre-created Kubernetes Secret

```yaml
global:
  existingSecret: ""  # when set, all inline secrets are ignored
  secrets:
    # -- Auth
    API_JWT_SECRET: ""
    API_JWT_REFRESHSECRET: ""
    WEB_NEXTAUTH_SECRET: ""
    WEB_JWT_SECRET_KEY: ""
    API_CRYPTO_KEY: ""

    # -- Webhooks
    CODE_MANAGEMENT_SECRET: ""
    CODE_MANAGEMENT_WEBHOOK_TOKEN: ""

    # -- LLM Providers
    API_OPEN_AI_API_KEY: ""
    API_OPENAI_FORCE_BASE_URL: ""
    API_LLM_PROVIDER_MODEL: ""
    API_MORPHLLM_API_KEY: ""
    API_E2B_KEY: ""

    # -- MCP Manager
    API_MCP_MANAGER_JWT_SECRET: ""
    API_MCP_MANAGER_ENCRYPTION_SECRET: ""
    API_MCP_MANAGER_COMPOSIO_API_KEY: ""
```

Sub-charts also support `existingSecret` for their own credentials.

## ServiceAccount

Both charts create a ServiceAccount by default:

```yaml
serviceAccount:
  create: true
  name: ""           # auto-generated if empty
  annotations: {}    # e.g., for IAM roles (EKS IRSA, GKE Workload Identity)
```

On OpenShift, the SCC is bound to this ServiceAccount:

```yaml
# scc.yaml (kodus-openshift only)
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: {{ include "kodus.sccName" . }}
users:
  - system:serviceaccount:{{ .Release.Namespace }}:{{ include "kodus.serviceAccountName" . }}
```

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
      serviceName: web       # maps to services.web
    api:
      host: api.kodus.example.com
      path: /
      serviceName: api
    webhooks:
      host: api.kodus.example.com
      path: /webhooks
      serviceName: webhooks
    mcp-manager:
      host: api.kodus.example.com
      path: /mcp
      serviceName: mcp-manager
```

Each `hosts` entry includes a `serviceName` field that maps to the corresponding service backend. The `ingress.yaml` template uses this to generate the correct `backend.service.name` and `backend.service.port`.

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
      serviceName: web
    api:
      host: api.kodus.apps.cluster.example.com
      serviceName: api
    webhooks:
      host: api.kodus.apps.cluster.example.com
      path: /webhooks
      serviceName: webhooks
```

Single `route.yaml` iterates over `hosts` map.

## NetworkPolicy

Optional network isolation (mirrors docker-compose network segmentation):

```yaml
networkPolicy:
  enabled: false
  # When enabled, creates policies that:
  # - Allow web → api, webhooks
  # - Allow api → postgresql, mongodb, rabbitmq, service-ast, mcp-manager
  # - Allow worker → postgresql, mongodb, rabbitmq
  # - Allow webhooks → postgresql, mongodb, rabbitmq
  # - Allow service-ast → rabbitmq
  # - Deny all other inter-pod traffic
```

Disabled by default for ease of setup. Recommended for production.

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

Default probes applied to all HTTP services. Per-service `probes.path` override is supported:

```yaml
defaultProbes:
  startup:
    httpGet: { path: "{{ .probes.path }}", port: http }
    failureThreshold: 30
    periodSeconds: 5
  liveness:
    httpGet: { path: "{{ .probes.path }}", port: http }
    initialDelaySeconds: 30
    periodSeconds: 10
  readiness:
    httpGet: { path: "{{ .probes.path }}", port: http }
    initialDelaySeconds: 10
    periodSeconds: 5
```

Worker uses exec probe that verifies RabbitMQ connectivity:

```yaml
services:
  worker:
    probes:
      type: exec
      command: ["node", "-e", "require('amqplib').connect(process.env.API_RABBITMQ_URI).then(() => process.exit(0)).catch(() => process.exit(1))"]
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

# Kubernetes (dev mode — low resources, single replica)
helm install kodus . -f values.yaml -f values-dev.yaml -n kodus-dev --create-namespace

# OpenShift
cd charts/kodus-openshift
helm dependency update
helm install kodus . -f values.yaml -n kodus --create-namespace
```

## PostgreSQL with pgvector

The Bitnami PostgreSQL chart uses `bitnami/postgresql` image by default, which does not include pgvector. The chart overrides the image to match docker-compose parity (PostgreSQL 16):

```yaml
postgresql:
  image:
    repository: pgvector/pgvector
    tag: 0.8.2-pg16
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

### RabbitMQ Vhost

The Kodus stack uses vhost `/kodus-ai`. The Bitnami chart does not create custom vhosts by default. Configuration via `extraConfiguration`:

```yaml
rabbitmq:
  extraConfiguration: |
    ## Custom vhosts
    ## These are created via a post-start lifecycle hook
  lifecycle:
    postStart:
      exec:
        command:
          - /bin/bash
          - -c
          - |
            until rabbitmqctl await_startup; do sleep 2; done
            rabbitmqctl add_vhost kodus-ai || true
            rabbitmqctl add_vhost kodus-ast || true
            rabbitmqctl set_permissions -p kodus-ai "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*"
            rabbitmqctl set_permissions -p kodus-ast "$RABBITMQ_DEFAULT_USER" ".*" ".*" ".*"
```

This mirrors the `init-definitions.sh` script from the docker-compose setup.

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
  existingSecret: ""

mongodb:
  enabled: false
externalMongodb:
  host: your-mongodb-host
  port: 27017
  username: kodusdev
  password: ""
  database: kodus
  existingSecret: ""

rabbitmq:
  enabled: false
externalRabbitmq:
  uri: amqp://user:pass@your-rabbitmq-host:5672/kodus-ai
  existingSecret: ""
```

## NOTES.txt Content

Post-install message shown to users:

```
Kodus has been deployed to namespace {{ .Release.Namespace }}.

1. Access the web UI:
   {{- if .Values.ingress.enabled }}
   https://{{ (index .Values.ingress.hosts "web").host }}
   {{- else }}
   kubectl port-forward svc/{{ .Release.Name }}-web {{ .Values.services.web.port }} -n {{ .Release.Namespace }}
   Then open http://localhost:{{ .Values.services.web.port }}
   {{- end }}

2. Check service status:
   kubectl get pods -n {{ .Release.Namespace }}

3. View logs:
   kubectl logs -f deploy/{{ .Release.Name }}-api -n {{ .Release.Namespace }}

4. Documentation: https://docs.kodus.io
```

## Files Not Changed

The existing Docker Compose setup (`docker-compose.yml`, `scripts/`, `.env.example`, `docker/`) remains untouched. The Helm charts are a parallel deployment option.
