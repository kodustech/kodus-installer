#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted SQL and scripts run elsewhere
# A real install of the Kody Runtime on a throwaway Linux VM (OrbStack), from
# this checkout and a kodus-ai checkout, with nothing on AWS:
#   1. control plane: scripts/runtime/install.sh (pins, generate.sh, the
#      Postgres roles, the RabbitMQ user, OpenBao, the hub, the runtime-worker)
#      on the product's own Postgres and RabbitMQ services of docker-compose.yml;
#   2. a registration token, recorded the way the runtime-worker records the
#      API's (the product API is not run: no product image is pulled);
#   3. cell host on the same VM: scripts/runtime/cell-host.sh install with no
#      --profile and no topology (gVisor's runsc by checksum, systemd units),
#      then the cell registers and connects;
#   4. scripts/runtime/smoke.sh: a code sandbox claim boots on the cell under
#      runsc, runs a command, reaches github.com, is refused example.com;
#   5. teardown: cell-host.sh uninstall --purge, uninstall.sh --purge-data,
#      and the VM deleted (unless --keep).
#
# What is not the release: the hub and the runtime-worker run from the kodus-ai
# checkout's source under node:22 (no hub/worker image is published), the cell
# from binaries built from it, the sandbox image is node:22 with the guest
# agent only (the release's tool image is not published), and the builder is
# a stand-in (a sandbox claim builds nothing).
#
# Usage (macOS with OrbStack, from this checkout):
#   scripts/runtime/test-local-install.sh --kodus-ai <kodus-ai checkout> [--machine NAME] [--keep]
# The kodus-ai checkout needs node_modules (a symlink is fine) and Go.
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE_IMAGE=docker.io/library/node:22.23.4-slim

if [ "${1:-}" != --inside ]; then
    KODUS_AI='' MACHINE=kr-runtime-install KEEP=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --kodus-ai) KODUS_AI=$(cd "${2:?}" && pwd); shift 2 ;;
            --machine) MACHINE=${2:?}; shift 2 ;;
            --keep) KEEP=1; shift ;;
            -h | --help) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "unknown argument $1" >&2; exit 2 ;;
        esac
    done
    [ -d "$KODUS_AI/apps/runtime-cell" ] || { echo "--kodus-ai must be a kodus-ai checkout with apps/runtime-cell" >&2; exit 2; }
    command -v orb >/dev/null || { echo "OrbStack (orb) is required" >&2; exit 2; }
    WORK="$ROOT/runtime/state/test-local"
    mkdir -p "$WORK/cellbin"
    if ! orb list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
        orb create ubuntu:noble "$MACHINE"
    fi
    case "$(orb -m "$MACHINE" uname -m)" in
        aarch64 | arm64) GOARCH=arm64 ;;
        x86_64) GOARCH=amd64 ;;
        *) echo "unsupported VM architecture" >&2; exit 2 ;;
    esac
    echo "== building the cell binaries (linux/$GOARCH) from $KODUS_AI"
    (cd "$KODUS_AI/apps/runtime-cell" && for c in cell egress resolver injector injector-admin observer reaper kody-exec kody-guest; do
        CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH go build -trimpath -ldflags "-s -w" -o "$WORK/cellbin/$c" "./cmd/$c"
    done)
    rc=0
    orb -m "$MACHINE" -u root bash "$SELF" --inside "$KODUS_AI" "$WORK" || rc=$?
    if [ "$KEEP" = 0 ]; then
        orb delete -f "$MACHINE" >/dev/null && echo "== VM $MACHINE deleted"
    else
        echo "== VM $MACHINE kept (orb delete -f $MACHINE)"
    fi
    exit "$rc"
fi

# --- inside the VM, as root -----------------------------------------------------
KODUS_AI=$2 WORK=$3
export DEBIAN_FRONTEND=noninteractive
step() { printf '\n== %s\n' "$*"; }
step "host packages"
command -v docker >/dev/null || { apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends docker.io >/dev/null; }
apt-get install -y -qq --no-install-recommends curl openssl bzip2 ca-certificates jq >/dev/null
docker compose version >/dev/null 2>&1 || apt-get install -y -qq --no-install-recommends docker-compose-v2 >/dev/null
IP=$(hostname -I | awk '{print $1}')
# Cells upload evidence to a one-label name or https (never an IP literal).
grep -q ' kodus-runtime-evidence$' /etc/hosts || echo "$IP kodus-runtime-evidence" >>/etc/hosts
BRIDGE=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
echo "VM $IP, Docker $(docker version --format '{{.Server.Version}}'), bridge $BRIDGE, kernel $(uname -r), /dev/kvm: $([ -c /dev/kvm ] && echo yes || echo no)"

