# Helm Charts for Kubernetes & OpenShift — Design Spec

## Goal

Add Kubernetes and OpenShift deployment options to the kodus-installer alongside the existing Docker Compose setup. Users should be able to `helm install` the Kodus stack on vanilla Kubernetes or OpenShift with a single command. The charts must meet **SOC 2 Type II** compliance requirements for production deployments.

## Architecture

### Chart Structure

Three Helm charts in `charts/`:

```
charts/
├── kodus-common/          # Library chart (type: library)
│   ├── Chart.yaml
│   └── templates/
│       ├── _helpers.tpl   # Names, labels, selectors, compliance labels
│       ├── _env.tpl       # Shared env var blocks (DB, RabbitMQ, auth, git)
│       ├── _pod.tpl       # Shared PodSpec (image, resources, probes, securityContext)
│       └── _security.tpl  # Shared security contexts, seccomp profiles
│
├── kodus/                 # Kubernetes vanilla chart
│   ├── Chart.yaml
│   ├── values.yaml        # Production-hardened defaults
│   ├── values-example.yaml
│   ├── values-dev.yaml    # Dev overlay (relaxed security, low resources)
│   └── templates/
│       ├── _helpers.tpl
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── configmap.yaml
│       ├── secrets.yaml
│       ├── ingress.yaml
│       ├── serviceaccount.yaml
│       ├── role.yaml
│       ├── rolebinding.yaml
│       ├── networkpolicy.yaml
│       ├── migration-job.yaml
│       ├── resourcequota.yaml
│       ├── hpa.yaml
│       ├── pdb.yaml
│       └── NOTES.txt
│
└── kodus-openshift/       # OpenShift chart
    ├── Chart.yaml
    ├── values.yaml        # Production-hardened defaults + OpenShift specifics
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
        ├── role.yaml
        ├── rolebinding.yaml
        ├── networkpolicy.yaml
        ├── migration-job.yaml
        ├── resourcequota.yaml
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

6. **Production-hardened defaults.** The `values.yaml` ships with security-first defaults (TLS enabled, NetworkPolicy enabled, no inline secrets). The `values-dev.yaml` overlay relaxes these for local development.

## SOC 2 Type II Compliance

### Requirements Mapping

| SOC 2 Control | Implementation |
|---|---|
| **CC6.1** Logical access controls | RBAC (Role/RoleBinding), ServiceAccount per release, NetworkPolicy |
| **CC6.6** External system boundaries | TLS termination on all ingress, encrypted DB connections |
| **CC6.7** Data transmission security | TLS required by default, `API_DATABASE_DISABLE_SSL: "false"` in production |
| **CC6.8** Unauthorized changes prevention | Immutable image tags (no `latest`), `readOnlyRootFilesystem` where possible |
| **CC7.1** System monitoring | Probes, resource quotas, structured logging to stdout |
| **CC7.2** Anomaly detection | Resource limits, HPA, PDB for availability |
| **CC8.1** Change management | Helm releases with versioned charts, migration Jobs with audit trail |
| **A1.2** Recovery procedures | PVC-based persistence, VolumeSnapshot support |

### Image Tag Policy

**`latest` tag is NOT used in production defaults.** All service images use a pinned tag or SHA digest:

```yaml
services:
  api:
    image:
      repository: ghcr.io/kodustech/kodus-ai-api
      tag: ""       # REQUIRED — must be set by user (e.g., "2.1.0" or "sha256:abc...")
      # digest: "" # Alternative: pin by SHA digest for maximum immutability
```

The chart validates that at least `tag` or `digest` is set and fails with a clear error if both are empty. The `values-dev.yaml` overlay sets `tag: latest` for convenience.

### Secret Management

**Inline secrets are disabled by default.** Production deployments MUST use one of:

```yaml
global:
  # Option 1: Pre-created Kubernetes Secret
  existingSecret: "kodus-credentials"

  # Option 2: External secret operator (recommended for SOC 2)
  externalSecrets:
    enabled: false
    # Supported backends: aws-secrets-manager, hashicorp-vault, azure-keyvault, gcp-secret-manager
    backend: ""
    # Backend-specific config
    store: ""          # SecretStore or ClusterSecretStore name
    refreshInterval: "1h"
```

When `externalSecrets.enabled: true`, the chart generates `ExternalSecret` resources (from the external-secrets operator) instead of native Kubernetes Secrets. This provides:
- Automatic secret rotation
- Audit trail for secret access
- No secrets stored in Helm values or git

The `values-dev.yaml` overlay re-enables inline secrets for local development.

### Encryption in Transit

TLS is **enabled by default** in production:

```yaml
# Ingress (kodus chart)
ingress:
  tls:
    enabled: true         # Default: true (SOC 2)
    secretName: ""        # TLS cert secret — or use cert-manager annotations
  annotations:
    cert-manager.io/cluster-issuer: ""  # Optional: auto-provision certs

