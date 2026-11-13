{{/* The pod of a database job: db-init.sh in the psql image, as the product's admin. */}}
{{- define "kr.dbJobPod" -}}
{{- $admin := .root.Values.postgres.admin -}}
spec:
  restartPolicy: OnFailure
  automountServiceAccountToken: false
  {{- include "kr.pullSecrets" .root | nindent 2 }}
  securityContext:
    {{- include "kr.podSecurity" (dict "uid" 70) | nindent 4 }}
  containers:
    - name: runtime-init
      image: {{ include "kr.image" (dict "root" .root "name" "psql") }}
      imagePullPolicy: {{ .root.Values.images.pullPolicy }}
      command: ["bash", "-c", {{ .script | quote }}]
      env:
        - { name: RUNTIME_INIT_MODE, value: {{ .mode | quote }} }
        - { name: RUNTIME_INIT_PGSSLMODE, value: {{ .root.Values.postgres.sslMode | quote }} }
        - { name: API_PG_DB_HOST, value: {{ include "kr.pgHost" .root | quote }} }
        - { name: API_PG_DB_PORT, value: {{ .root.Values.postgres.port | quote }} }
        - { name: API_PG_DB_DATABASE, value: {{ .root.Values.postgres.productDatabase | quote }} }
        - name: API_PG_DB_USERNAME
          valueFrom: { secretKeyRef: { name: {{ $admin.existingSecret }}, key: {{ $admin.usernameKey }} } }
        - name: API_PG_DB_PASSWORD
          valueFrom: { secretKeyRef: { name: {{ $admin.existingSecret }}, key: {{ $admin.passwordKey }} } }
        {{- range $k := list "RUNTIME_PG_PASSWORD" "RUNTIME_READER_PG_PASSWORD" "RUNTIME_SECRETS_READER_PG_PASSWORD" "RUNTIME_OPENBAO_PG_PASSWORD" }}
        - name: {{ $k }}
          valueFrom: { secretKeyRef: { name: {{ include "kr.fullname" $.root }}-env, key: {{ $k }} } }
        {{- end }}
      securityContext:
        {{- include "kr.containerSecurity" . | nindent 8 }}
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 128Mi }
      volumeMounts:
        - { name: db, mountPath: /runtime/db-init.sh, subPath: db-init.sh, readOnly: true }
        - { name: db, mountPath: /runtime/sql, readOnly: true }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: db
      configMap: { name: {{ include "kr.fullname" .root }}-db }
    - name: tmp
      emptyDir: { sizeLimit: 16Mi }
{{- end }}
