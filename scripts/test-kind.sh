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
#   ./scripts/test-kind.sh --tag 2.1.24    # pin a real release (default: latest)
#   ./scripts/test-kind.sh --cleanup       # delete the kind cluster and exit
#   ./scripts/test-kind.sh --keep          # leave the cluster running afterwards
#
# Requires: docker, kind, kubectl, helm.

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

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --keep) KEEP="true"; shift ;;
    --cleanup) CLEANUP_ONLY="true"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

section() { echo -e "\n${BLUE}== $1 ==${NC}"; }
die()     { echo -e "${RED}✘ $1${NC}"; exit 1; }

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
section "helm install (bundled, tag=$TAG)"
helm dependency build charts/kodus >/dev/null 2>&1 || die "helm dependency build failed"
echo -e "  ${YELLOW}pulling images + starting pods (can take a few minutes on first run)...${NC}"
set -x
helm upgrade --install "$RELEASE" charts/kodus \
  -f charts/kodus/values.yaml -f charts/kodus/values-dev.yaml \
  --set imageTag="$TAG" \
  -n "$NS" --create-namespace \
  --wait --timeout "$TIMEOUT"
rc=$?
set +x

if [ $rc -ne 0 ]; then
  section "Install did not converge — diagnostics"
  kubectl get pods -n "$NS" -o wide
  echo ""; kubectl get events -n "$NS" --sort-by=.lastTimestamp | tail -20
  echo ""
  for p in $(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print $1}'); do
    echo -e "${YELLOW}--- logs: $p ---${NC}"; kubectl logs "$p" -n "$NS" --tail 30 --all-containers 2>/dev/null
  done
  die "helm install failed to become ready within $TIMEOUT (see diagnostics above)."
fi
echo -e "${GREEN}Install converged.${NC}"

# --- Verify ---
section "Doctor"
./scripts/doctor-k8s.sh -n "$NS" -r "$RELEASE" || echo -e "${YELLOW}doctor reported issues (see above)${NC}"

section "helm test"
helm test "$RELEASE" -n "$NS" 2>&1 | tail -6 || echo -e "${YELLOW}helm test reported issues${NC}"

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
