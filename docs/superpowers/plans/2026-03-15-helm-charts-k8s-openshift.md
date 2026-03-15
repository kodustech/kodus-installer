# Helm Charts (K8s + OpenShift) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create Helm charts for deploying Kodus on Kubernetes and OpenShift with SOC 2 Type II hardened defaults.

**Architecture:** Three charts — `kodus-common` (shared library), `kodus` (K8s vanilla with Ingress), `kodus-openshift` (OpenShift with Routes/SCCs). All use generic iterable templates and Bitnami sub-charts for databases/RabbitMQ.

**Tech Stack:** Helm 3, Kubernetes 1.28+, OpenShift 4.14+, Bitnami sub-charts (PostgreSQL 18.5.6, MongoDB 18.6.11, RabbitMQ 16.0.14)

**Spec:** `docs/superpowers/specs/2026-03-15-helm-charts-k8s-openshift-design.md`

---

## File Structure

```
charts/
├── kodus-common/
│   ├── Chart.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── _env.tpl
│       ├── _pod.tpl
│       └── _security.tpl
│
├── kodus/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-example.yaml
│   ├── values-dev.yaml
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
└── kodus-openshift/
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
        ├── role.yaml
        ├── rolebinding.yaml
        ├── networkpolicy.yaml
        ├── migration-job.yaml
        ├── resourcequota.yaml
        ├── hpa.yaml
        ├── pdb.yaml
        └── NOTES.txt
```

---

## Chunk 1: Library Chart (kodus-common)

### Task 1: Create kodus-common Chart.yaml

**Files:**
- Create: `charts/kodus-common/Chart.yaml`

- [ ] **Step 1: Create Chart.yaml**

```yaml
apiVersion: v2
name: kodus-common
description: Shared library chart for Kodus Helm charts
type: library
version: 0.1.0
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus-common/Chart.yaml
git commit -m "feat(helm): add kodus-common library chart scaffold"
```

### Task 2: Create _helpers.tpl

**Files:**
- Create: `charts/kodus-common/templates/_helpers.tpl`

This file provides reusable named templates for naming, labels, and selectors. All charts will call these via `include`.

- [ ] **Step 1: Write _helpers.tpl**

```yaml
{{/*
Expand the name of the chart.
*/}}
{{- define "kodus-common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kodus-common.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label.
*/}}
{{- define "kodus-common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels — includes compliance/audit labels from global.labels.
*/}}
{{- define "kodus-common.labels" -}}
helm.sh/chart: {{ include "kodus-common.chart" . }}
{{ include "kodus-common.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kodus
{{- with .Values.global.labels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels for a specific service.
Expects a dict with .root (top-level context) and .serviceName.
*/}}
{{- define "kodus-common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kodus-common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service-specific selector labels.
Call with: include "kodus-common.serviceSelectorLabels" (dict "root" . "serviceName" $name)
*/}}
{{- define "kodus-common.serviceSelectorLabels" -}}
app.kubernetes.io/name: {{ .serviceName }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: kodus
{{- end }}

{{/*
Service-specific labels (full set).
Call with: include "kodus-common.serviceLabels" (dict "root" . "serviceName" $name)
*/}}
{{- define "kodus-common.serviceLabels" -}}
{{ include "kodus-common.serviceSelectorLabels" . }}
helm.sh/chart: {{ include "kodus-common.chart" .root }}
{{- if .root.Chart.AppVersion }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- with .root.Values.global.labels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "kodus-common.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kodus-common.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image tag validation — fails if tag is empty and no digest is set.
Call with: include "kodus-common.validateImageTag" (dict "svcName" $name "image" $svc.image)
*/}}
{{- define "kodus-common.validateImageTag" -}}
{{- if and (not .image.tag) (not .image.digest) }}
{{- fail (printf "ERROR: services.%s.image.tag is required. Set a pinned tag (e.g., '2.1.0') or use image.digest for SHA pinning. Do NOT use 'latest' in production." .svcName) }}
{{- end }}
{{- end }}

{{/*
Full image reference (repo:tag or repo@digest).
Call with: include "kodus-common.imageRef" $svc.image
*/}}
{{- define "kodus-common.imageRef" -}}
{{- if .digest }}
{{- printf "%s@%s" .repository .digest }}
{{- else }}
{{- printf "%s:%s" .repository .tag }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus-common/templates/_helpers.tpl
git commit -m "feat(helm): add kodus-common helpers (labels, naming, image validation)"
```

### Task 3: Create _security.tpl

**Files:**
- Create: `charts/kodus-common/templates/_security.tpl`

Shared security context templates used by both charts.

- [ ] **Step 1: Write _security.tpl**

```yaml
{{/*
Pod security context — SOC 2 hardened defaults.
*/}}
{{- define "kodus-common.podSecurityContext" -}}
runAsNonRoot: true
fsGroup: {{ .Values.podSecurityContext.fsGroup | default 1001 }}
seccompProfile:
  type: {{ .Values.podSecurityContext.seccompProfile.type | default "RuntimeDefault" }}
{{- end }}

{{/*
Container security context — SOC 2 hardened defaults.
*/}}
{{- define "kodus-common.containerSecurityContext" -}}
runAsNonRoot: true
readOnlyRootFilesystem: {{ .Values.containerSecurityContext.readOnlyRootFilesystem | default true }}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
{{- end }}

{{/*
Tmp volume mount + volume (for readOnlyRootFilesystem).
*/}}
{{- define "kodus-common.tmpVolumeMount" -}}
- name: tmp
  mountPath: /tmp
{{- end }}

{{- define "kodus-common.tmpVolume" -}}
- name: tmp
  emptyDir:
    sizeLimit: 100Mi
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus-common/templates/_security.tpl
git commit -m "feat(helm): add kodus-common security context templates"
```

### Task 4: Create _env.tpl

**Files:**
- Create: `charts/kodus-common/templates/_env.tpl`

Shared env var block construction for database connections, RabbitMQ, and credential-bearing env vars that must be built in the pod spec (not ConfigMap).

- [ ] **Step 1: Write _env.tpl**

