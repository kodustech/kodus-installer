#!/usr/bin/env bash
# scripts/doctor-k8s.sh
# Health check for a Kodus Helm deployment (Kubernetes / OpenShift).
# Parallel to doctor.sh (Docker Compose). Read-only: it inspects the cluster and
# probes the real health endpoints, never mutating anything.
#
# Usage:
#   ./scripts/doctor-k8s.sh [-n <namespace>] [-r <release>] [--profile prod|dev]
# Defaults: namespace = current kubectl context, release = kodus, profile = prod
#
# The profile separates two questions this script answers at once: "is this
# deployment healthy?" and "is this configuration fit for production?". On a local
# trial or a CI smoke test the second one is noise — values-dev.yaml points the
# webhook URL at localhost deliberately, and reporting that as a failure trains
# people to ignore red. --profile dev keeps every health check strict and
# downgrades production-readiness findings to warnings.

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

# shellcheck source=scripts/doctor-lib.sh
. "$(cd "$(dirname "$0")" && pwd)/doctor-lib.sh"

# Each check also records a result for the report (scripts/doctor-lib.sh);
# the lines echoed here only reach the terminal with --verbose.
ok()   { echo -e "  ${GREEN}✔${NC} $1"; PASS=$((PASS+1)); doctor_add ok infra "" "$1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; WARN=$((WARN+1)); doctor_add unknown infra "" "$1"; }
# bad <what> [impact] [fix] — a check that knows its consequence and remedy passes them.
bad()  { echo -e "  ${RED}✘${NC} $1"; FAIL=$((FAIL+1)); doctor_add fail infra "" "$1" "${2:-Kodus depends on this; reviews may not run until it is fixed.}" "${3:-}"; }
section() { echo -e "\n${BLUE}== $1 ==${NC}"; }

RELEASE="kodus"
NAMESPACE=""
PROFILE="prod"
# shellcheck disable=SC2034 # DOCTOR_VERBOSE is read by doctor-lib.sh
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    --profile)      PROFILE="$2"; shift 2 ;;
    -v|--verbose)   DOCTOR_VERBOSE=true; shift ;;
    -h|--help) echo "Usage: $0 [-n namespace] [-r release] [--profile prod|dev] [--verbose]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done
case "$PROFILE" in
  prod|dev) ;;
  *) echo "Unknown profile: $PROFILE (expected prod or dev)"; exit 1 ;;
esac

# A fresh dev/CI install has no Git provider or model connected, so the review
# checks are expected to report ✘ there: show them, keep them out of the exit code.
# shellcheck disable=SC2034 # read by doctor-lib.sh
[ "$PROFILE" = "dev" ] && DOCTOR_SOFT_APP_FAILS=true

doctor_capture_start

# Production-readiness finding: a real problem for a deployment meant to serve
# traffic, expected on a local trial. Fails under --profile prod, warns under dev.
notprod() { if [ "$PROFILE" = "dev" ]; then warn "$1"; else bad "$1"; fi; }

# --- Prerequisites ---
section "Prerequisites"
if ! command -v kubectl >/dev/null 2>&1; then
  bad "kubectl not found"; echo "Install kubectl and configure access to your cluster."; exit 1
fi
ok "kubectl present ($(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1 | cut -d'"' -f4))"
# Reachability WITHOUT cluster-scope RBAC: namespace-scoped users (OpenShift
# Developer Sandbox, enterprise multi-tenant clusters) can't run `kubectl
# cluster-info` — it needs cluster-scope. `kubectl version` only needs to reach
# the API server, so it works for any authenticated user.
if ! kubectl version -o json --request-timeout=8s >/dev/null 2>&1; then
  bad "cannot reach the Kubernetes API (check your kubeconfig/context, or log in)"; exit 1
fi
ok "cluster reachable ($(kubectl config current-context 2>/dev/null))"

if [ -z "$NAMESPACE" ]; then
  NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  [ -z "$NAMESPACE" ] && NAMESPACE="default"
