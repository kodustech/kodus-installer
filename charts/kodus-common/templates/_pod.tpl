{{/*
Probes for a service. HTTP by default; exec for the workers (no HTTP endpoint —
they verify the RabbitMQ connection). Call with (dict "svc" $svc).

Design (deterministic, not machine-timing-dependent):
  - startupProbe absorbs the whole cold start with RETRIES (up to ~2.5min for
    Node init). Because it exists, K8s does NOT run liveness/readiness until it
    passes — so those carry NO initialDelaySeconds (that would only add a
    redundant post-startup delay).
  - livenessProbe uses the SHALLOW path and restarts only on sustained failure
    (failureThreshold 3). It must never depend on downstream deps.
  - readinessProbe may use a DEEPER path (app + RabbitMQ + Postgres); failing it
    just removes the pod from the Service, never restarts it.
  - exec probes shell out to `node -e` (~hundreds of ms to boot Node); the 1s
    default timeout would flap under CPU pressure, so exec uses timeoutSeconds 5.
*/}}
{{- define "kodus-common.probes" -}}
{{- if eq (default "http" .svc.probes.type) "exec" }}
startupProbe:
  exec:
    command: {{ .svc.probes.command | toJson }}
  periodSeconds: 5
  timeoutSeconds: 5
  failureThreshold: 30
livenessProbe:
  exec:
    command: {{ .svc.probes.command | toJson }}
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  exec:
    command: {{ .svc.probes.command | toJson }}
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
{{- else }}
startupProbe:
  httpGet:
    path: {{ .svc.probes.path }}
    port: http
  periodSeconds: 5
  timeoutSeconds: 8          {{/* generous for cold start — a Next.js SSR "/" can take >3s on first hit; only affects startup */}}
  failureThreshold: 30
livenessProbe:
  httpGet:
    path: {{ .svc.probes.path }}                                 {{/* shallow — liveness must not depend on downstream deps */}}
    port: http
  periodSeconds: 15
  timeoutSeconds: 3
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: {{ .svc.probes.readinessPath | default .svc.probes.path }}   {{/* deep when defined (app + RabbitMQ + Postgres); pulls a degraded pod from the Service */}}
    port: http
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3
{{- end }}
{{- end }}

{{/*
Image pull secrets block (top-level context).
*/}}
{{- define "kodus-common.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
initContainers that wait for the data dependencies to accept TCP connections
before the app container starts — prevents CrashLoopBackOff during the DB/queue
warm-up race. Call with root ctx.
*/}}
{{- define "kodus-common.waitForDeps" -}}
{{- $pgHost := "" }}{{- $pgPort := "5432" }}
{{- if eq .Values.postgres.mode "bundled" }}{{- $pgHost = printf "%s-postgres" .Release.Name }}
{{- else if eq .Values.postgres.mode "operator" }}{{- $pgHost = printf "%s-postgres-rw" .Release.Name }}
{{- else }}{{- $pgHost = .Values.postgres.external.host | toString }}{{- $pgPort = .Values.postgres.external.port | default 5432 | toString }}{{- end }}
{{- $mgHost := "" }}{{- $mgPort := "27017" }}
{{- if eq .Values.mongodb.mode "bundled" }}{{- $mgHost = printf "%s-mongodb" .Release.Name }}
{{- else if eq .Values.mongodb.mode "operator" }}{{- $mgHost = printf "%s-mongodb-svc" .Release.Name }}
{{- else }}{{- $mgHost = .Values.mongodb.external.host | toString }}{{- $mgPort = .Values.mongodb.external.port | default 27017 | toString }}{{- end }}
- name: wait-for-deps
  image: {{ include "kodus-common.regPrefix" . }}{{ .Values.waitForDeps.image | default "busybox:1.37.0" }}
  command:
    - sh
    - -c
    - |
      until nc -z {{ $pgHost }} {{ $pgPort }}; do echo "waiting for postgres..."; sleep 2; done
      until nc -z {{ $mgHost }} {{ $mgPort }}; do echo "waiting for mongodb..."; sleep 2; done
      {{- if ne .Values.rabbitmq.mode "external" }}
      until nc -z {{ .Release.Name }}-rabbitmq 5672; do echo "waiting for rabbitmq..."; sleep 2; done
      {{- end }}
  resources:
    requests: { cpu: 10m, memory: 16Mi }
    limits:   { cpu: 50m, memory: 32Mi }
  securityContext:
    runAsNonRoot: true
    {{- /* on openshift the restricted SCC assigns the UID from the namespace range; pin nobody elsewhere */}}
    {{- if ne .Values.platform "openshift" }}
    runAsUser: 65534          # busybox has no non-root USER; pin nobody
    {{- end }}
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
{{- end }}
