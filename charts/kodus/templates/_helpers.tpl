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
