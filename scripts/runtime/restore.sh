#!/usr/bin/env bash
# Restores what scripts/runtime/backup.sh saved, into this install: the state
# directory, OpenBao's unseal key, the Runtime and OpenBao databases. Restore
# the product database first (its own backup), then this. The Runtime
# services are stopped for the restore and started again by install.sh.
#
# Usage: scripts/runtime/restore.sh --from <dir> --unseal-key <file> [--force]
#   --force   replace an existing runtime/state (its unseal key is lost)
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

FROM='' KEY='' FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM=${2:?}; shift 2 ;;
        --unseal-key) KEY=${2:?}; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h | --help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ -n "$FROM" ] && [ -n "$KEY" ] || rt_die "--from and --unseal-key are both required"
for f in kodus_runtime.dump kodus_openbao.dump runtime-state.tar.gz; do
    [ -s "$FROM/$f" ] || rt_die "$FROM/$f is missing"
done
[ "$(wc -c <"$KEY" | tr -d ' ')" = 32 ] || rt_die "$KEY is not a 32-byte unseal key"
if [ -s "$RT_STATE/openbao/server/unseal.key" ] && [ "$FORCE" = 0 ]; then
    rt_die "$RT_STATE already holds an install; --force replaces it (and its unseal key)"
fi

if [ -f "$RT_STATE/compose.env" ]; then
    rt_compose stop runtime-worker runtime-hub runtime-openbao >/dev/null 2>&1 || true
fi
umask 077
mkdir -p "$RT_STATE"
tar -C "$RT_STATE" -xzf "$FROM/runtime-state.tar.gz"
cp "$KEY" "$RT_STATE/openbao/server/unseal.key"
chmod 600 "$RT_STATE/openbao/server/unseal.key"
[ "$(id -u)" = 0 ] && chown -R 1000:1000 "$RT_STATE"

use_local_db=$(rt_env_get "$RT_ROOT/.env" USE_LOCAL_DB)
[ "${use_local_db:-true}" = false ] || rt_compose up -d --wait db_kodus_postgres
# The roles and empty databases first, with the restored passwords.
RUNTIME_INIT_MODE=roles rt_compose run --rm runtime-init
for db in kodus_runtime kodus_openbao; do
    rt_info "Restoring $db..."
    RUNTIME_INIT_MODE=restore rt_compose run --rm -T -e RUNTIME_INIT_DB="$db" runtime-init <"$FROM/$db.dump"
done
rt_ok "Restored. Start the Runtime again with: scripts/runtime/install.sh"
