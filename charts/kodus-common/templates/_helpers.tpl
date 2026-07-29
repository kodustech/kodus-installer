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
Chart label.
*/}}
{{- define "kodus-common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Service short name: release-name-serviceName (used for Service/Deployment names
and cross-service DNS). Call with (dict "root" . "serviceName" $name).
*/}}
{{- define "kodus-common.serviceFullname" -}}
{{- printf "%s-%s" .root.Release.Name .serviceName | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels — merges standard Helm labels with the compliance/audit labels
from global.labels (SOC 2 traceability).
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
Release-level selector labels.
*/}}
{{- define "kodus-common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kodus-common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service-specific selector labels (stable set used by Deployment/Service selectors
and NetworkPolicy podSelectors). Call with (dict "root" . "serviceName" $name).
*/}}
{{- define "kodus-common.serviceSelectorLabels" -}}
app.kubernetes.io/name: {{ .serviceName }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: kodus
{{- end }}

{{/*
Service-specific labels (full set for metadata.labels).
Call with (dict "root" . "serviceName" $name).
*/}}
{{- define "kodus-common.serviceLabels" -}}
{{ include "kodus-common.serviceSelectorLabels" . }}
helm.sh/chart: {{ include "kodus-common.chart" .root }}
{{- /*
  Report the version this service is ACTUALLY running, not the one the chart was
  built around. Chart.AppVersion is what the chart ships with; a user who ran
  `--set imageTag=2.1.28`, or overrode one service's image.tag, is running
  something else. A version label that disagrees with the running image is worse
  than no label — support debugs against the wrong release, and the label is what
  told them to.

  Resolution mirrors deployment.yaml: the service's own image.tag, else the
  stack-wide imageTag, else the chart's appVersion. Truncated to 63 characters
  because that is the label-value limit; a longer tag would fail admission.

  Components with no entry under .Values.services — the bundled datastores — keep
  the chart's appVersion. It says nothing useful about pgvector or mongo, but
  those run images this chart does not version, and rewriting their pod-template
  labels would restart a database on upgrade to fix a cosmetic field. Their real
  images are one `kubectl get sts -o wide` away, and the support annotations on
  the ConfigMap spell out the whole picture.
*/}}
{{- $svc := (index .root.Values.services .serviceName) | default dict }}
{{- $tag := (dig "image" "tag" "" $svc) | default .root.Values.imageTag | default .root.Chart.AppVersion }}
{{- if $tag }}
app.kubernetes.io/version: {{ $tag | toString | trunc 63 | trimSuffix "-" | trimSuffix "." | quote }}
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
Image tag validation — fails the render if neither tag nor digest is set.
Guards against booting production with a floating/unset image.
Call with (dict "svcName" $name "image" $svc.image).
*/}}
{{- define "kodus-common.validateImageTag" -}}
{{- if and (not .image.tag) (not .image.digest) }}
{{- fail (printf "ERROR: services.%s.image.tag is required. The chart defaults the top-level imageTag to 'latest'; pin a release (e.g. '2.1.27') or use image.digest for SHA pinning when you need reproducible installs." .svcName) }}
{{- end }}
{{- end }}

{{/*
Full image reference (repo:tag or repo@digest). Call with $svc.image.
*/}}
{{- define "kodus-common.imageRef" -}}
{{- if .digest }}
{{- printf "%s@%s" .repository .digest }}
{{- else }}
{{- printf "%s:%s" .repository .tag }}
{{- end }}
{{- end }}

{{/*
Global image-registry prefix for air-gapped mirrors. Returns "" when unset, or
"<registry>/" when global.imageRegistry is set — prepend it to every image so a
single value repoints the whole stack (app + busybox + mongo + pgvector + rabbit)
at a private mirror. Call with the root context.
*/}}
{{- define "kodus-common.regPrefix" -}}
{{- with .Values.global.imageRegistry }}{{ . | trimSuffix "/" }}/{{ end }}
{{- end }}

{{/*
Resolve a Kodus app image: regPrefix + repository + (digest | own tag | global
imageTag). The per-service image.tag wins; when empty it falls back to the
top-level .Values.imageTag (like docker-compose IMAGE_TAG). Fails if none is set.
Call with (dict "image" $svc.image "root" $ "name" $name).
*/}}
{{- define "kodus-common.appImage" -}}
{{- $img := .image -}}
{{- $tag := $img.tag | default .root.Values.imageTag -}}
{{- if and (not $tag) (not $img.digest) -}}
{{- fail (printf "image tag for '%s' is required — set services.%s.image.tag or the top-level imageTag (or use image.digest). The chart defaults imageTag to 'latest'; pin a release for reproducible installs." .name .name) -}}
{{- end -}}
{{- $ref := "" -}}
{{- if $img.digest }}{{ $ref = printf "%s@%s" $img.repository $img.digest }}{{ else }}{{ $ref = printf "%s:%s" $img.repository $tag }}{{ end -}}
{{- include "kodus-common.regPrefix" .root }}{{ $ref }}
{{- end }}