step "installer copy and a synthetic .env (from .env.example)"
KI=/opt/kodus-installer
if [ -d "$KI" ]; then
    # A --keep'd VM from an earlier run: this VM is the test's own, so
    # everything of that run goes (cell, containers, volumes).
    "$KI/scripts/runtime/cell-host.sh" uninstall --purge >/dev/null 2>&1 || true
    docker ps -aq | xargs -r docker rm -f >/dev/null
    docker volume ls -q | xargs -r docker volume rm >/dev/null
fi
rm -rf "$KI" && mkdir -p "$KI"
(cd "$ROOT" && tar -cf - --exclude ./runtime/state --exclude ./.git .) | tar -C "$KI" -xf -
cd "$KI"
cp .env.example .env
PGPW=$(openssl rand -hex 16) MQPW=$(openssl rand -hex 16)
sed -i -e "s|^IMAGE_TAG=.*|IMAGE_TAG=unreleased|" -e "s|^API_PG_DB_PASSWORD=.*|API_PG_DB_PASSWORD=$PGPW|" \
    -e "s|^RABBITMQ_DEFAULT_PASS=.*|RABBITMQ_DEFAULT_PASS=$MQPW|" \
    -e "s|^API_RABBITMQ_URI=.*|API_RABBITMQ_URI=amqp://kodus:$MQPW@rabbitmq:5672/kodus-ai|" .env
grep -q '^IMAGE_TAG=' .env || echo 'IMAGE_TAG=unreleased' >>.env

step "images: hub and worker from source, the test sandbox image"
docker pull -q "$NODE_IMAGE" >/dev/null
docker tag "$NODE_IMAGE" kodus-runtime-hub:source
docker tag "$NODE_IMAGE" kodus-runtime-worker:source
SB=$(mktemp -d)
cp "$WORK/cellbin/kody-guest" "$SB/kody-guest"
printf 'FROM %s\nCOPY kody-guest /usr/local/bin/kody-guest\nUSER 1000\n' "$NODE_IMAGE" >"$SB/Dockerfile"
docker build -q -t kodus-test-sandbox:local "$SB" >/dev/null
NM=$(readlink -f "$KODUS_AI/node_modules")
cat >"$WORK/compose.source.yml" <<EOF
# Test only: the hub and the runtime-worker from the kodus-ai checkout's source
# (the volumes merge with docker-compose.runtime.yml's by target).
services:
  runtime-hub:
    working_dir: /app
    command: ["node", "-r", "ts-node/register/transpile-only", "-r", "tsconfig-paths/register", "apps/runtime/src/hub/main.ts"]
    environment:
      TS_NODE_PROJECT: apps/runtime/tsconfig.json
      TS_NODE_TRANSPILE_ONLY: "true"
      # The release builds with webpack, which resolves ./taxonomy to the .ts;
      # plain Node tries taxonomy.json first unless ts-node prefers .ts.
      TS_NODE_PREFER_TS_EXTS: "true"
    volumes:
      - $KODUS_AI:/app:ro
      - $NM:/app/node_modules:ro
  runtime-worker:
    working_dir: /app
    command: ["node", "-r", "ts-node/register/transpile-only", "-r", "tsconfig-paths/register", "apps/runtime/src/worker/main.ts"]
    environment:
      TS_NODE_PROJECT: apps/runtime/tsconfig.json
      TS_NODE_TRANSPILE_ONLY: "true"
      # The release builds with webpack, which resolves ./taxonomy to the .ts;
      # plain Node tries taxonomy.json first unless ts-node prefers .ts.
      TS_NODE_PREFER_TS_EXTS: "true"
    volumes:
      - $KODUS_AI:/app:ro
      - $NM:/app/node_modules:ro
EOF
export KODUS_RUNTIME_COMPOSE_EXTRA="$WORK/compose.source.yml"
export KODUS_RUNTIME_HUB_IMAGE=kodus-runtime-hub:source KODUS_RUNTIME_WORKER_IMAGE=kodus-runtime-worker:source

step "control plane: scripts/runtime/install.sh"
export KODUS_RUNTIME_TEST_NO_PRODUCT=1
scripts/runtime/install.sh --release unreleased --cell-profile docker-gvisor \
    --hub-host "$IP" --openbao-host "$BRIDGE" --openbao-bind "$BRIDGE" --evidence-url http://kodus-runtime-evidence:3420

step "the exchanges the product's API declares at its boot (no product here)"
MQU=$(grep '^RABBITMQ_DEFAULT_USER=' .env | cut -d= -f2)
mqadmin() { scripts/runtime/compose.sh exec -T rabbitmq rabbitmqadmin -u "$MQU" -p "$MQPW" -V kodus-ai "$@"; }
mqadmin declare exchange name=workflow.exchange type=topic durable=true
mqadmin declare exchange name=workflow.exchange.dlx type=topic durable=true
mqadmin declare exchange name=workflow.exchange.runtime_retry type=headers durable=true
mqadmin declare exchange name=workflow.exchange.runtime_retry.return type=direct durable=true
for i in $(seq 1 60); do
    scripts/runtime/compose.sh exec -T runtime-worker node -e "require('net').connect(3430,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))" 2>/dev/null && break
    [ "$i" = 60 ] && { scripts/runtime/compose.sh logs --tail 30 runtime-worker; echo "FAILED the runtime-worker's sandbox listener never opened"; exit 1; }
    sleep 5
