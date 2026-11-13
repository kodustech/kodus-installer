#!/usr/bin/env bash
# Upgrades the Kody Runtime control plane to the images of another product
# release, in the order the Runtime needs (kodus-ai docs/runtime/deploy-*.md):
# no claim in flight, the runtime-worker stopped (no new Run, setup or
# sandbox), a backup, then install.sh: OpenBao, the hub first (it applies the
# Runtime migrations under an advisory lock), the API (product migrations),
# the read grants again, and the runtime-worker last. Cells keep running and
# reconnect; upgrade them afterwards with cell-host.sh upgrade, staying within
# one protocol version of the hub (runtime/compatibility.tsv).
#
# Usage: scripts/runtime/upgrade.sh --release <r> (--backup-dir <dir> --unseal-key-out <file> | --no-backup) [--wait-claims <minutes>]
# Rollback: scripts/runtime/install.sh --release <previous>. The Runtime's
# migrations only add tables, so older code runs on the newer schema.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

RELEASE='' BACKUP_DIR='' KEY_OUT='' NO_BACKUP=0 WAIT_MIN=30
while [ $# -gt 0 ]; do
    case "$1" in
        --release) RELEASE=${2:?}; shift 2 ;;
        --backup-dir) BACKUP_DIR=${2:?}; shift 2 ;;
        --unseal-key-out) KEY_OUT=${2:?}; shift 2 ;;
        --no-backup) NO_BACKUP=1; shift ;;
        --wait-claims) WAIT_MIN=${2:?}; shift 2 ;;
        -h | --help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ -n "$RELEASE" ] || rt_die "--release is required"
[ "$NO_BACKUP" = 1 ] || { [ -n "$BACKUP_DIR" ] && [ -n "$KEY_OUT" ]; } ||
    rt_die "--backup-dir and --unseal-key-out (or --no-backup) are required"
OLD=$(rt_env_get "$RT_STATE/compose.env" KODUS_RUNTIME_RELEASE)
[ -n "$OLD" ] || rt_die "no Runtime install in $RT_STATE"
# Fails now, before anything stops, when the release has no row or no image.
rt_cell_release_for "$RELEASE" >/dev/null
rt_image "$RELEASE" hub >/dev/null
rt_image "$RELEASE" worker >/dev/null

rt_info "Waiting for claims in flight to end (up to $WAIT_MIN min)..."
deadline=$(($(date +%s) + WAIT_MIN * 60))
while :; do
    n=$(RUNTIME_INIT_MODE=live-claims rt_compose run --rm -T runtime-init | tr -d '[:space:]')
    [ "$n" = 0 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && rt_die "$n claim(s) still pending, bound or held: wait for them, or release them from the Runtime screens"
    sleep 15
done
rt_compose stop runtime-worker

if [ "$NO_BACKUP" = 0 ]; then
    "$RT_SCRIPTS_DIR/backup.sh" --out "$BACKUP_DIR" --unseal-key-out "$KEY_OUT"
fi
"$RT_SCRIPTS_DIR/install.sh" --release "$RELEASE"
rt_ok "Runtime control plane: $OLD -> $RELEASE."
rt_info "Cells: scripts/runtime/cell-host.sh upgrade --release $(rt_cell_release_for "$RELEASE") on each cell host."
