#!/usr/bin/env bash
# scripts/doctor-k8s.sh
# Health check for a Kodus Helm deployment (Kubernetes / OpenShift).
# Parallel to doctor.sh (Docker Compose). Read-only: it inspects the cluster and
# probes the real health endpoints, never mutating anything.
#
# Usage:
#   ./scripts/doctor-k8s.sh [-n <namespace>] [-r <release>]
# Defaults: namespace = current kubectl context, release = kodus

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

ok()   { echo -e "  ${GREEN}✔${NC} $1"; PASS=$((PASS+1)); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; WARN=$((WARN+1)); }
bad()  { echo -e "  ${RED}✘${NC} $1"; FAIL=$((FAIL+1)); }
section() { echo -e "\n${BLUE}== $1 ==${NC}"; }

RELEASE="kodus"
NAMESPACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [-n namespace] [-r release]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Prerequisites ---
section "Prerequisites"
if ! command -v kubectl >/dev/null 2>&1; then
  bad "kubectl not found"; echo "Install kubectl and configure access to your cluster."; exit 1
fi
ok "kubectl present ($(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | head -1 | cut -d'"' -f4))"
if ! kubectl cluster-info >/dev/null 2>&1; then
  bad "cannot reach a cluster (check your kubeconfig/context)"; exit 1
fi
ok "cluster reachable ($(kubectl config current-context 2>/dev/null))"

if [ -z "$NAMESPACE" ]; then
  NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  [ -z "$NAMESPACE" ] && NAMESPACE="default"
fi
if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  bad "namespace '$NAMESPACE' not found"; exit 1
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
  warn "no migration job found (ttl-cleaned, or migrations.enabled=false)"
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
fi

# --- Pods ---
section "Pod health"
BADPODS=$($K get pods -l "$SEL" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1" ("$3")"}')
RESTARTS=$($K get pods -l "$SEL" --no-headers 2>/dev/null | awk '$4>5 {print $1" (restarts="$4")"}')
if [ -z "$($K get pods -l "$SEL" --no-headers 2>/dev/null)" ]; then
  warn "no pods match selector"
else
  if [ -z "$BADPODS" ]; then
    ok "all pods Running/Completed"
  else
    while IFS= read -r p; do [ -n "$p" ] && bad "pod not ready: $p"; done <<< "$BADPODS"
  fi
  if [ -n "$RESTARTS" ]; then
    while IFS= read -r p; do [ -n "$p" ] && warn "high restart count: $p"; done <<< "$RESTARTS"
  fi
fi

# --- Config & Secrets ---
section "Config & Secrets"
$K get configmap "${RELEASE}-config" >/dev/null 2>&1 && ok "configmap ${RELEASE}-config present" || bad "configmap ${RELEASE}-config missing"
if $K get secret "${RELEASE}-secrets" >/dev/null 2>&1; then
  # API_CRYPTO_KEY must decode to 64 hex chars (32 bytes) or the app crash-loops.
  CK=$($K get secret "${RELEASE}-secrets" -o jsonpath='{.data.API_CRYPTO_KEY}' 2>/dev/null | base64 -d 2>/dev/null)
  if echo "$CK" | grep -qE '^[0-9a-f]{64}$'; then ok "app secrets present; API_CRYPTO_KEY is valid 32-byte hex"; else bad "API_CRYPTO_KEY is not 32-byte hex (app will crash: 'must be 32 bytes in hexadecimal')"; fi
else
  warn "secret ${RELEASE}-secrets not found (using existingSecret/externalSecrets?)"
fi

# --- Config sanity (the class of error the UI hits on "save repositories") ---
section "Config sanity (Git webhooks reachability)"
CM="${RELEASE}-config"
HOSTAPI=$($K get configmap "$CM" -o jsonpath='{.data.WEB_HOSTNAME_API}' 2>/dev/null)
case "$HOSTAPI" in
  localhost|127.0.0.1|0.0.0.0|"")
    warn "WEB_HOSTNAME_API='${HOSTAPI:-<empty>}' — Git providers cannot reach it, so enabling repos (webhook registration) WILL fail with 'Error saving repositories'. Set a PUBLIC hostname in production." ;;
  *) ok "WEB_HOSTNAME_API=$HOSTAPI (public-looking)" ;;
esac
for prov in GITHUB GITLAB; do
  key="API_${prov}_CODE_MANAGEMENT_WEBHOOK"
  url=$($K get configmap "$CM" -o jsonpath="{.data.$key}" 2>/dev/null)
  [ -z "$url" ] && continue
  case "$url" in
    https://*localhost*|http://*) warn "$prov webhook not publicly usable (http or localhost): $url" ;;
    https://*) ok "$prov webhook uses https ($url)" ;;
  esac
done
NEXTA=$($K get configmap "$CM" -o jsonpath='{.data.NEXTAUTH_URL}' 2>/dev/null)
case "$NEXTA" in
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

# --- HTTP health endpoints (via port-forward) ---
section "Service health endpoints"
probe() {
  local svc=$1 port=$2 path=$3 label=$4
  if ! $K get svc "$svc" >/dev/null 2>&1; then warn "$label: service $svc not present (disabled?)"; return; fi
  local lport=$(( (RANDOM % 10000) + 20000 ))
  kubectl -n "$NAMESPACE" port-forward "svc/$svc" "$lport:$port" >/dev/null 2>&1 &
  local pf=$!
  sleep 3
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${lport}${path}" 2>/dev/null)
  kill "$pf" >/dev/null 2>&1; wait "$pf" 2>/dev/null
  if echo "$code" | grep -qE '^(2|3)[0-9][0-9]$'; then ok "$label ${path} → HTTP $code"; else bad "$label ${path} → HTTP ${code:-no-response}"; fi
}
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not found — skipping endpoint probes"
else
  probe "${RELEASE}-api"         3001 /health        "api"
  probe "${RELEASE}-webhooks"    3332 /health/ready  "webhooks"
  probe "${RELEASE}-mcp-manager" 3101 /health        "mcp-manager"
  probe "${RELEASE}-web"         3000 /              "web"
fi

# --- Summary ---
section "Summary"
echo -e "  ${GREEN}${PASS} ok${NC}   ${YELLOW}${WARN} warn${NC}   ${RED}${FAIL} fail${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}Some checks failed.${NC} Inspect with:  $K get pods,events --sort-by=.lastTimestamp | tail"
  exit 1
fi
echo -e "${GREEN}Kodus looks healthy.${NC}"