```yaml
{{/*
Database connection env vars — constructed from sub-chart or external values.
Returns env: entries with valueFrom for secrets and value for config.
Call with top-level context.
*/}}
{{- define "kodus-common.dbEnv" -}}
{{- if .Values.postgresql.enabled }}
- name: API_PG_DB_HOST
  value: {{ printf "%s-postgresql" .Release.Name }}
- name: API_PG_DB_PORT
  value: "5432"
- name: API_PG_DB_USERNAME
  value: {{ .Values.postgresql.auth.username | quote }}
- name: API_PG_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.postgresql.auth.existingSecret }}{{ .Values.postgresql.auth.existingSecret }}{{ else }}{{ printf "%s-postgresql" .Release.Name }}{{ end }}
      key: password
- name: API_PG_DB_DATABASE
  value: {{ .Values.postgresql.auth.database | quote }}
{{- else }}
- name: API_PG_DB_HOST
  value: {{ .Values.externalPostgresql.host | quote }}
- name: API_PG_DB_PORT
  value: {{ .Values.externalPostgresql.port | default 5432 | quote }}
- name: API_PG_DB_USERNAME
  value: {{ .Values.externalPostgresql.username | quote }}
- name: API_PG_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.externalPostgresql.existingSecret }}{{ .Values.externalPostgresql.existingSecret }}{{ else }}{{ printf "%s-external-pg" .Release.Name }}{{ end }}
      key: password
- name: API_PG_DB_DATABASE
  value: {{ .Values.externalPostgresql.database | quote }}
{{- end }}
{{- if .Values.mongodb.enabled }}
- name: API_MG_DB_HOST
  value: {{ printf "%s-mongodb" .Release.Name }}
- name: API_MG_DB_PORT
  value: "27017"
- name: API_MG_DB_USERNAME
  value: {{ .Values.mongodb.auth.rootUsername | quote }}
- name: API_MG_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.mongodb.auth.existingSecret }}{{ .Values.mongodb.auth.existingSecret }}{{ else }}{{ printf "%s-mongodb" .Release.Name }}{{ end }}
      key: mongodb-root-password
- name: API_MG_DB_DATABASE
  value: {{ index .Values.mongodb.auth.databases 0 | quote }}
{{- else }}
- name: API_MG_DB_HOST
  value: {{ .Values.externalMongodb.host | quote }}
- name: API_MG_DB_PORT
  value: {{ .Values.externalMongodb.port | default 27017 | quote }}
- name: API_MG_DB_USERNAME
  value: {{ .Values.externalMongodb.username | quote }}
- name: API_MG_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.externalMongodb.existingSecret }}{{ .Values.externalMongodb.existingSecret }}{{ else }}{{ printf "%s-external-mg" .Release.Name }}{{ end }}
      key: password
- name: API_MG_DB_DATABASE
  value: {{ .Values.externalMongodb.database | quote }}
{{- end }}
{{- end }}

{{/*
RabbitMQ connection env vars.
*/}}
{{- define "kodus-common.rabbitmqEnv" -}}
{{- if .Values.rabbitmq.enabled }}
- name: RABBITMQ_USER
  value: {{ .Values.rabbitmq.auth.username | quote }}
- name: RABBITMQ_PASS
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.rabbitmq.auth.existingPasswordSecret }}{{ .Values.rabbitmq.auth.existingPasswordSecret }}{{ else }}{{ printf "%s-rabbitmq" .Release.Name }}{{ end }}
      key: rabbitmq-password
- name: API_RABBITMQ_URI
  value: "amqp://$(RABBITMQ_USER):$(RABBITMQ_PASS)@{{ .Release.Name }}-rabbitmq:5672/kodus-ai"
- name: RABBIT_URL
  value: "amqp://$(RABBITMQ_USER):$(RABBITMQ_PASS)@{{ .Release.Name }}-rabbitmq:5672/kodus-ai"
{{- else }}
- name: API_RABBITMQ_URI
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.externalRabbitmq.existingSecret }}{{ .Values.externalRabbitmq.existingSecret }}{{ else }}{{ printf "%s-external-rmq" .Release.Name }}{{ end }}
      key: uri
- name: RABBIT_URL
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.externalRabbitmq.existingSecret }}{{ .Values.externalRabbitmq.existingSecret }}{{ else }}{{ printf "%s-external-rmq" .Release.Name }}{{ end }}
      key: uri
{{- end }}
{{- end }}

{{/*
App secrets env vars — from existingSecret or inline secret.
*/}}
{{- define "kodus-common.appSecretsEnv" -}}
{{- $secretName := default (printf "%s-secrets" .Release.Name) .Values.global.existingSecret -}}
{{- range $key := list "API_JWT_SECRET" "API_JWT_REFRESHSECRET" "WEB_NEXTAUTH_SECRET" "WEB_JWT_SECRET_KEY" "API_CRYPTO_KEY" "CODE_MANAGEMENT_SECRET" "CODE_MANAGEMENT_WEBHOOK_TOKEN" "API_OPEN_AI_API_KEY" "API_OPENAI_FORCE_BASE_URL" "API_LLM_PROVIDER_MODEL" "API_MORPHLLM_API_KEY" "API_E2B_KEY" "API_MCP_MANAGER_JWT_SECRET" "API_MCP_MANAGER_ENCRYPTION_SECRET" "API_MCP_MANAGER_COMPOSIO_API_KEY" }}
- name: {{ $key }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $key }}
      optional: true
{{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus-common/templates/_env.tpl
git commit -m "feat(helm): add kodus-common env var templates (db, rabbitmq, secrets)"
```

### Task 5: Create _pod.tpl

**Files:**
- Create: `charts/kodus-common/templates/_pod.tpl`

Shared PodSpec fragments for probes, image pull, etc.

- [ ] **Step 1: Write _pod.tpl**