# Route (kodus-openshift chart)
route:
  tls:
    termination: edge
    insecureEdgePolicy: Redirect  # Force HTTPS

# Database connections
global:
  config:
    API_DATABASE_DISABLE_SSL: "false"  # Default: SSL enabled
    DB_SSL: "true"
```

### Audit Labels

All resources include compliance-relevant labels for traceability:

```yaml
global:
  labels:
    app.kubernetes.io/part-of: kodus
    app.kubernetes.io/managed-by: helm
    kodus.io/environment: ""      # REQUIRED: production, staging, development
    kodus.io/team: ""             # REQUIRED: team owning this deployment
    kodus.io/compliance: "soc2"
    kodus.io/data-classification: "confidential"
```

The `_helpers.tpl` in `kodus-common` merges these with standard Helm labels on every resource.

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
      tag: ""     # REQUIRED
    port: 3000
    replicas: 2   # HA by default
    probes:
      path: /
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  api:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-ai-api
      tag: ""     # REQUIRED
    port: 3001
    replicas: 2
    probes:
      path: /health
    resources:
      requests: { cpu: 250m, memory: 512Mi }
      limits:   { cpu: "1", memory: 1Gi }

  worker:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-ai-worker
      tag: ""     # REQUIRED
    port: null  # no exposed port
    replicas: 2
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
      tag: ""     # REQUIRED
    port: 3332
    replicas: 2
    probes:
      path: /health
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  service-ast:
    enabled: true
    image:
      repository: ghcr.io/kodustech/kodus-service-ast
      tag: ""     # REQUIRED
    port: 3002
    replicas: 1
    probes:
      path: /health
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }

  mcp-manager:
    enabled: false
    image:
      repository: ghcr.io/kodustech/kodus-mcp-manager
      tag: ""     # REQUIRED when enabled
    port: 3101
    replicas: 1
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
image:
  pullPolicy: Always  # SOC 2: always verify image on pull
imagePullSecrets: []
# - name: ghcr-credentials
```

`pullPolicy: Always` ensures the runtime always validates the image against the registry, preventing use of tampered local cache.

## Database Migrations

Migrations run as a **Helm hook Job** instead of inside every pod replica to avoid race conditions:

```yaml
migrations:
  enabled: true
  image:
    repository: ghcr.io/kodustech/kodus-ai-api
    tag: ""   # REQUIRED — should match services.api.tag
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

The migration Job includes an `initContainer` that waits for PostgreSQL readiness before running migrations. This handles the case where sub-chart pods (PostgreSQL, MongoDB) are still starting:

```yaml
initContainers:
  - name: wait-for-postgres
    image: busybox
    command: ['sh', '-c', 'until nc -z {{ .Release.Name }}-postgresql 5432; do sleep 2; done']
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
    WEB_HOSTNAME_API: ""          # REQUIRED — no default (must be explicit)
    WEB_PORT_API: "3001"
    WEB_PORT: "3000"
    NEXTAUTH_URL: ""              # REQUIRED — must be HTTPS in production
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
    API_DATABASE_DISABLE_SSL: "false"   # SOC 2: SSL enabled by default
    API_MG_DB_PRODUCTION_CONFIG: ""

    # -- RabbitMQ
    API_RABBITMQ_ENABLED: "true"

    # -- Cron
    API_CRON_SYNC_CODE_REVIEW_REACTIONS: "* 5 * * *"
    API_CRON_KODY_LEARNING: "0 0 * * 6"
    API_CRON_CHECK_IF_PR_SHOULD_BE_APPROVED: "*/2 * * * *"

    # -- General (set on all containers)
    NODE_ENV: "production"

    # -- AST Service
    API_ENABLE_CODE_REVIEW_AST: "true"
    API_SERVICE_AST_URL: "http://{{ .Release.Name }}-service-ast:3002"
    AST_NODE_ENV: "production"
    AST_LOG_PRETTY: "false"
    AST_LOG_LEVEL: "info"
    AST_PORT: "3002"
    DB_SSL: "true"              # SOC 2: SSL enabled by default
    RABBIT_URL: "amqp://$(RABBITMQ_USER):$(RABBITMQ_PASS)@{{ .Release.Name }}-rabbitmq:5672/kodus-ai"
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
    API_MCP_MANAGER_REDIRECT_URI: ""  # REQUIRED when MCP enabled
    API_MCP_MANAGER_PG_DB_SCHEMA: "mcp-manager"

    # -- Git Provider Webhooks (fill only the one in use)
    API_GITHUB_CODE_MANAGEMENT_WEBHOOK: ""
    API_GITLAB_CODE_MANAGEMENT_WEBHOOK: ""
    GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK: ""
    GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK: ""
    API_FORGEJO_CODE_MANAGEMENT_WEBHOOK: ""
