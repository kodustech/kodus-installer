{{/* Thin wrappers over kodus-common so chart templates read cleanly. */}}

{{- define "kodus.fullname" -}}
{{ include "kodus-common.fullname" . }}
{{- end }}

{{- define "kodus.labels" -}}
{{ include "kodus-common.labels" . }}
{{- end }}

{{- define "kodus.serviceAccountName" -}}
{{ include "kodus-common.serviceAccountName" . }}
{{- end }}

{{/*
Public base URL (scheme://host) that serves the `webhooks` service (port 3332),
taken from the Route (OpenShift) or Ingress (plain K8s) the user configured. Used
to auto-derive API_<provider>_CODE_MANAGEMENT_WEBHOOK when left empty, so the user
doesn't have to hand-write it. Returns "" when we can't derive safely — no
ingress/route, host empty (e.g. OpenShift router auto-assigns it, unknown at
template time), or still the shipped example.com placeholder — so we never emit a
plausible-but-wrong URL. When empty, doctor-k8s.sh guides the user to set it.
*/}}
{{- define "kodus.webhooksBaseUrl" -}}
{{- $host := "" -}}
{{- $scheme := "https" -}}
{{- if eq .Values.platform "openshift" -}}
{{- if .Values.route.enabled -}}{{- with .Values.route.hosts.webhooks }}{{- $host = .host | default "" -}}{{- end -}}{{- end -}}
{{- else -}}
{{- if .Values.ingress.enabled -}}{{- with .Values.ingress.hosts.webhooks }}{{- $host = .host | default "" -}}{{- end -}}{{- end -}}
{{- if not .Values.ingress.tls.enabled -}}{{- $scheme = "http" -}}{{- end -}}
{{- end -}}
{{- if and $host (not (contains "example.com" $host)) -}}{{ printf "%s://%s" $scheme $host }}{{- end -}}
{{- end -}}

{{/*
Public base URL of the `web` service. NEXTAUTH_URL wins when set — it is already
required to be the full public HTTPS URL, so it is the most reliable source and
keeps the OAuth redirect on the same origin the user signs in on. Otherwise fall
back to the configured Route/Ingress host, with the same safety rules as
webhooksBaseUrl: returns "" rather than guessing when the host is unknown or is
still the example.com placeholder. Used to auto-derive API_MCP_MANAGER_REDIRECT_URI.
*/}}
{{- define "kodus.webBaseUrl" -}}
{{- $url := (.Values.global.config.NEXTAUTH_URL | default "") -}}
{{- if and $url (not (contains "example.com" $url)) -}}
{{ trimSuffix "/" $url }}
{{- else -}}
{{- $host := "" -}}
{{- $scheme := "https" -}}
{{- if eq .Values.platform "openshift" -}}
{{- if .Values.route.enabled -}}{{- with .Values.route.hosts.web }}{{- $host = .host | default "" -}}{{- end -}}{{- end -}}
{{- else -}}
{{- if .Values.ingress.enabled -}}{{- with .Values.ingress.hosts.web }}{{- $host = .host | default "" -}}{{- end -}}{{- end -}}
{{- if not .Values.ingress.tls.enabled -}}{{- $scheme = "http" -}}{{- end -}}
{{- end -}}
{{- if and $host (not (contains "example.com" $host)) -}}{{ printf "%s://%s" $scheme $host }}{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Provider → webhook path segment. The webhooks server mounts each controller at
/<segment>/webhook with NO global prefix (apps/webhooks/src/main.ts has no
setGlobalPrefix), so the public URL is <base>/<segment>/webhook.
*/}}
{{- define "kodus.webhookProviders" -}}
API_GITHUB_CODE_MANAGEMENT_WEBHOOK: github
API_GITLAB_CODE_MANAGEMENT_WEBHOOK: gitlab
GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK: bitbucket
GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK: azure-repos
API_FORGEJO_CODE_MANAGEMENT_WEBHOOK: forgejo
{{- end }}

{{/*
Secret keys the app consumes, split by generation method (per kodus-ai schema
autogen tags). hex32 → 32-byte hex (sha256 of random gives 64 hex chars); the
rest → base64. This ordering is load-bearing: API_CRYPTO_KEY / CODE_MANAGEMENT_SECRET
are parsed with Buffer.from(x,'hex') and MUST be valid hex.
*/}}
{{- define "kodus.secretKeysHex" -}}
- API_CRYPTO_KEY
- CODE_MANAGEMENT_SECRET
- API_MCP_MANAGER_ENCRYPTION_SECRET
{{- end }}
{{- define "kodus.secretKeysB64" -}}
- API_JWT_SECRET
- API_JWT_REFRESH_SECRET
- WEB_NEXTAUTH_SECRET
- API_MCP_MANAGER_JWT_SECRET
- CODE_MANAGEMENT_WEBHOOK_TOKEN
{{- end }}

{{/*
Reject app service names that would collide with a bundled datastore.

A Service's selector is {name: <svcName>, instance: <release>, part-of: kodus}
(kodus-common.serviceSelectorLabels), and the bundled datastore pods carry
{name: postgres|mongodb|rabbitmq, instance: <release>, part-of: kodus}. So a
service declared as `postgres:` under .Values.services renders a Service whose
selector matches all three labels on the DATABASE pods — app traffic would be
balanced onto Postgres, and the failure reads as a bizarre protocol error rather
than a naming mistake.

Fixing this in the labels themselves is not an option on an existing release:
Deployment.spec.selector is immutable, so adding a `component` label would break
`helm upgrade`. Failing the render is the cheap equivalent — it costs nothing,
touches no selector, and turns a silent misroute into a clear message at install
time. Call once with the root context.
*/}}
{{- define "kodus.validateServiceNames" -}}
{{- $reserved := list "postgres" "mongodb" "rabbitmq" }}
{{- range $name, $svc := .Values.services }}
{{- if has $name $reserved }}
{{- fail (printf "ERROR: services.%s is a reserved name. The bundled %s StatefulSet labels its pods app.kubernetes.io/name=%s, so this service's selector would match the datastore pods instead of its own. Rename the service (e.g. %s-api)." $name $name $name $name) }}
{{- end }}
{{- end }}
{{- end }}