```yaml
{{/*
Probes for a service.
Call with: include "kodus-common.probes" (dict "svc" $svc "defaultProbes" .Values.defaultProbes)
*/}}
{{- define "kodus-common.probes" -}}
{{- if eq (default "http" .svc.probes.type) "exec" }}
startupProbe:
  exec:
    command: {{ .svc.probes.command | toJson }}
  failureThreshold: 30
  periodSeconds: 5
livenessProbe:
  exec:
    command: {{ .svc.probes.command | toJson }}
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  exec:
    command: {{ .svc.probes.command | toJson }}
  initialDelaySeconds: 10
  periodSeconds: 5
{{- else }}
startupProbe:
  httpGet:
    path: {{ .svc.probes.path }}
    port: http
  failureThreshold: 30
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: {{ .svc.probes.path }}
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: {{ .svc.probes.path }}
    port: http
  initialDelaySeconds: 10
  periodSeconds: 5
{{- end }}
{{- end }}

{{/*
Image pull secrets block.
*/}}
{{- define "kodus-common.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus-common/templates/_pod.tpl
git commit -m "feat(helm): add kodus-common pod templates (probes, imagePullSecrets)"
```

---

## Chunk 2: Kubernetes Chart (kodus) — Scaffold & Values

### Task 6: Create kodus Chart.yaml with dependencies

**Files:**
- Create: `charts/kodus/Chart.yaml`

- [ ] **Step 1: Write Chart.yaml**

```yaml
apiVersion: v2
name: kodus
description: Deploy Kodus AI on Kubernetes
type: application
version: 0.1.0
appVersion: "2.0.0"
keywords:
  - kodus
  - ai
  - code-review
home: https://kodus.io
sources:
  - https://github.com/kodustech/kodus-installer
maintainers:
  - name: Kodus Team
    email: support@kodus.io
dependencies:
  - name: postgresql
    version: "18.5.6"
    repository: https://charts.bitnami.com/bitnami
    condition: postgresql.enabled
  - name: mongodb
    version: "18.6.11"
    repository: https://charts.bitnami.com/bitnami
    condition: mongodb.enabled
  - name: rabbitmq
    version: "16.0.14"
    repository: https://charts.bitnami.com/bitnami
    condition: rabbitmq.enabled
  - name: kodus-common
    version: "0.1.0"
    repository: "file://../kodus-common"
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/Chart.yaml
git commit -m "feat(helm): add kodus chart scaffold with bitnami dependencies"
```

### Task 7: Create values.yaml (production-hardened)

**Files:**
- Create: `charts/kodus/values.yaml`

This is the largest single file. It contains ALL configuration values with SOC 2 hardened defaults. Refer to the spec sections: Services, Image Pull, Migrations, ConfigMap, Secrets, RBAC, Networking, NetworkPolicy, Security, Resource Quotas, Probes, Backup, HPA, PDB, sub-chart overrides.

- [ ] **Step 1: Write values.yaml**

Write the complete values.yaml following every section of the spec. Key points:
- All `image.tag` fields default to `""` (REQUIRED)
- `image.pullPolicy: Always`
- `ingress.tls.enabled: true`
- `networkPolicy.enabled: true`
- `autoscaling.enabled: true`
- `pdb.enabled: true`
- `containerSecurityContext.readOnlyRootFilesystem: true`
- All secrets default to `""` (inline disabled)
- PostgreSQL image override to `pgvector/pgvector:0.8.2-pg16`
- RabbitMQ `communityPlugins` + `extraPlugins` + lifecycle vhost creation
- `global.labels` with compliance labels
- `global.config` with ALL env vars from the spec's ConfigMap section
- `global.secrets` with ALL secret keys from the spec's Secrets section

The full values.yaml content should match the spec exactly. This file will be ~400 lines.

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/values.yaml
git commit -m "feat(helm): add kodus values.yaml with SOC 2 hardened defaults"
```

### Task 8: Create values-dev.yaml

**Files:**
- Create: `charts/kodus/values-dev.yaml`

- [ ] **Step 1: Write values-dev.yaml**

Copy the `values-dev.yaml` content exactly from the spec's "values-dev.yaml" section (lines 824-898). This overlay relaxes all SOC 2 hardening for local development.

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/values-dev.yaml
git commit -m "feat(helm): add kodus values-dev.yaml overlay"
```

### Task 9: Create values-example.yaml

**Files:**
- Create: `charts/kodus/values-example.yaml`

- [ ] **Step 1: Write values-example.yaml**

A commented copy of values.yaml with guidance. Focus on the REQUIRED fields and common customization points. Keep comments concise.

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/values-example.yaml
git commit -m "feat(helm): add kodus values-example.yaml with inline docs"
```

---

## Chunk 3: Kubernetes Chart (kodus) — Templates

### Task 10: Create _helpers.tpl for kodus chart

**Files:**
- Create: `charts/kodus/templates/_helpers.tpl`

- [ ] **Step 1: Write _helpers.tpl**

This file wraps `kodus-common` helpers and adds chart-specific helpers:

```yaml
{{/* Wrap common helpers */}}
{{- define "kodus.fullname" -}}
{{ include "kodus-common.fullname" . }}
{{- end }}

{{- define "kodus.labels" -}}
{{ include "kodus-common.labels" . }}
{{- end }}

{{- define "kodus.serviceAccountName" -}}
{{ include "kodus-common.serviceAccountName" . }}
{{- end }}