```

### Secrets (sensitive)

**Inline secrets are disabled by default.** Production must use `existingSecret` or `externalSecrets`:

```yaml
global:
  # Option 1: reference pre-created K8s Secret
  existingSecret: ""

  # Option 2: external-secrets operator
  externalSecrets:
    enabled: false
    backend: ""
    store: ""
    refreshInterval: "1h"

  # Option 3: inline (ONLY for dev — ignored when existingSecret or externalSecrets is set)
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

## RBAC

Least-privilege RBAC for the Kodus ServiceAccount:

```yaml
serviceAccount:
  create: true
  name: ""
  annotations: {}    # e.g., eks.amazonaws.com/role-arn for IRSA

rbac:
  create: true
  rules:
    # Only permissions the app actually needs
    - apiGroups: [""]
      resources: ["configmaps", "secrets"]
      verbs: ["get", "list", "watch"]
    - apiGroups: [""]
      resources: ["pods"]
      verbs: ["get", "list"]
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
  annotations:
    cert-manager.io/cluster-issuer: ""    # Optional: auto TLS
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
  tls:
    enabled: true          # SOC 2: TLS on by default
    secretName: ""
  hosts:
    web:
      host: kodus.example.com
      path: /
      serviceName: web
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
    insecureEdgePolicy: Redirect  # Force HTTPS
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

Network isolation is **enabled by default** (SOC 2 requirement):

```yaml
networkPolicy:
  enabled: true   # SOC 2: enabled by default
  # Creates policies that:
  # - Allow web → api, webhooks (frontend to backend)
  # - Allow api → postgresql, mongodb, rabbitmq, service-ast, mcp-manager
  # - Allow worker → postgresql, mongodb, rabbitmq
  # - Allow webhooks → postgresql, mongodb, rabbitmq
  # - Allow service-ast → rabbitmq
  # - Allow ingress controller → web, api, webhooks (external traffic)
  # - Deny all other inter-pod traffic (default deny)
  ingressControllerLabels: {}
  # e.g., for nginx-ingress:
  # ingressControllerLabels:
  #   app.kubernetes.io/name: ingress-nginx
```

## Security

### Pod Security (both charts)

```yaml
podSecurityContext:
  runAsNonRoot: true
  fsGroup: 1001
  seccompProfile:
    type: RuntimeDefault     # SOC 2: seccomp enabled

containerSecurityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true   # SOC 2: read-only by default
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]            # SOC 2: drop all capabilities
```

**`readOnlyRootFilesystem: true`** — Node.js apps need writable `/tmp`. This is handled via an `emptyDir` volume mount:

```yaml
# In deployment.yaml template
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir:
      sizeLimit: 100Mi
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

### Pod Security Standards

The chart is designed to comply with the Kubernetes **Restricted** Pod Security Standard. When using Pod Security Admission:

```yaml
# Namespace labels (user responsibility, documented in NOTES.txt)
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

## Resource Quotas

Optional namespace-level resource quotas to prevent resource exhaustion:

```yaml
resourceQuota:
  enabled: false   # Enable for multi-tenant clusters
  hard:
    requests.cpu: "8"
    requests.memory: "16Gi"
    limits.cpu: "16"
    limits.memory: "32Gi"
    pods: "50"
    persistentvolumeclaims: "10"
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

## Logging

All containers log to stdout/stderr in structured JSON format (no log files on disk). This enables centralized log aggregation via:
- EFK stack (Elasticsearch/Fluentd/Kibana)
- Loki/Grafana
- CloudWatch/Stackdriver/Azure Monitor
- Any sidecar-based log shipper

```yaml
global:
  config:
    API_LOG_PRETTY: "false"    # JSON output, not human-readable
    API_LOG_LEVEL: "error"     # Production: minimal log verbosity
    AST_LOG_PRETTY: "false"
```

The chart does NOT include a logging stack — it integrates with whatever the cluster already has. NOTES.txt documents how to verify logs are flowing.

## Backup & Recovery

### VolumeSnapshots

Optional VolumeSnapshot support for data PVCs:

```yaml
backup:
  enabled: false
  # When enabled, creates VolumeSnapshot resources on a schedule
  schedule: "0 2 * * *"  # Daily at 2 AM
  retention: 7            # Keep 7 snapshots
  snapshotClassName: ""   # Must match cluster's VolumeSnapshotClass
```

