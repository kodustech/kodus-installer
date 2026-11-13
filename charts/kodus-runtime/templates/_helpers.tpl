{{/* Names */}}
{{- define "kr.name" -}}
{{- default "kodus-runtime" .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kr.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 50 | trimSuffix "-" -}}
{{- else if contains (include "kr.name" .) .Release.Name -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "kr.name" .) | trunc 50 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "kr.labels" -}}
app.kubernetes.io/name: {{ include "kr.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/component: {{ .component }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "kr.selector" -}}
app.kubernetes.io/name: {{ include "kr.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* An image by digest, or the render fails naming the value. */}}
{{- define "kr.image" -}}
{{- $ref := index .root.Values.images .name -}}
{{- if not $ref -}}
{{- fail (printf "images.%s is required (repository@sha256:<digest>): no Runtime image is published yet, see docs/runtime.md" .name) -}}
{{- end -}}
{{- if not (regexMatch "@sha256:[0-9a-f]{64}$" $ref) -}}
{{- fail (printf "images.%s must be pinned by digest (repository@sha256:<64 hex>), got %q" .name $ref) -}}
{{- end -}}
{{- $ref -}}
{{- end -}}

{{- define "kr.required" -}}
{{- if not .value -}}{{- fail (printf "%s is required" .name) -}}{{- end -}}
{{- .value -}}
{{- end -}}

{{/* The restricted security context of every container. */}}
{{- define "kr.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "kr.podSecurity" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .uid }}
fsGroup: {{ .uid }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "kr.pullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* Service names. */}}
{{- define "kr.hub" -}}{{ include "kr.fullname" . }}-hub{{- end -}}
{{- define "kr.hubInternal" -}}{{ include "kr.fullname" . }}-hub-internal{{- end -}}
{{- define "kr.worker" -}}{{ include "kr.fullname" . }}-worker{{- end -}}
{{- define "kr.evidence" -}}{{ include "kr.fullname" . }}-evidence{{- end -}}
{{- define "kr.openbao" -}}{{ include "kr.fullname" . }}-openbao{{- end -}}
{{- define "kr.cell" -}}{{ include "kr.fullname" . }}-cell{{- end -}}
{{- define "kr.cellEgress" -}}{{ include "kr.fullname" . }}-cell-egress{{- end -}}

{{- define "kr.hubUrl" -}}
{{- if .Values.cell.hub.url -}}
{{- .Values.cell.hub.url -}}
{{- else -}}
{{- printf "wss://%s.%s.svc:3410/cells" (include "kr.hub" .) .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{- define "kr.openbaoAddr" -}}
{{- if .Values.cell.openbao.addr -}}
{{- .Values.cell.openbao.addr -}}
{{- else -}}
{{- printf "https://%s.%s.svc:8200" (include "kr.openbao" .) .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{- define "kr.evidenceUrl" -}}
{{- default (printf "http://%s:3420" (include "kr.evidence" .)) .Values.controlPlane.worker.evidence.publicUrl -}}
{{- end -}}

{{/*
Generated state, made once per render and kept across upgrades: on install
every value is new; on upgrade it is read back from the Secrets this chart
wrote (lookup), so passwords, keys and certificates never churn. helm
template has no cluster, so it renders fresh values.
*/}}
{{- define "kr.state" -}}
{{- if not (hasKey .Values "__krState") -}}
{{- $ns := .Release.Namespace -}}
{{- $old := dict -}}
{{- $s := lookup "v1" "Secret" $ns (printf "%s-state" (include "kr.fullname" .)) -}}
{{- if $s -}}{{- $old = $s.data -}}{{- end -}}
{{- $st := dict -}}
{{- range $k := list "pgRuntime" "pgReader" "pgSecretsReader" "pgOpenbao" "mqRuntime" "runToken" "evidenceSecret" -}}
{{- $_ := set $st $k (ternary (index $old $k | default "" | b64dec) (randAlphaNum 40) (hasKey $old $k)) -}}
{{- end -}}
{{- /* 32 bytes, hex: RUNTIME_SECRET_SEAL_KEY. */ -}}
{{- $_ := set $st "sealKey" (ternary (index $old "sealKey" | default "" | b64dec) (printf "%s%s" (uuidv4 | replace "-" "") (uuidv4 | replace "-" "")) (hasKey $old "sealKey")) -}}
{{- /* OpenBao's static unseal key: 32 raw bytes, kept base64 here. */ -}}
{{- $_ := set $st "unsealKey" (ternary (index $old "unsealKey" | default "") (randBytes 32) (hasKey $old "unsealKey")) -}}
{{- range $k := list "apiRoleId" "apiSecretId" "injectorRoleId" "injectorSecretId" -}}
{{- $_ := set $st $k (ternary (index $old $k | default "" | b64dec) (printf "%s%s" (uuidv4 | replace "-" "") (randAlphaNum 16 | lower)) (hasKey $old $k)) -}}
{{- end -}}
{{- /* PKI: P-256 throughout (the hub signs cell certificates only with an ECDSA P-256 CA). */ -}}
{{- $pki := dict -}}
{{- $p := lookup "v1" "Secret" $ns (printf "%s-pki" (include "kr.fullname" .)) -}}
{{- if $p -}}
{{- range $k, $v := $p.data -}}{{- $_ := set $pki $k ($v | b64dec) -}}{{- end -}}
{{- else -}}
{{- $hubNames := list (include "kr.hub" .) (printf "%s.%s" (include "kr.hub" .) $ns) (printf "%s.%s.svc" (include "kr.hub" .) $ns) (printf "%s.%s.svc.cluster.local" (include "kr.hub" .) $ns) (include "kr.hubInternal" .) (printf "%s.%s.svc" (include "kr.hubInternal" .) $ns) "runtime-hub" "localhost" -}}
{{- $hubNames = concat $hubNames .Values.controlPlane.hub.externalHosts -}}
{{- $caKey := genPrivateKey "ecdsa" -}}
{{- $ca := genCAWithKey "Kody Runtime CA" 3650 $caKey -}}
{{- $hubKey := genPrivateKey "ecdsa" -}}
{{- $hub := genSignedCertWithKey "runtime-hub" (list "127.0.0.1") $hubNames 397 $ca $hubKey -}}
{{- $wcaKey := genPrivateKey "ecdsa" -}}
{{- $wca := genCAWithKey "Kody Runtime worker CA" 3650 $wcaKey -}}
{{- $wKey := genPrivateKey "ecdsa" -}}
{{- $w := genSignedCertWithKey "runtime-worker" nil nil 397 $wca $wKey -}}
{{- $obNames := list (include "kr.openbao" .) (printf "%s.%s" (include "kr.openbao" .) $ns) (printf "%s.%s.svc" (include "kr.openbao" .) $ns) (printf "%s.%s.svc.cluster.local" (include "kr.openbao" .) $ns) "runtime-openbao" "localhost" -}}
{{- $obNames = concat $obNames .Values.controlPlane.openbao.externalHosts -}}
{{- $obcaKey := genPrivateKey "ecdsa" -}}
{{- $obca := genCAWithKey "Kody Runtime OpenBao CA" 3650 $obcaKey -}}
{{- $obKey := genPrivateKey "ecdsa" -}}
{{- $ob := genSignedCertWithKey "runtime-openbao" (list "127.0.0.1") $obNames 397 $obca $obKey -}}
{{- $_ := set $pki "ca.pem" $ca.Cert -}}
{{- $_ := set $pki "ca.key" $ca.Key -}}
{{- $_ := set $pki "hub.pem" $hub.Cert -}}
{{- $_ := set $pki "hub.key" $hub.Key -}}
{{- $_ := set $pki "worker-ca.pem" $wca.Cert -}}
{{- $_ := set $pki "worker.pem" $w.Cert -}}
{{- $_ := set $pki "worker.key" $w.Key -}}
{{- $_ := set $pki "openbao-ca.pem" $obca.Cert -}}
{{- $_ := set $pki "openbao.pem" $ob.Cert -}}
{{- $_ := set $pki "openbao.key" $ob.Key -}}
{{- end -}}
{{- $_ := set $st "pki" $pki -}}
{{- $_ := set .Values "__krState" $st -}}
{{- end -}}
{{- end -}}

{{/* One generated value: (dict "root" $ "key" "pgRuntime"). */}}
{{- define "kr.get" -}}
{{- include "kr.state" .root -}}
{{- index .root.Values.__krState .key -}}
{{- end -}}

{{- define "kr.pki" -}}
{{- include "kr.state" .root -}}
{{- index .root.Values.__krState.pki .key -}}
{{- end -}}

{{- define "kr.pgHost" -}}{{ include "kr.required" (dict "name" "postgres.host" "value" .Values.postgres.host) }}{{- end -}}

{{- define "kr.runtimeDbUrl" -}}
{{- printf "postgres://kodus_runtime:%s@%s:%v/kodus_runtime?sslmode=%s" (include "kr.get" (dict "root" . "key" "pgRuntime")) (include "kr.pgHost" .) .Values.postgres.port .Values.postgres.sslMode -}}
{{- end -}}

{{- define "kr.mqUrl" -}}
{{- printf "%s://kodus_runtime:%s@%s:%v/%s?heartbeat=60" .Values.rabbitmq.scheme (include "kr.get" (dict "root" . "key" "mqRuntime")) (include "kr.required" (dict "name" "rabbitmq.host" "value" .Values.rabbitmq.host)) .Values.rabbitmq.port (.Values.rabbitmq.vhost | urlquery) -}}
{{- end -}}

{{/* An init container that waits until a role can log in to its database. */}}
{{- define "kr.waitForDb" -}}
- name: wait-for-postgres
  image: {{ include "kr.image" (dict "root" .root "name" "psql") }}
  imagePullPolicy: {{ .root.Values.images.pullPolicy }}
  command: ["sh", "-c", "until psql \"$DATABASE_URL\" -Atqc 'select 1' >/dev/null 2>&1; do echo waiting for {{ .what }}; sleep 3; done"]
  env:
    - name: DATABASE_URL
      valueFrom:
        secretKeyRef: { name: {{ include "kr.fullname" .root }}-env, key: {{ .key }} }
  securityContext:
    {{- include "kr.containerSecurity" . | nindent 4 }}
  resources:
    requests: { cpu: 10m, memory: 16Mi }
    limits: { memory: 64Mi }
{{- end -}}