{{/* Service fullname: release-name-serviceName */}}
{{- define "kodus.serviceFullname" -}}
{{- printf "%s-%s" .root.Release.Name .serviceName | trunc 63 | trimSuffix "-" }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/_helpers.tpl
git commit -m "feat(helm): add kodus chart _helpers.tpl"
```

### Task 11: Create configmap.yaml

**Files:**
- Create: `charts/kodus/templates/configmap.yaml`

- [ ] **Step 1: Write configmap.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "kodus.fullname" . }}-config
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
data:
  {{- range $key, $value := .Values.global.config }}
  {{ $key }}: {{ tpl ($value | toString) $ | quote }}
  {{- end }}
```

Uses `tpl` to resolve `{{ .Release.Name }}` references inside config values.

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/configmap.yaml
git commit -m "feat(helm): add kodus configmap template"
```

### Task 12: Create secrets.yaml

**Files:**
- Create: `charts/kodus/templates/secrets.yaml`

- [ ] **Step 1: Write secrets.yaml**

```yaml
{{- if and (not .Values.global.existingSecret) (not .Values.global.externalSecrets.enabled) }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "kodus.fullname" . }}-secrets
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
type: Opaque
stringData:
  {{- range $key, $value := .Values.global.secrets }}
  {{- if $value }}
  {{ $key }}: {{ $value | quote }}
  {{- end }}
  {{- end }}
{{- end }}
---
{{/* External secrets for external DB passwords when not using sub-charts */}}
{{- if and (not .Values.postgresql.enabled) (not .Values.externalPostgresql.existingSecret) }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "kodus.fullname" . }}-external-pg
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
type: Opaque
stringData:
  password: {{ .Values.externalPostgresql.password | quote }}
{{- end }}
---
{{- if and (not .Values.mongodb.enabled) (not .Values.externalMongodb.existingSecret) }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "kodus.fullname" . }}-external-mg
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
type: Opaque
stringData:
  password: {{ .Values.externalMongodb.password | quote }}
{{- end }}
---
{{- if and (not .Values.rabbitmq.enabled) (not .Values.externalRabbitmq.existingSecret) }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "kodus.fullname" . }}-external-rmq
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
type: Opaque
stringData:
  uri: {{ .Values.externalRabbitmq.uri | quote }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/secrets.yaml
git commit -m "feat(helm): add kodus secrets template (inline + external)"
```

### Task 12b: Create externalsecret.yaml (ExternalSecret CRD support)

**Files:**
- Create: `charts/kodus/templates/externalsecret.yaml`

When `global.externalSecrets.enabled: true`, generate `ExternalSecret` resources instead of native Secrets.

- [ ] **Step 1: Write externalsecret.yaml**

```yaml
{{- if .Values.global.externalSecrets.enabled }}
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ include "kodus.fullname" . }}-secrets
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
spec:
  refreshInterval: {{ .Values.global.externalSecrets.refreshInterval | default "1h" }}
  secretStoreRef:
    name: {{ .Values.global.externalSecrets.store }}
    kind: {{ .Values.global.externalSecrets.storeKind | default "SecretStore" }}
  target:
    name: {{ include "kodus.fullname" . }}-secrets
    creationPolicy: Owner
  data:
    {{- range $key := list "API_JWT_SECRET" "API_JWT_REFRESHSECRET" "WEB_NEXTAUTH_SECRET" "WEB_JWT_SECRET_KEY" "API_CRYPTO_KEY" "CODE_MANAGEMENT_SECRET" "CODE_MANAGEMENT_WEBHOOK_TOKEN" "API_OPEN_AI_API_KEY" "API_OPENAI_FORCE_BASE_URL" "API_LLM_PROVIDER_MODEL" "API_MORPHLLM_API_KEY" "API_E2B_KEY" "API_MCP_MANAGER_JWT_SECRET" "API_MCP_MANAGER_ENCRYPTION_SECRET" "API_MCP_MANAGER_COMPOSIO_API_KEY" }}
    - secretKey: {{ $key }}
      remoteRef:
        key: {{ printf "kodus/%s" $key }}
    {{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/externalsecret.yaml
git commit -m "feat(helm): add ExternalSecret CRD template for external-secrets operator"
```

### Task 13: Create serviceaccount.yaml, role.yaml, rolebinding.yaml

**Files:**
- Create: `charts/kodus/templates/serviceaccount.yaml`
- Create: `charts/kodus/templates/role.yaml`
- Create: `charts/kodus/templates/rolebinding.yaml`

- [ ] **Step 1: Write serviceaccount.yaml**

```yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "kodus.serviceAccountName" . }}
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
  {{- with .Values.serviceAccount.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
automountServiceAccountToken: false
{{- end }}
```

- [ ] **Step 2: Write role.yaml**

```yaml
{{- if .Values.rbac.create }}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ include "kodus.fullname" . }}
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
rules:
  {{- toYaml .Values.rbac.rules | nindent 2 }}
{{- end }}
```

- [ ] **Step 3: Write rolebinding.yaml**

```yaml
{{- if .Values.rbac.create }}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ include "kodus.fullname" . }}
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ include "kodus.fullname" . }}
subjects:
  - kind: ServiceAccount
    name: {{ include "kodus.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
{{- end }}
```

- [ ] **Step 4: Commit**

```bash
git add charts/kodus/templates/serviceaccount.yaml charts/kodus/templates/role.yaml charts/kodus/templates/rolebinding.yaml
git commit -m "feat(helm): add kodus RBAC templates (SA, Role, RoleBinding)"
```

### Task 14: Create deployment.yaml (generic iterable)

**Files:**
- Create: `charts/kodus/templates/deployment.yaml`

This is the core template. It iterates over `.Values.services` and generates one Deployment per enabled service.

- [ ] **Step 1: Write deployment.yaml**

```yaml
{{- range $name, $svc := .Values.services }}
{{- if ne (toString (default true $svc.enabled)) "false" }}
{{- $ctx := dict "root" $ "serviceName" $name "svc" $svc }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "kodus.serviceFullname" $ctx }}
  labels:
    {{- include "kodus-common.serviceLabels" (dict "root" $ "serviceName" $name) | nindent 4 }}
spec:
  {{- if not $.Values.autoscaling.enabled }}
  replicas: {{ $svc.replicas | default 1 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "kodus-common.serviceSelectorLabels" (dict "root" $ "serviceName" $name) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "kodus-common.serviceSelectorLabels" (dict "root" $ "serviceName" $name) | nindent 8 }}
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") $ | sha256sum }}
        checksum/secret: {{ include (print $.Template.BasePath "/secrets.yaml") $ | sha256sum }}
    spec:
      serviceAccountName: {{ include "kodus-common.serviceAccountName" $ }}
      {{- include "kodus-common.imagePullSecrets" $ | nindent 6 }}
      securityContext:
        {{- include "kodus-common.podSecurityContext" $ | nindent 8 }}
      containers:
        - name: {{ $name }}
          image: {{ include "kodus-common.imageRef" $svc.image }}
          imagePullPolicy: {{ $.Values.image.pullPolicy | default "Always" }}
          {{- if $svc.port }}
          ports:
            - name: http
              containerPort: {{ $svc.port }}
              protocol: TCP
          {{- end }}
          securityContext:
            {{- include "kodus-common.containerSecurityContext" $ | nindent 12 }}
          envFrom:
            - configMapRef:
                name: {{ include "kodus-common.fullname" $ }}-config
          env:
            {{- include "kodus-common.dbEnv" $ | nindent 12 }}
            {{- include "kodus-common.rabbitmqEnv" $ | nindent 12 }}
            {{- include "kodus-common.appSecretsEnv" $ | nindent 12 }}
            {{- with $svc.env }}
            {{- range $k, $v := . }}
            - name: {{ $k }}
              value: {{ $v | quote }}
            {{- end }}
            {{- end }}
          {{- include "kodus-common.probes" (dict "svc" $svc "defaultProbes" $.Values.defaultProbes) | nindent 10 }}
          resources:
            {{- toYaml $svc.resources | nindent 12 }}
          volumeMounts:
            {{- include "kodus-common.tmpVolumeMount" $ | nindent 12 }}
      volumes:
        {{- include "kodus-common.tmpVolume" $ | nindent 8 }}
      {{- with $.Values.topologySpreadConstraints }}
      {{- if .enabled }}
      topologySpreadConstraints:
        - maxSkew: {{ .maxSkew | default 1 }}
          topologyKey: {{ .topologyKey | default "kubernetes.io/hostname" }}
          whenUnsatisfiable: {{ .whenUnsatisfiable | default "DoNotSchedule" }}
          labelSelector:
            matchLabels:
              {{- include "kodus-common.serviceSelectorLabels" (dict "root" $ "serviceName" $name) | nindent 14 }}
      {{- end }}
      {{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Validate with `helm template` (dry run)**

```bash
cd charts/kodus
helm dependency update
helm template test . -f values-dev.yaml 2>&1 | head -100
```

Expected: YAML output showing Deployment resources for each service (may have errors if values-dev.yaml references aren't all set yet — that's OK at this stage).

- [ ] **Step 3: Commit**

```bash
git add charts/kodus/templates/deployment.yaml
git commit -m "feat(helm): add kodus deployment template (generic iterable)"
```

### Task 15: Create service.yaml

**Files:**
- Create: `charts/kodus/templates/service.yaml`

- [ ] **Step 1: Write service.yaml**

```yaml
{{- range $name, $svc := .Values.services }}
{{- if and (ne (toString (default true $svc.enabled)) "false") $svc.port }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ printf "%s-%s" $.Release.Name $name | trunc 63 | trimSuffix "-" }}
  labels:
    {{- include "kodus-common.serviceLabels" (dict "root" $ "serviceName" $name) | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - port: {{ $svc.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "kodus-common.serviceSelectorLabels" (dict "root" $ "serviceName" $name) | nindent 4 }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/service.yaml
git commit -m "feat(helm): add kodus service template"
```

### Task 16: Create ingress.yaml

**Files:**
- Create: `charts/kodus/templates/ingress.yaml`

- [ ] **Step 1: Write ingress.yaml**

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "kodus.fullname" . }}
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if .Values.ingress.className }}
  ingressClassName: {{ .Values.ingress.className }}
  {{- end }}
  {{- if .Values.ingress.tls.enabled }}
  tls:
    - hosts:
        {{- range $name, $host := .Values.ingress.hosts }}
        - {{ $host.host }}
        {{- end }}
      {{- if .Values.ingress.tls.secretName }}
      secretName: {{ .Values.ingress.tls.secretName }}
      {{- end }}
  {{- end }}
  rules:
    {{- range $name, $host := .Values.ingress.hosts }}
    - host: {{ $host.host }}
      http:
        paths:
          - path: {{ $host.path | default "/" }}
            pathType: Prefix
            backend:
              service:
                name: {{ printf "%s-%s" $.Release.Name $host.serviceName | trunc 63 | trimSuffix "-" }}
                port:
                  name: http
    {{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/ingress.yaml
git commit -m "feat(helm): add kodus ingress template"
```

### Task 17: Create migration-job.yaml

**Files:**
- Create: `charts/kodus/templates/migration-job.yaml`

- [ ] **Step 1: Write migration-job.yaml**

```yaml
{{- if .Values.migrations.enabled }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "kodus.fullname" . }}-migrations
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
  annotations:
    "helm.sh/hook": pre-install,pre-upgrade
    "helm.sh/hook-weight": "0"
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        {{- include "kodus-common.serviceSelectorLabels" (dict "root" . "serviceName" "migrations") | nindent 8 }}
    spec:
      serviceAccountName: {{ include "kodus-common.serviceAccountName" . }}
      {{- include "kodus-common.imagePullSecrets" . | nindent 6 }}
      restartPolicy: OnFailure
      securityContext:
        {{- include "kodus-common.podSecurityContext" . | nindent 8 }}
      initContainers:
        - name: wait-for-postgres
          image: busybox:1.37.0
          command:
            - sh
            - -c
            - |
              {{- if .Values.postgresql.enabled }}
              until nc -z {{ .Release.Name }}-postgresql 5432; do echo "Waiting for PostgreSQL..."; sleep 2; done
              {{- else }}
              until nc -z {{ .Values.externalPostgresql.host }} {{ .Values.externalPostgresql.port | default 5432 }}; do echo "Waiting for PostgreSQL..."; sleep 2; done
              {{- end }}
          securityContext:
            {{- include "kodus-common.containerSecurityContext" . | nindent 12 }}
      containers:
        - name: migrations
          image: {{ include "kodus-common.imageRef" .Values.migrations.image }}
          imagePullPolicy: {{ .Values.image.pullPolicy | default "Always" }}
          securityContext:
            {{- include "kodus-common.containerSecurityContext" . | nindent 12 }}
          envFrom:
            - configMapRef:
                name: {{ include "kodus-common.fullname" . }}-config
          env:
            - name: RUN_MIGRATIONS
              value: {{ .Values.migrations.env.RUN_MIGRATIONS | quote }}
            - name: RUN_SEEDS
              value: {{ .Values.migrations.env.RUN_SEEDS | quote }}
            {{- include "kodus-common.dbEnv" . | nindent 12 }}
            {{- include "kodus-common.rabbitmqEnv" . | nindent 12 }}
            {{- include "kodus-common.appSecretsEnv" . | nindent 12 }}
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          volumeMounts:
            {{- include "kodus-common.tmpVolumeMount" . | nindent 12 }}
      volumes:
        {{- include "kodus-common.tmpVolume" . | nindent 8 }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/migration-job.yaml
git commit -m "feat(helm): add kodus migration job template (helm hook)"
```

### Task 18: Create networkpolicy.yaml

**Files:**
- Create: `charts/kodus/templates/networkpolicy.yaml`

- [ ] **Step 1: Write networkpolicy.yaml**

```yaml
{{- if .Values.networkPolicy.enabled }}
{{/* Default deny all ingress */}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "kodus.fullname" . }}-default-deny
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/part-of: kodus
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress:
    - {}  {{/* Allow all egress (DNS, external APIs, etc.) */}}
---
{{/* Allow ingress controller → web, api, webhooks */}}
{{- range $name := list "web" "api" "webhooks" }}
{{- $svc := index $.Values.services $name }}
{{- if and (ne (toString (default true $svc.enabled)) "false") $svc.port }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ printf "%s-%s-ingress" (include "kodus.fullname" $) $name }}
  labels:
    {{- include "kodus.labels" $ | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "kodus-common.serviceSelectorLabels" (dict "root" $ "serviceName" $name) | nindent 6 }}
  policyTypes:
    - Ingress
  ingress:
    - from:
        {{- with $.Values.networkPolicy.ingressControllerLabels }}
        - podSelector:
            matchLabels:
              {{- toYaml . | nindent 14 }}
        {{- end }}
        - namespaceSelector: {}  {{/* Allow from ingress controller namespace */}}
      ports:
        - port: {{ $svc.port }}
          protocol: TCP