fi
# `get ns` needs cluster-scope on some clusters; fall back to a namespace-scoped
# op so a namespace-only user still passes.
if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1 && ! kubectl get pods -n "$NAMESPACE" >/dev/null 2>&1; then
  bad "namespace '$NAMESPACE' not found or not accessible with your permissions"; exit 1
fi
ok "namespace: $NAMESPACE   release: $RELEASE"

K="kubectl -n $NAMESPACE"
SEL="app.kubernetes.io/part-of=kodus,app.kubernetes.io/instance=$RELEASE"

# --- Helm release ---
section "Helm release"
if command -v helm >/dev/null 2>&1; then
  STATUS=$(helm -n "$NAMESPACE" status "$RELEASE" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  case "$STATUS" in
    deployed) ok "helm release '$RELEASE' is deployed" ;;
    "")       warn "no helm release '$RELEASE' in $NAMESPACE (installed by other means?)" ;;
    *)        bad "helm release status: $STATUS" ;;
  esac
else
  warn "helm not found — skipping release check"
fi

# --- Migration Job ---
section "Database migrations Job"
JOB=$($K get job -l "app.kubernetes.io/component=migrations,app.kubernetes.io/instance=$RELEASE" \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
if [ -n "$JOB" ]; then
  SUCC=$($K get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)
  if [ "${SUCC:-0}" -ge 1 ] 2>/dev/null; then
    ok "migration job '$JOB' completed"
  else
    bad "migration job '$JOB' has not succeeded — check: $K logs job/$JOB"
  fi
else
  # The Job deletes itself 10 minutes after it finishes (ttlSecondsAfterFinished),
  # so on any install older than that there is nothing to find. A ready api
  # means the release is up; the review checks read the database itself.
  API_READY=$($K get deploy "${RELEASE}-api" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "${API_READY:-0}" -ge 1 ] 2>/dev/null; then
    echo "  ‣ no migration job left (cleaned up 10 minutes after it finished); the api is ready"
  else
    warn "no migration job found and the api is not ready (migrations.enabled=false, or the job was cleaned up) — check: $K logs -l app.kubernetes.io/name=migrations --tail=-1"
  fi
fi

# --- Workloads ---
section "Workloads (Deployments & StatefulSets)"
check_rollout() {
  local kind=$1 name=$2
  local desired ready
  desired=$($K get "$kind" "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  if [ -z "$desired" ]; then return; fi
  ready=$($K get "$kind" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  ready=${ready:-0}
  if [ "$ready" = "$desired" ]; then
    ok "$kind/$name  ($ready/$desired ready)"
  else
    bad "$kind/$name  ($ready/$desired ready)"
  fi
}
DEPLOYS=$($K get deploy -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
STS=$($K get statefulset -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [ -z "$DEPLOYS$STS" ]; then
  bad "no Kodus workloads found (selector: $SEL) — wrong namespace/release?"
else
  for d in $DEPLOYS; do check_rollout deployment "$d"; done
  for s in $STS;     do check_rollout statefulset "$s"; done
  # Without these, reviews do not run (or nobody can sign in) even though every
  # pod that does exist is healthy. The api is checked under "Reviews".
  for svc in worker webhooks web; do
    if ! printf '%s\n' "$DEPLOYS" | grep -qx "${RELEASE}-${svc}"; then
      bad "deployment ${RELEASE}-${svc} not found" \
        "$(case $svc in worker) echo "No review runs: nothing takes the review jobs." ;; webhooks) echo "Kodus is not told about new pull requests, so none is reviewed." ;; web) echo "Nobody can sign in or change settings." ;; esac)" \
        "Enable it (services.${svc}.enabled=true) and run helm upgrade."
    elif [ "$($K get deploy "${RELEASE}-${svc}" -o jsonpath='{.spec.replicas}' 2>/dev/null)" = "0" ]; then
      bad "deployment ${RELEASE}-${svc} is scaled to 0 replicas" \
        "$(case $svc in worker) echo "No review runs: nothing takes the review jobs." ;; webhooks) echo "Kodus is not told about new pull requests, so none is reviewed." ;; web) echo "Nobody can sign in or change settings." ;; esac)" \
        "Scale it back up: $K scale deploy/${RELEASE}-${svc} --replicas=1 (or set services.${svc}.replicas and run helm upgrade)."
    fi
  done
fi

# No MongoDB 8.3 release starts on Linux kernels 6.19+ (SERVER-121912), and the
# chart's bundled default is 8.3. The pod only crash-loops, so name the cause.
MONGO_IMG=$($K get statefulset "${RELEASE}-mongodb" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
if echo "$MONGO_IMG" | grep -qE ':8\.3(\.|$)'; then
  NEW_KERNELS=$($K get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kernelVersion}{"\n"}{end}' 2>/dev/null \
    | awk -F. '$1+0 > 6 || ($1+0 == 6 && $2+0 >= 19)' | sort -u | tr '\n' ' ')
  if [ -n "$NEW_KERNELS" ]; then
    bad "bundled MongoDB $MONGO_IMG cannot start on node kernel(s) $NEW_KERNELS(SERVER-121912)" \
      "Kodus has no database until MongoDB starts." \
      "helm upgrade with --set mongodb.bundled.image=mongo:8.2.11"
  fi
fi

# --- Pods ---
section "Pod health"
# A pod with a deletionTimestamp is on its way out, not broken. Run this straight
# after `helm upgrade` and the old ReplicaSet's pods are still draining their
# terminationGracePeriod while the new ones already serve traffic — reporting
# those as failures makes a healthy rollout look like an outage. Read the phase
# and the deletion timestamp explicitly rather than the STATUS column, which
# collapses both into the word "Terminating".
#
# Detection still reads kubectl's computed STATUS column, NOT .status.phase: a
# CrashLoopBackOff pod has phase=Running, so phase alone would call a crash loop
# healthy. Terminating pods are identified separately by deletionTimestamp and
# subtracted from the list.
TERMINATING=$($K get pods -l "$SEL" \
  -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^$')
# Exact-name subtraction, not a substring filter: one pod's name can be a prefix
# of another's, and a grep -F would then hide a genuinely broken pod.
BADPODS=$($K get pods -l "$SEL" --no-headers 2>/dev/null \
  | awk -v term="$TERMINATING" '
      BEGIN { n = split(term, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") t[a[i]] = 1 }
      $3 != "Running" && $3 != "Completed" && !($1 in t) { print $1" ("$3")" }')
RESTARTS=$($K get pods -l "$SEL" --no-headers 2>/dev/null | awk '$4>5 {print $1" (restarts="$4")"}')
if [ -z "$($K get pods -l "$SEL" --no-headers 2>/dev/null)" ]; then
  warn "no pods match selector"
else
  if [ -z "$BADPODS" ]; then
    ok "all pods Running/Completed"
  else
    while IFS= read -r p; do [ -n "$p" ] && bad "pod not ready: $p"; done <<< "$BADPODS"
  fi
  if [ -n "$TERMINATING" ]; then
    n=$(echo "$TERMINATING" | grep -c .)
    warn "$n pod(s) terminating — normal right after an upgrade or a scale-down: $(echo "$TERMINATING" | tr '\n' ' ')"
  fi
  if [ -n "$RESTARTS" ]; then
    while IFS= read -r p; do [ -n "$p" ] && warn "high restart count: $p"; done <<< "$RESTARTS"
  fi
  # A container the kernel killed for memory comes back Running, so only its
  # last (or current) termination reason tells. Per pod: container=last/current;...
  OOMS=$($K get pods -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.name}{"="}{.lastState.terminated.reason}{"/"}{.state.terminated.reason}{";"}{end}{"\n"}{end}' 2>/dev/null)
  while IFS=$'\t' read -r pod containers; do
    [ -n "$pod" ] || continue
    IFS=';' read -r -a cs <<< "$containers"
    for c in ${cs[@]+"${cs[@]}"}; do
      case "$c" in
        *OOMKilled*)
          echo -e "  ${YELLOW}!${NC} pod $pod container ${c%%=*} was OOMKilled"
          doctor_add warn infra "" "Pod $pod (container ${c%%=*}) was killed for running out of memory." \
            "The work it was doing stopped (a review in progress fails), and it happens again when it needs that much memory." \
            "Raise its memory limit (resources.limits.memory of ${c%%=*} in your values) and run helm upgrade."
          ;;
      esac
    done
  done <<< "$OOMS"
fi

# --- Config & Secrets ---
section "Config & Secrets"
$K get configmap "${RELEASE}-config" >/dev/null 2>&1 && ok "configmap ${RELEASE}-config present" || bad "configmap ${RELEASE}-config missing"
if $K get secret "${RELEASE}-secrets" >/dev/null 2>&1; then
  # API_CRYPTO_KEY must decode to 64 hex chars (32 bytes) or the app crash-loops.
  CK=$($K get secret "${RELEASE}-secrets" -o jsonpath='{.data.API_CRYPTO_KEY}' 2>/dev/null | base64 -d 2>/dev/null)
  if echo "$CK" | grep -qE '^[0-9a-f]{64}$'; then ok "app secrets present; API_CRYPTO_KEY is valid 32-byte hex"; else bad "API_CRYPTO_KEY is not 32-byte hex (app will crash: 'must be 32 bytes in hexadecimal')"; fi
  # The mcp-manager verifies the signature of the access token the web forwards,
  # so an empty API_JWT_SECRET makes every MCP request 401 while the /health
  # probe still passes. The chart always generates it, so empty means a broken setup.
  JS=$($K get secret "${RELEASE}-secrets" -o jsonpath='{.data.API_JWT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -n "$JS" ]; then ok "API_JWT_SECRET present (MCP auth can verify tokens)"; else bad "API_JWT_SECRET is empty — MCP requests will 401 (the mcp-manager verifies the forwarded access token's signature). Fix: set API_JWT_SECRET in the secret (or in your values) and run helm upgrade"; fi
else
  warn "secret ${RELEASE}-secrets not found (using existingSecret/externalSecrets?)"
fi

# --- Config sanity (the class of error the UI hits on "save repositories") ---
section "Config sanity (Git webhooks reachability)"
CM="${RELEASE}-config"
# WEB_HOSTNAME_API is the IN-CLUSTER API address the web proxies to (NOT the public
# webhook URL — that's API_*_CODE_MANAGEMENT_WEBHOOK, checked below). Empty breaks
# the web→api proxy (/api/proxy calls fail with "fetch failed").
HOSTAPI=$($K get configmap "$CM" -o jsonpath='{.data.WEB_HOSTNAME_API}' 2>/dev/null)
if [ -z "$HOSTAPI" ]; then
  bad "WEB_HOSTNAME_API is empty — the web can't reach the API (login/signup fail). Set it to the in-cluster API service (default: ${RELEASE}-api)."
else
  ok "WEB_HOSTNAME_API=$HOSTAPI (web→api, in-cluster)"
fi
# Guide the user: connecting a repo registers this URL as the provider webhook,
# so it must reach the webhooks service at /<provider>/webhook from the Git
# provider. http is fine for a Git server on the same network (the app does not
# require https); localhost never reaches a pod.
any_webhook=""
for entry in API_GITHUB_CODE_MANAGEMENT_WEBHOOK:github:GitHub \
             API_GITLAB_CODE_MANAGEMENT_WEBHOOK:gitlab:GitLab \
             GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK:bitbucket:Bitbucket \
             GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK:azure-repos:Azure-Repos \
             API_FORGEJO_CODE_MANAGEMENT_WEBHOOK:forgejo:Forgejo; do
  key=${entry%%:*}; seg=${entry#*:}; label=${seg#*:}; seg=${seg%%:*}; label=${label//-/ }
  url=$($K get configmap "$CM" -o jsonpath="{.data.$key}" 2>/dev/null)
  [ -z "$url" ] && continue
  any_webhook=1
  path_ok=""
  case "$url" in
    */${seg}/webhook) path_ok=1 ;;
    */azdevops/webhook) [ "$seg" = azure-repos ] && path_ok=1 ;;
  esac
  case "$url" in
    *://localhost*|*://127.0.0.1*|*://0.0.0.0*)
      notprod "$key points at localhost ($url) — the Git provider cannot reach it, so 'save repositories' fails. Use a URL your Git provider reaches, like https://<webhooks-host>/${seg}/webhook." ;;
    http://*|https://*)
      if [ -z "$path_ok" ]; then
        warn "$label webhook path looks off ($url) — expected .../${seg}/webhook"
      elif [ "${url#http://}" != "$url" ]; then
        warn "$label webhook uses http:// ($url) — fine if your Git server reaches it on your network; a Git provider on the internet should get https"
      else
        ok "$label webhook: $url"
      fi ;;
    *)
      bad "$key is not a URL ($url)" \
        "$label cannot be told about new pull requests: saving repositories fails or no webhook is delivered." \
        "Set it to the URL your Git provider uses to reach the webhooks service, like https://<webhooks-host>/${seg}/webhook, and run helm upgrade." ;;
  esac
done
if [ -z "$any_webhook" ]; then
  warn "no Git webhook configured — connecting a repo won't register a webhook. Set API_<PROVIDER>_CODE_MANAGEMENT_WEBHOOK (GLOBAL_ for Bitbucket and Azure Repos) to a URL reaching the webhooks service, e.g. https://<webhooks-host>/github/webhook"
fi
NEXTA=$($K get configmap "$CM" -o jsonpath='{.data.NEXTAUTH_URL}' 2>/dev/null)
case "$NEXTA" in
  "") warn "NEXTAUTH_URL is empty — sign-in still works (the web trusts the request's host), but connecting GitHub through the Kodus GitHub App cannot send you back to Kodus. Set global.config.NEXTAUTH_URL to the web's public URL (https://...) and run helm upgrade" ;;
  https://*) ok "NEXTAUTH_URL is https" ;;
  *localhost*|http://*) warn "NEXTAUTH_URL is http/localhost ($NEXTA) — fine for local trials, must be public HTTPS in production" ;;
esac

# --- PVCs ---
section "Persistent volumes"
# Bundled datastore PVCs come from StatefulSet volumeClaimTemplates, which is
# immutable — so we can't stamp our part-of label on them. The StatefulSet
# controller sets app.kubernetes.io/instance automatically; match on that.
PVCS=$($K get pvc -l "app.kubernetes.io/instance=$RELEASE" --no-headers 2>/dev/null)
if [ -n "$PVCS" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=$(echo "$line" | awk '{print $1}'); phase=$(echo "$line" | awk '{print $2}')
    [ "$phase" = "Bound" ] && ok "pvc $name Bound" || bad "pvc $name is $phase"
  done <<< "$PVCS"
else
  warn "no PVCs labelled for this release (external DBs, or unlabeled bundled claims)"
fi

# --- Disruption budgets ---
# A PDB whose minAvailable equals the number of healthy pods yields
# disruptionsAllowed = 0. That does not slow evictions down — it forbids them
# permanently, so `kubectl drain` blocks forever and node maintenance, cluster
# upgrades and autoscaler compaction all stall. The error names the POD
# ("Cannot evict pod as it would violate the pod's disruption budget"), not the
# PDB, so it reads as an application problem. Every pod stays Running throughout,
# which is why nothing else in this script notices.
section "Disruption budgets"
PDBS=$($K get pdb -l "app.kubernetes.io/part-of=kodus" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.currentHealthy}{"\t"}{.status.disruptionsAllowed}{"\n"}{end}' 2>/dev/null)
if [ -z "$PDBS" ]; then
  ok "no PodDisruptionBudgets for this release (pdb.enabled=false, or every service runs a single replica)"
else
  while IFS=$'\t' read -r name healthy allowed; do
    [ -z "$name" ] && continue
    if [ "${allowed:-0}" = "0" ]; then
      bad "pdb $name allows 0 disruptions (healthy=$healthy) — drain will hang on its pods" \
        "Pods of this service can never be evicted: node drains, cluster upgrades and autoscaler compaction hang." \
        "Raise the service's replicas above 1 (helm upgrade ... --set services.<name>.replicas=2), or drop the PDB."
      echo "      raise the service's replicas above 1, or drop the PDB:"
      echo "      helm upgrade ... --set services.<name>.replicas=2"
    else
      ok "pdb $name allows $allowed disruption(s) (healthy=$healthy)"
    fi
  done <<< "$PDBS"
fi

# --- HTTP health endpoints (from inside each pod) ---
# kubectl exec, not port-forward: a port-forward needs its own permission, a free
# local port and a guessed wait (it was `sleep 3`), so a forbidden or slow one
# read as a dead service. The pod asks itself, at its hostname (the pod IP:
# Next.js may bind that instead of 127.0.0.1), on the port its Deployment
# declares. A probe that cannot run, or times out, is ?, not ✘.
section "Service health endpoints"
# shellcheck disable=SC2016 # JavaScript, not shell
PROBE_JS='const [, port, path] = process.argv;
fetch(`http://${require("os").hostname()}:${port}${path}`, { signal: AbortSignal.timeout(8000), redirect: "manual" })
  .then((r) => console.log(r.status))
  .catch((e) => console.log("ERR:" + ((e && e.cause && e.cause.code) || (e && e.name) || "error")));'
probe() {
  local svc=$1 path=$2 label=$3 impact=$4 soft=${5:-}
  local deploy="${RELEASE}-${svc}" port out
  # mcp-manager down degrades reviews (no MCP tools); the rest stop them.
  down() {
    if [ -n "$soft" ]; then
      echo -e "  ${YELLOW}!${NC} $1"; doctor_add warn infra "" "$1" "$impact" "Check its logs: $K logs deploy/$deploy --tail=200"
    else
      bad "$1" "$impact" "Check its logs: $K logs deploy/$deploy --tail=200"
    fi
  }
  if ! $K get deploy "$deploy" >/dev/null 2>&1; then warn "$label: deployment $deploy not present (disabled?)"; return; fi
  port=$($K get deploy "$deploy" -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}' 2>/dev/null)
  if [ -z "$port" ]; then warn "$label: deployment $deploy declares no container port to probe"; return; fi
  out=$($K exec "deploy/$deploy" -c "$svc" -- node -e "$PROBE_JS" "$port" "$path" 2>&1 | tail -1)
  case "$out" in
    [23][0-9][0-9]) ok "$label ${path} → HTTP $out" ;;
    [0-9][0-9][0-9]) down "$label ${path} → HTTP $out" ;;
    ERR:TimeoutError|ERR:AbortError|ERR:UND_ERR_*TIMEOUT) warn "$label ${path} did not answer within 8s (from inside the pod)" ;;
    ERR:E*) down "$label ${path} → not answering (${out#ERR:})" ;;
    *) warn "couldn't probe $label ${path} from inside its pod: ${out:-no output} (exec not permitted, or no pod running?)" ;;
  esac
}
probe api         /health       "api"         "Nothing can be reviewed, and the review checks cannot run."
probe webhooks    /health/ready "webhooks"    "Kodus is not told about new pull requests, so none is reviewed."
probe mcp-manager /health       "mcp-manager" "Reviews run without the MCP tools your organizations connected." soft
probe web         /api/health   "web"         "Nobody can sign in or change settings."

# --- RabbitMQ resource alarms ---
# A disk/memory alarm silently BLOCKS every publisher: webhook deliveries and
# review jobs stop being enqueued while every pod still reports "Running", so the
# product looks up but nothing happens. The usual trigger is the stock image's
# disk_free_limit being relative to the RAM RabbitMQ detects — in a container that
# is the NODE's RAM, not the pod limit, so on a small PVC the limit is unreachable
# and the alarm never clears. Read-only check via a bundled RabbitMQ pod.
section "RabbitMQ resource alarms"
# Bundled mode runs <release>-rabbitmq-0; the RabbitMQ operator names its pods
# <cluster>-server-N. Both run the Kodus image with a container named rabbitmq.
RMQ_POD="${RELEASE}-rabbitmq-0"
$K get pod "$RMQ_POD" >/dev/null 2>&1 || RMQ_POD="${RELEASE}-rabbitmq-server-0"
if ! $K get pod "$RMQ_POD" >/dev/null 2>&1; then
  RMQ_POD=""
  echo -e "  ${BLUE}‣${NC} no bundled or operator RabbitMQ pod (${RELEASE}-rabbitmq-0 / ${RELEASE}-rabbitmq-server-0) — external broker, skipping"
else
  alarm_out=$($K exec "$RMQ_POD" -c rabbitmq -- rabbitmq-diagnostics -q check_alarms 2>&1)
  alarm_rc=$?
  echo "     $alarm_out"
  if [ $alarm_rc -ne 0 ] && ! echo "$alarm_out" | grep -qi 'alarm on node' \
    && echo "$alarm_out" | grep -qiE "forbidden|cannot exec|not allowed|denied"; then
    warn "couldn't check RabbitMQ alarms (exec not permitted for this user)"
  else
    doctor_check_rabbit_alarms "$alarm_rc" "$alarm_out" \
      "Free disk is below RabbitMQ's limit, which is relative to the RAM it detects: in a container that is the node's RAM, not the pod limit, so a small volume never has enough. Upgrade to a current chart (it sets total_memory_available_override_value) or grow the RabbitMQ volume. Inspect: $K exec $RMQ_POD -c rabbitmq -- rabbitmq-diagnostics status" \
      "RabbitMQ is over its memory limit, usually jobs piling up in a queue nothing takes: $K exec $RMQ_POD -c rabbitmq -- rabbitmqctl list_queues -p kodus-ai name messages consumers; or raise its memory limit."
  fi
fi

# --- Support fingerprint ---
# Printed last and deliberately plain — no colour, no check marks — so it can be
# pasted straight into an issue. It is read from the ConfigMap the chart writes,
# not reconstructed here, so it cannot drift from what is actually installed.
FINGERPRINT=$(
section "Deployment fingerprint (paste this into a support ticket)"
# Plain text/template — range and $k/$v only. `hasPrefix` looks like it belongs
# here but is a sprig function; kubectl's templates are the standard library, so
# the kodus.io/ filter is grep's job.
FP=$($K get configmap "${RELEASE}-config" \
  -o go-template='{{range $k, $v := .metadata.annotations}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null \
  | grep '^kodus\.io/')
if [ -n "$FP" ]; then
  echo "$FP" | sed 's|^kodus\.io/|  |'
  # Not in the ConfigMap: these describe the cluster, not the release.
  echo "  kubernetes=$(kubectl version -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | tail -1)"
  echo "  namespace=$NAMESPACE  release=$RELEASE"
else
  warn "no fingerprint annotations — this release predates them; upgrade the chart"
fi
)

# --- Message queue job time limit ---
section "RabbitMQ consumer_timeout"
# RMQ_POD: the bundled or operator pod found above.
if [ -n "$RMQ_POD" ]; then
  doctor_check_consumer_timeout "$($K exec "$RMQ_POD" -c rabbitmq -- rabbitmqctl eval 'application:get_env(rabbit, consumer_timeout).' 2>/dev/null)"
else
  doctor_add unknown broker.consumer_timeout "" \
    "Could not check the message queue's job time limit (external RabbitMQ)." \
    "" "Make sure consumer_timeout is at least 7200000 (2 hours) on your broker."
fi

# --- Reviews (checks run by the API itself, kodus-ai #1987) ---
section "Reviews"
if $K get deploy "${RELEASE}-api" >/dev/null 2>&1; then
  doctor_run_app_checks "$K exec deploy/${RELEASE}-api --"
else
  doctor_add fail reviews.api "" "The api deployment (${RELEASE}-api) was not found." \
    "Nothing can be reviewed, and the review checks cannot run." \
    "Check the release name (-r) and namespace (-n), or 'helm status $RELEASE'."
fi

doctor_render
[ -n "$FINGERPRINT" ] && { echo; echo -e "$FINGERPRINT"; }

# 1 = reviews do not run, 2 = could not verify (doctor-lib.sh). --profile dev
# keeps the api's own ✘ and UNVERIFIED out of it (see DOCTOR_SOFT_APP_FAILS).
rc=$(doctor_exit_code)
if [ "$rc" = 1 ]; then
  echo -e "${RED}Some checks failed.${NC} Inspect with:  $K get pods,events --sort-by=.lastTimestamp | tail"
fi
exit "$rc"