When enabled, a CronJob creates VolumeSnapshots of PostgreSQL and MongoDB PVCs. This provides point-in-time recovery capability.

**Note:** For production SOC 2 compliance, managed database services (RDS, Atlas, etc.) with built-in backup are recommended over in-cluster databases.

## Optional Features

### HPA (HorizontalPodAutoscaler)

```yaml
autoscaling:
  enabled: true    # SOC 2: availability — enabled by default
  minReplicas: 2
  maxReplicas: 10
  targetCPU: 80
  targetMemory: 80
```

### PDB (PodDisruptionBudget)

```yaml
pdb:
  enabled: true    # SOC 2: availability — enabled by default
  minAvailable: 1
```

Both are enabled by default for production availability. The `values-dev.yaml` overlay disables them.

### Topology Spread

Optional pod scheduling constraints for multi-node HA:

```yaml
topologySpreadConstraints:
  enabled: false
  maxSkew: 1
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: DoNotSchedule
```

## Usage

```bash
# Kubernetes (production)
cd charts/kodus
helm dependency update
helm install kodus . \
  -f values.yaml \
  --set global.existingSecret=kodus-credentials \
  --set ingress.hosts.web.host=kodus.mycompany.com \
  --set ingress.hosts.api.host=api.kodus.mycompany.com \
  -n kodus --create-namespace

# Kubernetes (dev mode — relaxed security, latest tags, single replica)
helm install kodus . -f values.yaml -f values-dev.yaml -n kodus-dev --create-namespace

# OpenShift (production)
cd charts/kodus-openshift
helm dependency update
helm install kodus . \
  -f values.yaml \
  --set global.existingSecret=kodus-credentials \
  --set route.hosts.web.host=kodus.apps.cluster.mycompany.com \
  -n kodus --create-namespace
```

## values-dev.yaml

Development overlay that relaxes production hardening:

```yaml
# values-dev.yaml — overlay for local/dev environments
# Relaxes SOC 2 defaults for development convenience

services:
  web:
    image: { tag: latest }
    replicas: 1
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits:   { cpu: 200m, memory: 256Mi }
  api:
    image: { tag: latest }
    replicas: 1
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
  worker:
    image: { tag: latest }
    replicas: 1
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 512Mi }
  webhooks:
    image: { tag: latest }
    replicas: 1
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits:   { cpu: 200m, memory: 256Mi }
  service-ast:
    image: { tag: latest }
    replicas: 1
    resources:
      requests: { cpu: 50m, memory: 128Mi }
      limits:   { cpu: 200m, memory: 256Mi }

image:
  pullPolicy: IfNotPresent

migrations:
  image: { tag: latest }

global:
  config:
    API_LOG_LEVEL: "debug"
    API_LOG_PRETTY: "true"
    API_DATABASE_DISABLE_SSL: "true"
    DB_SSL: "false"
  # Dev mode: allow inline secrets
  secrets:
    API_JWT_SECRET: "dev-secret"
    WEB_NEXTAUTH_SECRET: "dev-secret"
    WEB_JWT_SECRET_KEY: "dev-secret"
    API_CRYPTO_KEY: "dev-crypto-key-0000000000000000"
    CODE_MANAGEMENT_SECRET: "dev-webhook-secret"

containerSecurityContext:
  readOnlyRootFilesystem: false  # Relaxed for dev

ingress:
  tls:
    enabled: false  # No TLS in dev

autoscaling:
  enabled: false

pdb:
  enabled: false

networkPolicy:
  enabled: false

resourceQuota:
  enabled: false
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

**Note:** The docker-compose `USE_LOCAL_DB` and `USE_LOCAL_RABBITMQ` flags are NOT used in the Helm charts. They are replaced by the sub-chart `enabled` toggles (`postgresql.enabled`, `mongodb.enabled`, `rabbitmq.enabled`). Setting these to `false` is equivalent to `USE_LOCAL_DB=false` / `USE_LOCAL_RABBITMQ=false`.

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
  disableSsl: "false"    # SOC 2: SSL by default
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
  uri: amqps://user:pass@your-rabbitmq-host:5671/kodus-ai  # Note: amqps (TLS)
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

4. SOC 2 checklist:
   - [ ] TLS enabled on ingress
   - [ ] Secrets via existingSecret or externalSecrets (no inline)
   - [ ] NetworkPolicy enabled
   - [ ] Image tags pinned (no :latest)
   - [ ] Pod Security Standards enforced on namespace
   - [ ] Centralized logging configured

5. Documentation: https://docs.kodus.io
```

## Files Not Changed

The existing Docker Compose setup (`docker-compose.yml`, `scripts/`, `.env.example`, `docker/`) remains untouched. The Helm charts are a parallel deployment option.