---
{{- end }}
{{- end }}
{{/* Allow web → api, webhooks */}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "kodus.fullname" . }}-api-from-web
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: api
      app.kubernetes.io/instance: {{ .Release.Name }}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: web
              app.kubernetes.io/instance: {{ .Release.Name }}
      ports:
        - port: {{ .Values.services.api.port }}
---
{{/* Allow api → service-ast, mcp-manager (inter-service) */}}
{{- range $target := list "service-ast" "mcp-manager" }}
{{- $targetSvc := index $.Values.services $target }}
{{- if and (ne (toString (default true $targetSvc.enabled)) "false") $targetSvc.port }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ printf "%s-%s-from-api" (include "kodus.fullname" $) $target }}
  labels:
    {{- include "kodus.labels" $ | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "kodus-common.serviceSelectorLabels" (dict "root" $ "serviceName" $target) | nindent 6 }}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: api
              app.kubernetes.io/instance: {{ $.Release.Name }}
      ports:
        - port: {{ $targetSvc.port }}
---
{{- end }}
{{- end }}
{{- end }}
```

Note: This covers the core policies. The implementer should add equivalent policies for worker, webhooks, and service-ast egress to database/rabbitmq pods following the same pattern.

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/networkpolicy.yaml
git commit -m "feat(helm): add kodus networkpolicy template"
```

