#!/usr/bin/env bash
# Installs the Kody Runtime control plane next to a running Kodus compose
# install (docs/runtime.md): OpenBao, the hub and the runtime-worker, the
# Runtime's Postgres roles and RabbitMQ user, and the Runtime env of the API
# and the worker. Re-run it to upgrade (scripts/runtime/upgrade.sh does) or
# to change a setting; it keeps every generated secret.
#
# Usage: scripts/runtime/install.sh --cell-profile <profile> --hub-host <host> [options]
#   --cell-profile docker-gvisor | docker-firecracker | kubernetes
#                     how this install's cells will run (cell-host.sh checks the
#                     host itself before a cell starts)
#   --release <r>     the product release whose Runtime images to pin
#                     (default: IMAGE_TAG of .env; `unreleased` for local builds)
#   --check           resolve and validate only; start nothing
#   every option of scripts/runtime/generate.sh (--hub-host, --openbao-host, ...)
#
# Test hook (never on a real install): KODUS_RUNTIME_TEST_NO_PRODUCT=1 leaves
# the product's api and worker out (and so their read grants), for
# scripts/runtime/test-local-install.sh, which has no product images.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; }

PROFILE='' RELEASE="${KODUS_RUNTIME_RELEASE:-}" CHECK_ONLY=0 GEN_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --cell-profile) PROFILE=${2:?}; shift 2 ;;
        --release) RELEASE=${2:?}; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        -h | --help) usage; exit 0 ;;
        --rotate-certs) GEN_ARGS+=("$1"); shift ;;
        --*) GEN_ARGS+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
        *) rt_die "unknown argument $1 (see --help)" ;;
    esac
done

ENV_FILE="$RT_ROOT/.env"
[ -f "$ENV_FILE" ] || rt_die ".env not found: install Kodus first (docs/compose.md)"
docker compose version >/dev/null 2>&1 || rt_die "the Runtime needs Docker Compose v2 (docker compose)"

[ -n "$PROFILE" ] || PROFILE=$(rt_env_get "$RT_STATE/compose.env" KODUS_RUNTIME_CELL_PROFILE)
case "$PROFILE" in
    docker-gvisor | docker-firecracker | kubernetes) ;;
    '') rt_die "--cell-profile is required: docker-gvisor, docker-firecracker or kubernetes (docs/runtime.md, Profiles)" ;;
    *) rt_die "unknown cell profile '$PROFILE': docker-gvisor, docker-firecracker or kubernetes" ;;
esac

[ -n "$RELEASE" ] || RELEASE=$(rt_env_get "$RT_STATE/compose.env" KODUS_RUNTIME_RELEASE)
[ -n "$RELEASE" ] || RELEASE=$(rt_env_get "$ENV_FILE" IMAGE_TAG)
case "$RELEASE" in
    '' | latest) rt_die "pin the product release: IMAGE_TAG=<release> in .env, or --release (the Runtime images are pinned per release; 'latest' has no row in runtime/compatibility.tsv)" ;;
esac

# --- the release and its images ---------------------------------------------
CELL_RELEASE=$(rt_cell_release_for "$RELEASE" "${KODUS_RUNTIME_CELL_RELEASE:-}")
[ -n "$CELL_RELEASE" ] || rt_die "no cell release in runtime/compatibility.tsv speaks the protocol of the hub of $RELEASE"
BACKENDS=$(rt_cell_backends "$CELL_RELEASE")
case "$PROFILE" in
    docker-gvisor)
        rt_protocol_fits gvisor "$BACKENDS" || rt_die "cell release $CELL_RELEASE has no gvisor backend (it has: $BACKENDS)" ;;
    docker-firecracker)
        rt_protocol_fits firecracker "$BACKENDS" ||
            rt_warn "docker-firecracker: cell release $CELL_RELEASE has no firecracker backend (phase P2). The control plane installs, but cell-host.sh refuses to start a cell of this profile." ;;
    kubernetes)
        rt_warn "kubernetes: the cell installs with Helm (charts/kodus-runtime, cell.enabled) against this control plane; see docs/runtime.md, Kubernetes." ;;
