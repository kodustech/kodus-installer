{{/*
Pod security context — SOC 2 hardened defaults.
On OpenShift, set podSecurityContext.fsGroup: null in values (the SCC assigns UIDs).
*/}}
{{- define "kodus-common.podSecurityContext" -}}
runAsNonRoot: true
{{- if not (kindIs "invalid" .Values.podSecurityContext.fsGroup) }}
fsGroup: {{ .Values.podSecurityContext.fsGroup }}
{{- end }}
seccompProfile:
  type: {{ .Values.podSecurityContext.seccompProfile.type | default "RuntimeDefault" }}
{{- end }}

{{/*
Container security context — SOC 2 hardened defaults.
readOnlyRootFilesystem requires a writable /tmp emptyDir (see tmpVolume below).
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
Pod security context for a bundled datastore StatefulSet. On Kubernetes we pin
the image's uid/gid (999); on OpenShift we omit them so the restricted SCC
assigns the range (bundled DBs on OpenShift may still need a permissive SCC —
operator/external is recommended there).
*/}}
{{- define "kodus-common.datastorePodSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- if ne .Values.platform "openshift" }}
fsGroup: 999
runAsUser: 999
{{- end }}
{{- end }}

{{/*
Writable /tmp volume mount + volume, needed alongside readOnlyRootFilesystem
(Node.js writes to /tmp). All Kodus services log to stdout, so /app/logs is not
required to be writable.
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