### Task 19: Create hpa.yaml, pdb.yaml, resourcequota.yaml

**Files:**
- Create: `charts/kodus/templates/hpa.yaml`
- Create: `charts/kodus/templates/pdb.yaml`
- Create: `charts/kodus/templates/resourcequota.yaml`

- [ ] **Step 1: Write hpa.yaml**

```yaml
{{- if .Values.autoscaling.enabled }}
{{- range $name, $svc := .Values.services }}
{{- if ne (toString (default true $svc.enabled)) "false" }}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ printf "%s-%s" $.Release.Name $name | trunc 63 | trimSuffix "-" }}
  labels:
    {{- include "kodus-common.serviceLabels" (dict "root" $ "serviceName" $name) | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ printf "%s-%s" $.Release.Name $name | trunc 63 | trimSuffix "-" }}
  minReplicas: {{ $.Values.autoscaling.minReplicas | default 2 }}
  maxReplicas: {{ $.Values.autoscaling.maxReplicas | default 10 }}
  metrics:
    {{- if $.Values.autoscaling.targetCPU }}
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ $.Values.autoscaling.targetCPU }}
    {{- end }}
    {{- if $.Values.autoscaling.targetMemory }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ $.Values.autoscaling.targetMemory }}
    {{- end }}
{{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 2: Write pdb.yaml**

```yaml
{{- if .Values.pdb.enabled }}
{{- range $name, $svc := .Values.services }}
{{- if ne (toString (default true $svc.enabled)) "false" }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ printf "%s-%s" $.Release.Name $name | trunc 63 | trimSuffix "-" }}
  labels:
    {{- include "kodus-common.serviceLabels" (dict "root" $ "serviceName" $name) | nindent 4 }}
