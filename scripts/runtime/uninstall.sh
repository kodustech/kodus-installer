#!/usr/bin/env bash
# Removes the Kody Runtime control plane from a Kodus install. By default only
# the services go: the API and the worker are recreated without the Runtime
# env, and the databases, OpenBao's storage, the RabbitMQ user and
# runtime/state stay, so install.sh brings it back as it was.
#
# Usage: scripts/runtime/uninstall.sh [--purge-data --i-have-a-backup]
#   --purge-data       also drop kodus_runtime and kodus_openbao (every org
#                      secret), the Runtime roles, the RabbitMQ user, the
#                      evidence volume and runtime/state (the unseal key too)
#   --i-have-a-backup  required with --purge-data (scripts/runtime/backup.sh)
# Each cell host: scripts/runtime/cell-host.sh uninstall --purge.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

PURGE=0 ACK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --purge-data) PURGE=1; shift ;;
        --i-have-a-backup) ACK=1; shift ;;
        -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ "$PURGE" = 0 ] || [ "$ACK" = 1 ] || rt_die "--purge-data destroys every org secret: back up first (scripts/runtime/backup.sh), then add --i-have-a-backup"

rt_compose rm -sf runtime-worker runtime-hub runtime-openbao runtime-init
# The product without the overlay: no Runtime env, no OpenBao files.
# (KODUS_RUNTIME_TEST_NO_PRODUCT: install.sh's test hook, no product to recreate.)
[ "${KODUS_RUNTIME_TEST_NO_PRODUCT:-0}" = 1 ] ||
    docker compose --project-directory "$RT_ROOT" -f "$RT_ROOT/docker-compose.yml" up -d --force-recreate api worker
rt_ok "Runtime services removed; the API and the worker run without the Runtime."

if [ "$PURGE" = 1 ]; then
    RUNTIME_INIT_MODE=uninstall rt_compose run --rm runtime-init
    if [ "$(rt_env_get "$RT_ROOT/.env" USE_LOCAL_RABBITMQ)" != false ]; then
        rt_compose exec -T rabbitmq rabbitmqctl -q delete_user kodus_runtime >/dev/null 2>&1 || true
    else
        rt_warn "external RabbitMQ: delete the user kodus_runtime there"
    fi
    docker volume rm kodus-runtime-evidence >/dev/null 2>&1 || true
    rm -rf "$RT_STATE"
    rt_ok "Runtime data removed (databases, roles, RabbitMQ user, evidence, $RT_STATE)."
fi
