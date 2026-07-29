#!/usr/bin/env bash
# scripts/test-kind.sh
# End-to-end smoke test of the Helm chart on a local kind cluster.
# Spins up a real (single-node) Kubernetes cluster in Docker, installs Kodus in
# bundled mode (Postgres + Mongo + RabbitMQ come up as StatefulSets — no operators
# or external services needed), waits for rollout, runs the doctor + `helm test`,
# and reports. Nothing here touches a real/remote cluster.
#
# Usage:
#   ./scripts/test-kind.sh                 # create cluster, install, verify
#   ./scripts/test-kind.sh --tag 2.1.27    # pin a real release (default: latest)
#   ./scripts/test-kind.sh --cleanup       # delete the kind cluster and exit
#   ./scripts/test-kind.sh --keep          # leave the cluster running afterwards
#   ./scripts/test-kind.sh --strict        # exit non-zero if doctor or helm test fails
#   ./scripts/test-kind.sh --timeout 10m   # per-deploy rollout budget (default 12m)
#   ./scripts/test-kind.sh --upgrade-from origin/main
#                                          # install THAT ref's chart first, then
#                                          # upgrade to the working tree
#
# --strict is what CI runs. Interactively the default is lenient: you want to see
# every problem and then poke at the cluster. In CI a swallowed failure is a green
# build over a broken install, which is worse than no test at all.
#
# --upgrade-from covers the failure this chart cannot recover from. Several fields
# are immutable once created — StatefulSet.spec.serviceName, Service.clusterIP,
# Deployment.spec.selector — so a change that installs perfectly on an empty
# cluster can still break `helm upgrade` for every existing user, and a fresh
# install will never show it.
#
# Requires: docker, kind, kubectl, helm. --upgrade-from also needs git.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
CLUSTER="kodus-test"
NS="kodus"
RELEASE="kodus"
TAG="latest"
TIMEOUT="12m"
KEEP="false"
CLEANUP_ONLY="false"
STRICT="false"
UPGRADE_FROM=""
WORKTREE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --keep) KEEP="true"; shift ;;
    --cleanup) CLEANUP_ONLY="true"; shift ;;
    --strict) STRICT="true"; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --upgrade-from) UPGRADE_FROM="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

section() { echo -e "\n${BLUE}== $1 ==${NC}"; }
die()     { echo -e "${RED}✘ $1${NC}"; exit 1; }
# Non-fatal by default so an interactive run surfaces every problem at once;
# fatal under --strict so CI cannot go green over a broken install.
soft_fail() {
  if [ "$STRICT" = "true" ]; then die "$1"; else echo -e "${YELLOW}! $1${NC}"; fi
}
cleanup_worktree() {
  [ -n "$WORKTREE" ] && git worktree remove --force "$WORKTREE" >/dev/null 2>&1
  WORKTREE=""
}
trap cleanup_worktree EXIT

# --- Prerequisites ---
section "Prerequisites"
for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found. Install it first (brew install $bin)."
  echo -e "  ${GREEN}✔${NC} $bin"
done
docker info >/dev/null 2>&1 || die "Docker daemon is not running."

if [ "$CLEANUP_ONLY" = "true" ]; then
  section "Cleanup"
  kind delete cluster --name "$CLUSTER" && echo -e "${GREEN}Cluster '$CLUSTER' deleted.${NC}"
  exit 0
fi

# --- Cluster ---
section "kind cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo -e "  ${YELLOW}!${NC} cluster '$CLUSTER' already exists — reusing"
else
  kind create cluster --name "$CLUSTER" || die "failed to create kind cluster"
fi
kubectl cluster-info --context "kind-$CLUSTER" >/dev/null 2>&1 || die "cannot reach the kind cluster"
kubectl config use-context "kind-$CLUSTER" >/dev/null 2>&1
echo -e "  ${GREEN}✔${NC} context: kind-$CLUSTER"

# --- Install ---
diagnose() {
  section "$1 — diagnostics"
  kubectl get pods -n "$NS" -o wide
  echo ""; kubectl get events -n "$NS" --sort-by=.lastTimestamp | tail -20
  echo ""
  for p in $(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print $1}'); do
    echo -e "${YELLOW}--- logs: $p ---${NC}"; kubectl logs "$p" -n "$NS" --tail 30 --all-containers 2>/dev/null
  done
}

# Deploys a chart directory and waits for it to converge. $1 = chart path,
# $2 = label for messages.
deploy() {
  helm dependency build "$1" >/dev/null 2>&1 || die "helm dependency build failed for $1"
  set -x
  helm upgrade --install "$RELEASE" "$1" \
    -f "$1/values.yaml" -f "$1/values-dev.yaml" \
    --set imageTag="$TAG" \
    -n "$NS" --create-namespace \
    --wait --timeout "$TIMEOUT"
  rc=$?
  set +x
  if [ $rc -ne 0 ]; then
    diagnose "$2 did not converge"
    die "$2 failed to become ready within $TIMEOUT (see diagnostics above)."
  fi
  echo -e "${GREEN}$2 converged.${NC}"
}

# Optional baseline: install the chart as it exists at another git ref, so the
# real install below runs as an UPGRADE over it. A worktree (not a checkout)
# keeps the working tree untouched.
if [ -n "$UPGRADE_FROM" ]; then
  section "baseline install from $UPGRADE_FROM"
  command -v git >/dev/null 2>&1 || die "--upgrade-from needs git"
  git rev-parse --verify "$UPGRADE_FROM" >/dev/null 2>&1 || die "unknown git ref: $UPGRADE_FROM"
  # git worktree wants to create the directory itself.
  WORKTREE="$(mktemp -d)/chart"
  git worktree add --detach "$WORKTREE" "$UPGRADE_FROM" >/dev/null 2>&1 \
    || die "could not create a worktree at $UPGRADE_FROM"
  echo -e "  baseline chart: ${YELLOW}$(git -C "$WORKTREE" rev-parse --short HEAD)${NC}"
  deploy "$WORKTREE/charts/kodus" "baseline install"
fi

if [ -n "$UPGRADE_FROM" ]; then
  section "helm upgrade onto the baseline (bundled, tag=$TAG)"
else
  section "helm install (bundled, tag=$TAG)"
  echo -e "  ${YELLOW}pulling images + starting pods (can take a few minutes on first run)...${NC}"
fi
deploy charts/kodus "install"
cleanup_worktree

# --- Verify ---
section "Doctor"
# --profile dev: this always installs with values-dev.yaml, which points the
# webhook URL at localhost on purpose. Health checks stay strict; only the
# "this config is not production-grade" findings drop to warnings.
./scripts/doctor-k8s.sh -n "$NS" -r "$RELEASE" --profile dev \
  || soft_fail "doctor reported issues (see above)"

section "helm test"
if ! helm test "$RELEASE" -n "$NS" --logs 2>&1 | tail -40; then
  diagnose "helm test failed"
  soft_fail "helm test reported issues"
fi

# --- Access ---
section "Access the UI"
# Use 13000 locally to avoid clashing with a docker-compose Kodus already on :3000.
echo "  kubectl port-forward -n $NS svc/${RELEASE}-web 13000:3000"
echo "  then open http://localhost:13000"

# --- Cleanup ---
if [ "$KEEP" = "true" ]; then
  echo -e "\n${YELLOW}Cluster kept running. Tear down with: $0 --cleanup${NC}"
else
  section "Cleanup"
  echo -e "  ${YELLOW}Deleting the kind cluster (use --keep to leave it up)...${NC}"
  kind delete cluster --name "$CLUSTER"
fi