spec:
  minAvailable: {{ $.Values.pdb.minAvailable | default 1 }}
  selector:
    matchLabels:
      {{- include "kodus-common.serviceSelectorLabels" (dict "root" $ "serviceName" $name) | nindent 6 }}
{{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 3: Write resourcequota.yaml**

```yaml
{{- if .Values.resourceQuota.enabled }}
apiVersion: v1
kind: ResourceQuota
metadata:
  name: {{ include "kodus.fullname" . }}
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
spec:
  hard:
    {{- toYaml .Values.resourceQuota.hard | nindent 4 }}
{{- end }}
```

- [ ] **Step 4: Commit**

```bash
git add charts/kodus/templates/hpa.yaml charts/kodus/templates/pdb.yaml charts/kodus/templates/resourcequota.yaml
git commit -m "feat(helm): add kodus HPA, PDB, ResourceQuota templates"
```

### Task 19b: Create backup-cronjob.yaml (VolumeSnapshot)

**Files:**
- Create: `charts/kodus/templates/backup-cronjob.yaml`

Optional CronJob that creates VolumeSnapshots of PostgreSQL and MongoDB PVCs.

- [ ] **Step 1: Write backup-cronjob.yaml**

```yaml
{{- if .Values.backup.enabled }}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "kodus.fullname" . }}-backup
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
spec:
  schedule: {{ .Values.backup.schedule | default "0 2 * * *" | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: {{ .Values.backup.retention | default 7 }}
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: {{ include "kodus-common.serviceAccountName" . }}
          restartPolicy: OnFailure
          containers:
            - name: snapshot
              image: bitnami/kubectl:latest
              command:
                - /bin/sh
                - -c
                - |
                  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
                  {{- if .Values.postgresql.enabled }}
                  cat <<SNAP | kubectl apply -f -
                  apiVersion: snapshot.storage.k8s.io/v1
                  kind: VolumeSnapshot
                  metadata:
                    name: {{ .Release.Name }}-pg-${TIMESTAMP}
                    namespace: {{ .Release.Namespace }}
                  spec:
                    volumeSnapshotClassName: {{ .Values.backup.snapshotClassName }}
                    source:
                      persistentVolumeClaimName: data-{{ .Release.Name }}-postgresql-0
                  SNAP
                  {{- end }}
                  {{- if .Values.mongodb.enabled }}
                  cat <<SNAP | kubectl apply -f -
                  apiVersion: snapshot.storage.k8s.io/v1
                  kind: VolumeSnapshot
                  metadata:
                    name: {{ .Release.Name }}-mg-${TIMESTAMP}
                    namespace: {{ .Release.Namespace }}
                  spec:
                    volumeSnapshotClassName: {{ .Values.backup.snapshotClassName }}
                    source:
                      persistentVolumeClaimName: datadir-{{ .Release.Name }}-mongodb-0
                  SNAP
                  {{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/backup-cronjob.yaml
git commit -m "feat(helm): add kodus backup CronJob template (VolumeSnapshot)"
```

### Task 20: Create NOTES.txt

**Files:**
- Create: `charts/kodus/templates/NOTES.txt`

- [ ] **Step 1: Write NOTES.txt**

Use the exact content from the spec's "NOTES.txt Content" section (lines 991-1017), including the SOC 2 checklist.

- [ ] **Step 2: Commit**

```bash
git add charts/kodus/templates/NOTES.txt
git commit -m "feat(helm): add kodus NOTES.txt with SOC 2 checklist"
```

### Task 21: Validate the kodus chart

- [ ] **Step 1: Run helm dependency update**

```bash
cd charts/kodus
helm dependency update
```

Expected: Dependencies downloaded to `charts/` subdirectory.

- [ ] **Step 2: Run helm lint**

```bash
helm lint . -f values-dev.yaml
```

Expected: No errors. Warnings about empty values are acceptable at this stage.

- [ ] **Step 3: Run helm template dry run**

```bash
helm template test . -f values-dev.yaml --debug 2>&1 | head -200
```

Expected: Valid YAML output with all resources rendered.

- [ ] **Step 4: Fix any lint/template errors**

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "fix(helm): resolve lint and template errors in kodus chart"
```

---

## Chunk 4: OpenShift Chart (kodus-openshift)

### Task 22: Create kodus-openshift Chart.yaml

**Files:**
- Create: `charts/kodus-openshift/Chart.yaml`

- [ ] **Step 1: Write Chart.yaml**

Same as kodus chart but with `name: kodus-openshift` and `description: Deploy Kodus AI on OpenShift`.

- [ ] **Step 2: Commit**

```bash
git add charts/kodus-openshift/Chart.yaml
git commit -m "feat(helm): add kodus-openshift chart scaffold"
```

### Task 23: Create values.yaml for OpenShift

**Files:**
- Create: `charts/kodus-openshift/values.yaml`

- [ ] **Step 1: Write values.yaml**

Copy kodus values.yaml as base, then apply these changes:
- Remove `ingress` section, replace with `route` section (from spec lines 557-574)
- Add `scc` section (from spec lines 657-661)
- Override sub-chart security contexts for OpenShift (spec lines 635-651):
  - `postgresql.primary.podSecurityContext.fsGroup: null`
  - `mongodb.podSecurityContext.fsGroup: null`
  - `rabbitmq.podSecurityContext.fsGroup: null`
  - All `volumePermissions.enabled: false`
- `podSecurityContext.fsGroup` should be `null` (not 1001)

- [ ] **Step 2: Create values-dev.yaml**

Copy kodus values-dev.yaml, replace `ingress.tls.enabled: false` with `route.tls.termination: edge`.

- [ ] **Step 3: Create values-example.yaml**

Similar to kodus version but with Route/SCC examples instead of Ingress.

- [ ] **Step 4: Commit**

```bash
git add charts/kodus-openshift/values.yaml charts/kodus-openshift/values-dev.yaml charts/kodus-openshift/values-example.yaml
git commit -m "feat(helm): add kodus-openshift values files with OpenShift defaults"
```

### Task 24: Copy shared templates from kodus chart

**Files:**
- Create: `charts/kodus-openshift/templates/_helpers.tpl`
- Create: `charts/kodus-openshift/templates/configmap.yaml`
- Create: `charts/kodus-openshift/templates/secrets.yaml`
- Create: `charts/kodus-openshift/templates/serviceaccount.yaml`
- Create: `charts/kodus-openshift/templates/role.yaml`
- Create: `charts/kodus-openshift/templates/rolebinding.yaml`
- Create: `charts/kodus-openshift/templates/deployment.yaml`
- Create: `charts/kodus-openshift/templates/service.yaml`
- Create: `charts/kodus-openshift/templates/networkpolicy.yaml`
- Create: `charts/kodus-openshift/templates/migration-job.yaml`
- Create: `charts/kodus-openshift/templates/hpa.yaml`
- Create: `charts/kodus-openshift/templates/pdb.yaml`
- Create: `charts/kodus-openshift/templates/resourcequota.yaml`
- Create: `charts/kodus-openshift/templates/externalsecret.yaml`
- Create: `charts/kodus-openshift/templates/backup-cronjob.yaml`
- Create: `charts/kodus-openshift/templates/NOTES.txt`

- [ ] **Step 1: Copy templates from kodus chart**

```bash
cp charts/kodus/templates/_helpers.tpl charts/kodus-openshift/templates/
cp charts/kodus/templates/configmap.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/secrets.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/serviceaccount.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/role.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/rolebinding.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/deployment.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/service.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/networkpolicy.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/migration-job.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/hpa.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/pdb.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/resourcequota.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/externalsecret.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/backup-cronjob.yaml charts/kodus-openshift/templates/
cp charts/kodus/templates/NOTES.txt charts/kodus-openshift/templates/
```

- [ ] **Step 2: Update NOTES.txt for OpenShift**

Replace the following in the copied NOTES.txt:
- `kubectl` → `oc`
- `kubectl get pods` → `oc get pods`
- `kubectl port-forward` → `oc port-forward`
- `kubectl logs` → `oc logs`
- Ingress host reference → Route host reference: `{{- if .Values.route.enabled }}` and `(index .Values.route.hosts "web").host`
- Add to SOC 2 checklist: `- [ ] SecurityContextConstraints applied`

- [ ] **Step 3: Commit**

```bash
git add charts/kodus-openshift/templates/
git commit -m "feat(helm): add shared templates to kodus-openshift chart"
```

### Task 25: Create route.yaml (OpenShift-specific)

**Files:**
- Create: `charts/kodus-openshift/templates/route.yaml`

- [ ] **Step 1: Write route.yaml**

```yaml
{{- if .Values.route.enabled }}
{{- range $name, $host := .Values.route.hosts }}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: {{ printf "%s-%s" $.Release.Name $name | trunc 63 | trimSuffix "-" }}
  labels:
    {{- include "kodus-common.serviceLabels" (dict "root" $ "serviceName" $name) | nindent 4 }}
spec:
  host: {{ $host.host }}
  {{- if $host.path }}
  path: {{ $host.path }}
  {{- end }}
  to:
    kind: Service
    name: {{ printf "%s-%s" $.Release.Name $host.serviceName | trunc 63 | trimSuffix "-" }}
    weight: 100
  port:
    targetPort: http
  tls:
    termination: {{ $.Values.route.tls.termination | default "edge" }}
    insecureEdgeTerminationPolicy: {{ $.Values.route.tls.insecureEdgePolicy | default "Redirect" }}
  wildcardPolicy: None
{{- end }}
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus-openshift/templates/route.yaml
git commit -m "feat(helm): add kodus-openshift route template"
```

### Task 26: Create scc.yaml (OpenShift-specific)

**Files:**
- Create: `charts/kodus-openshift/templates/scc.yaml`

- [ ] **Step 1: Write scc.yaml**

```yaml
{{- if .Values.scc.create }}
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: {{ .Values.scc.name | default (printf "%s-scc" (include "kodus.fullname" .)) }}
  labels:
    {{- include "kodus.labels" . | nindent 4 }}
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities: []
defaultAddCapabilities: []
fsGroup:
  type: RunAsAny
readOnlyRootFilesystem: true
requiredDropCapabilities:
  - ALL
runAsUser:
  type: MustRunAsNonRoot
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: RunAsAny
users:
  - system:serviceaccount:{{ .Release.Namespace }}:{{ include "kodus-common.serviceAccountName" . }}
volumes:
  - configMap
  - downwardAPI
  - emptyDir
  - persistentVolumeClaim
  - projected
  - secret
{{- end }}
```

- [ ] **Step 2: Commit**

```bash
git add charts/kodus-openshift/templates/scc.yaml
git commit -m "feat(helm): add kodus-openshift SCC template"
```

### Task 27: Validate the kodus-openshift chart

- [ ] **Step 1: Run helm dependency update**

```bash
cd charts/kodus-openshift
helm dependency update
```

- [ ] **Step 2: Run helm lint**

```bash
helm lint . -f values-dev.yaml
```

- [ ] **Step 3: Run helm template dry run**

```bash
helm template test . -f values-dev.yaml --debug 2>&1 | head -200
```

- [ ] **Step 4: Fix any lint/template errors**

- [ ] **Step 5: Commit fixes**

```bash
git add -A
git commit -m "fix(helm): resolve lint and template errors in kodus-openshift chart"
```

---

## Chunk 5: Documentation & Final Validation

### Task 28: Update README.md

**Files:**
- Modify: `readme.md`

- [ ] **Step 1: Add Kubernetes/OpenShift section to README**

Add a new section after the Docker Compose installation section:

```markdown
## Kubernetes / OpenShift

Helm charts are available for deploying Kodus on Kubernetes or OpenShift.

### Kubernetes

\`\`\`bash
cd charts/kodus
helm dependency update
helm install kodus . \
  -f values.yaml \
  --set global.existingSecret=kodus-credentials \
  --set ingress.hosts.web.host=kodus.mycompany.com \
  --set ingress.hosts.api.host=api.kodus.mycompany.com \
  -n kodus --create-namespace
\`\`\`

### OpenShift

\`\`\`bash
cd charts/kodus-openshift
helm dependency update
helm install kodus . \
  -f values.yaml \
  --set global.existingSecret=kodus-credentials \
  --set route.hosts.web.host=kodus.apps.cluster.mycompany.com \
  -n kodus --create-namespace
\`\`\`

### Development Mode

Both charts include a `values-dev.yaml` overlay with relaxed defaults:

\`\`\`bash
helm install kodus . -f values.yaml -f values-dev.yaml -n kodus-dev --create-namespace
\`\`\`

See `charts/kodus/values-example.yaml` for all configuration options.
```

- [ ] **Step 2: Commit**

```bash
git add readme.md
git commit -m "docs: add Kubernetes/OpenShift deployment section to README"
```

### Task 29: Final end-to-end validation

- [ ] **Step 1: Lint both charts**

```bash
cd charts/kodus && helm lint . -f values-dev.yaml
cd ../kodus-openshift && helm lint . -f values-dev.yaml
```

- [ ] **Step 2: Template both charts and verify output**

```bash
cd charts/kodus && helm template test . -f values-dev.yaml > /tmp/kodus-k8s.yaml
cd ../kodus-openshift && helm template test . -f values-dev.yaml > /tmp/kodus-openshift.yaml
```

- [ ] **Step 3: Verify resource count**

```bash
grep "^kind:" /tmp/kodus-k8s.yaml | sort | uniq -c
grep "^kind:" /tmp/kodus-openshift.yaml | sort | uniq -c
```

Expected for K8s: ConfigMap, Deployment (x5-6), HorizontalPodAutoscaler, Ingress, Job, NetworkPolicy, PodDisruptionBudget, ResourceQuota, Role, RoleBinding, Secret, Service (x5-6), ServiceAccount
Expected for OpenShift: Same minus Ingress, plus Route, SecurityContextConstraints

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "fix(helm): final validation fixes"
```