done
echo "runtime-worker: sandbox listener open"

step "a registration token for a synthetic organization (as the runtime-worker records the API's)"
ORG=$(cat /proc/sys/kernel/random/uuid)
TOKEN="kcr_$(openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
HASH=$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)
sql() { scripts/runtime/compose.sh exec -T db_kodus_postgres psql -U kodusdev -d kodus_runtime -Atq -v ON_ERROR_STOP=1 "$@"; }
sql -c "INSERT INTO runtime.runtime_cell_tokens (token_hash, organization_id, topology, expires_at, issued_by)
        VALUES ('$HASH', '$ORG', 'self_hosted', now() + interval '15 minutes', 'test-local-install')"

step "cell host: scripts/runtime/cell-host.sh install (no --profile, no topology)"
CELL_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
export KODUS_RUNTIME_SANDBOX_IMAGE=kodus-test-sandbox:local
# A sandbox claim builds nothing; the release's builder is not published yet.
KODUS_RUNTIME_BUILDER_IMAGE=$(awk -F '\t' '$1 == "any" && $2 == "holder" { print $3 }' runtime/images.lock)
export KODUS_RUNTIME_BUILDER_IMAGE
# A throwaway VM's disk: 5 GB is enough for a sandbox claim (the 20 GB floor is the build state's).
KODUS_CELL_REGISTRATION_TOKEN=$TOKEN scripts/runtime/cell-host.sh install --bundle runtime/state/cell-host --cell-bin-dir "$WORK/cellbin" \
    --min-free-gb "${KODUS_TEST_MIN_FREE_GB:-5}"
CELL_ID=$(grep '^CELL_ID=' /etc/kodus/cell/cell.env | cut -d= -f2)

step "the cell registers and connects"
for i in $(seq 1 60); do
    [ "$(sql -c "SELECT status FROM runtime.runtime_cells WHERE cell_id = '$CELL_ID'")" = connected ] && break
    [ "$i" = 60 ] && { journalctl -u kodus-cell --no-pager | tail -40; echo "FAILED the cell did not connect"; exit 1; }
    sleep 5
done
sql -c "SELECT 'cell ' || cell_id || ': org ' || organization_id || ', owner ' || owner || ', topology ' || topology || ', ' || status FROM runtime.runtime_cells WHERE cell_id = '$CELL_ID'"
sql -c "SELECT 'token used at ' || used_at FROM runtime.runtime_cell_tokens WHERE token_hash = '$HASH'"
journalctl -u kodus-cell --no-pager -o cat --since "$CELL_SINCE" | grep -E '"msg":"(isolation.backend|cell.start|memory.admission|machine_trust.ready)"' | head -5 || true
grep -E '^  (ca|localCa):' /etc/kodus/cell/cell.yaml

step "the cell takes work: its heartbeat reports free slots"
for i in $(seq 1 60); do
    [ "$(sql -c "SELECT coalesce(max(free_slots), 0) FROM runtime.runtime_cell_sessions WHERE cell_id = '$CELL_ID'")" -gt 0 ] 2>/dev/null && break
    [ "$i" = 60 ] && { journalctl -u kodus-cell --no-pager -o cat --since "$CELL_SINCE" | tail -20; echo "FAILED the cell never reported free slots"; exit 1; }
    sleep 5
done
sql -c "SELECT 'free slots ' || free_slots FROM runtime.runtime_cell_sessions WHERE cell_id = '$CELL_ID'"

step "a sandbox claim boots on the cell: scripts/runtime/smoke.sh"
# Which OCI runtime the claim's containers run under, seen while they exist.
( for _ in $(seq 1 240); do
    docker ps -q --filter "label=kodus.cell=$CELL_ID" | xargs -r docker inspect -f '{{.Name}} runtime={{.HostConfig.Runtime}} image={{.Config.Image}}'
    sleep 0.5
done ) >"$WORK/claim-containers.txt" 2>/dev/null &
WATCH=$!
scripts/runtime/smoke.sh --org "$ORG"
kill "$WATCH" 2>/dev/null || true
sort -u "$WORK/claim-containers.txt"
sql -c "SELECT 'sandbox audit rows: ' || count(*) FROM runtime.runtime_sandbox_audit WHERE org_id = '$ORG'" || true

step "teardown"
scripts/runtime/cell-host.sh uninstall --purge --remove-runsc
scripts/runtime/uninstall.sh --purge-data --i-have-a-backup
scripts/runtime/compose.sh down -v --remove-orphans >/dev/null 2>&1 || true
[ -z "$(docker ps -aq --filter "label=kodus.cell=$CELL_ID")" ] && echo "no container of cell $CELL_ID is left"
echo "PASSED install, registration, sandbox claim, teardown"