esac

HUB_IMAGE=$(rt_image "$RELEASE" hub)
WORKER_IMAGE=$(rt_image "$RELEASE" worker)
OPENBAO_IMAGE=$(rt_image "$RELEASE" openbao)
case "$WORKER_IMAGE" in
    *@sha256:*) d=${WORKER_IMAGE##*@sha256:}; RELEASE_VERSION="$RELEASE-${d:0:12}" ;;
    *)
        id=$(docker image inspect --format '{{.Id}}' "$WORKER_IMAGE" 2>/dev/null) ||
            rt_die "$WORKER_IMAGE is not a digest and is not in the local Docker: build it first (docs/runtime.md)"
        id=${id#sha256:}
        RELEASE_VERSION="local-${id:0:12}"
        ;;
esac
rt_info "Release $RELEASE, cell release $CELL_RELEASE, profile $PROFILE"
rt_info "  hub     $HUB_IMAGE"
rt_info "  worker  $WORKER_IMAGE"
rt_info "  openbao $OPENBAO_IMAGE"

# --- generated material -----------------------------------------------------
"$RT_SCRIPTS_DIR/generate.sh" ${GEN_ARGS[@]+"${GEN_ARGS[@]}"}
umask 077
{
    cat "$RT_STATE/settings.env"
    echo "KODUS_RUNTIME_RELEASE=$RELEASE"
    echo "KODUS_RUNTIME_CELL_RELEASE=$CELL_RELEASE"
    echo "KODUS_RUNTIME_CELL_PROFILE=$PROFILE"
    echo "KODUS_RUNTIME_RELEASE_VERSION=$RELEASE_VERSION"
    echo "KODUS_RUNTIME_HUB_IMAGE=$HUB_IMAGE"
    echo "KODUS_RUNTIME_WORKER_IMAGE=$WORKER_IMAGE"
    echo "KODUS_RUNTIME_OPENBAO_IMAGE=$OPENBAO_IMAGE"
} >"$RT_STATE/compose.env"
[ "$(id -u)" = 0 ] && chown 1000:1000 "$RT_STATE/compose.env"
# The cell release that fits this hub, for cell-host.sh --bundle (once).
conf="$RT_STATE/cell-host/cell-host.conf"
grep -v '^KODUS_RUNTIME_CELL_RELEASE=' "$conf" >"$conf.new" || true
printf 'KODUS_RUNTIME_CELL_RELEASE=%s\n' "$CELL_RELEASE" >>"$conf.new"
mv "$conf.new" "$conf"
[ "$(id -u)" = 0 ] && chown 1000:1000 "$conf"

rt_compose config -q || rt_die "docker compose rejected the Runtime configuration"
rt_ok "Configuration valid."
[ "$CHECK_ONLY" = 1 ] && exit 0

# --- start ------------------------------------------------------------------
use_local_db=$(rt_env_get "$ENV_FILE" USE_LOCAL_DB)
use_local_mq=$(rt_env_get "$ENV_FILE" USE_LOCAL_RABBITMQ)
docker network create shared-network >/dev/null 2>&1 || true
docker network create monitoring-network >/dev/null 2>&1 || true
docker network create kodus-backend-services >/dev/null 2>&1 || true
[ "${use_local_db:-true}" = false ] || rt_compose up -d --wait db_kodus_postgres
[ "${use_local_mq:-true}" = false ] || rt_compose up -d --wait rabbitmq

rt_info "Postgres roles and databases..."
RUNTIME_INIT_MODE=roles rt_compose run --rm runtime-init

rt_info "RabbitMQ user kodus_runtime..."
MQ_URI=$(rt_env_get "$ENV_FILE" API_RABBITMQ_URI)
VHOST=$(rt_url_part "$MQ_URI" path)
MQ_PW=$(rt_env_get "$RT_STATE/secrets.env" RUNTIME_MQ_PASSWORD)
Q='workflow\.jobs\.runtime_(run|control)\.queue'
# The retry exchange, and the dead-letter exchange its queues name: RabbitMQ
# checks write access to a queue's x-dead-letter-exchange at every declare.
D='workflow\.exchange\.runtime_run_retry|workflow\.exchange\.dlx'
if [ "${use_local_mq:-true}" = false ]; then
    rt_warn "external RabbitMQ: create user kodus_runtime on vhost '$VHOST' with the password RUNTIME_MQ_PASSWORD of $RT_STATE/secrets.env and the permissions in docs/runtime.md (RabbitMQ), then re-run."
else
    if ! rt_compose exec -T rabbitmq rabbitmqctl -q list_users | grep -qw kodus_runtime; then
        # The password goes in on stdin, never on this host's command line.
        # shellcheck disable=SC2016 # expanded by the container's shell
        printf '%s\n' "$MQ_PW" | rt_compose exec -T rabbitmq sh -c 'IFS= read -r pw && exec rabbitmqctl -q add_user kodus_runtime "$pw"' >/dev/null
    fi
    # configure, write, read: only its own queues; publish on the product
    # exchange only with the RUNTIME_PUBLISH routing key (kodus-ai
    # scripts/runtime/dev-runtime-users.sh).
    rt_compose exec -T rabbitmq rabbitmqctl -q set_permissions -p "$VHOST" kodus_runtime \
        "^(${Q}|amq\.gen-.*)\$" "^(workflow\.exchange|${D}|${Q}|amq\.gen-.*)\$" "^(workflow\.exchange|${Q}|amq\.gen-.*)\$" >/dev/null
    rt_compose exec -T rabbitmq rabbitmqctl -q set_topic_permissions -p "$VHOST" kodus_runtime workflow.exchange \
        '^workflow\.jobs\.created\.RUNTIME_PUBLISH$' '^workflow\.jobs\.(\*|created)\.RUNTIME_(RUN|CONTROL)$' >/dev/null
fi

rt_info "OpenBao..."
rt_compose up -d --wait runtime-openbao
rt_info "Runtime hub (applies the Runtime migrations)..."
rt_compose up -d --wait runtime-hub
if [ "${KODUS_RUNTIME_TEST_NO_PRODUCT:-0}" = 1 ]; then
    rt_warn "test only (KODUS_RUNTIME_TEST_NO_PRODUCT): the product's api and worker are not started, nor their read grants"
else
    rt_info "API and worker with the Runtime env (the API applies the product migrations)..."
    rt_compose up -d --force-recreate api worker

    rt_info "Read grants (waits for the Runtime and product tables)..."
    for i in $(seq 1 60); do
        rc=0
        RUNTIME_INIT_MODE=grants rt_compose run --rm runtime-init || rc=$?
        [ "$rc" = 0 ] && break
        [ "$rc" = 3 ] || rt_die "runtime-init grants failed (exit $rc)"
        [ "$i" = 60 ] && rt_die "the tables did not appear in 10 minutes: check scripts/runtime/compose.sh logs api runtime-hub"
        sleep 10
    done
fi

rt_info "Runtime worker..."
rt_compose up -d --wait runtime-worker

rt_ok "Kody Runtime control plane is up."
cat <<EOF

Next, on each cell host (docs/runtime.md, "Cell host"):
  1. Copy $RT_STATE/cell-host/ to the host (it holds the injector's OpenBao
     credential: transfer it privately, 0600).
  2. Create a registration token as the org owner (valid 15 minutes, once):
       scripts/runtime/cell-token.sh --api-url <https://api host>
  3. sudo scripts/runtime/cell-host.sh install --profile $PROFILE --bundle <copied dir> --token-file <file>
EOF
