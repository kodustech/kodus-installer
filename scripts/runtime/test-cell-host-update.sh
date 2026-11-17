#!/usr/bin/env bash
# Tests what scripts/runtime/cell-host.sh does around `cell update`, on this
# machine, in a temporary directory: no root, no Docker, no systemd, no
# network (Linux or macOS). The functions are sourced from cell-host.sh and
# run with KODUS_CELL_ROOT on the temporary directory, a stub cell and a
# stub systemctl.
#   - every `cell update` the script runs carries -preflight-config with the
#     cell's config, -root and the rollback window, plus the upgrade flags
#     (--retry-rolled-back, --require-protocol, --skip-*); a refused update
#     dies and keeps the release current;
#   - `upgrade --from` needs --release;
#   - `rollback` by hand swaps back, restores the release's settings and
#     units, and turns the automatic rollback watch off;
#   - the watch's units are installed with the others.
# The whole host install runs in scripts/runtime/test-cell-host.sh (Docker).
# Usage: scripts/runtime/test-cell-host-update.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CH="$HERE/cell-host.sh"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

pass=0 fail=0
t() {
    local name=$1
    shift
    if "$@" >"$TMP/out" 2>&1; then
        pass=$((pass + 1)); printf 'ok    %s\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n' "$name"; sed 's/^/      /' "$TMP/out" | tail -20
    fi
}
has() { grep -qF -- "$1" "$2" || { echo "no \"$1\" in $2:"; cat "$2"; return 1; }; }

# A host with release v1 installed by the installer: links to real paths
# (no prefix), each release keeping the settings and units it ran with.
new_host() {
    H="$TMP/host-$1"
    mkdir -p "$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/bin" "$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/systemd" "$H/etc/kodus/cell" "$H/etc/systemd/system"
    ln -sfn /opt/kodus-cell/releases/v1-aaaaaaaaaaaa "$H/opt/kodus-cell/current"
    printf 'KODUS_CELL_RELEASE=v1\n' >"$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/cell.env"
    printf 'v1 unit\n' >"$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/systemd/kodus-cell.service"
    printf 'CELL_ID=cell-test\nKODUS_CELL_RELEASE=v1\n' >"$H/etc/kodus/cell/cell.env"
    printf 'stateDir: /var/lib/kodus-cell/state\n' >"$H/etc/kodus/cell/cell.yaml"
    # The stub cell records its arguments and, for `update`, does what the
    # real one does to the layout: stage under -root, swap, arm the watch.
    cat >"$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/bin/cell" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
[ "${STUB_EXIT:-0}" = 0 ] || { echo "cell update: release refused: stub" >&2; exit "$STUB_EXIT"; }
root='' release=''
while [ $# -gt 0 ]; do
    case "$1" in -root) root=$2; shift 2 ;; -release) release=$2; shift 2 ;; *) shift ;; esac
done
dest="$root/releases/$release-bbbbbbbbbbbb"
mkdir -p "$dest/bin"
ln -sfn "$(readlink "$root/current")" "$root/previous"
printf '{}\n' >"$root/update-pending.json"
ln -sfn "$dest" "$root/current"
EOF
    chmod 755 "$H/opt/kodus-cell/releases/v1-aaaaaaaaaaaa/bin/cell"
    export STUB_LOG="$H/cell.log"
    : >"$STUB_LOG"
}

# in_script: runs CALL with cell-host.sh's functions on the host H, its
# output in $H/script.out. The script's systemctl calls are dry-run prints.
in_script() {
    (
        set --
        export KODUS_CELL_ROOT=$H KODUS_CELL_SYSTEMCTL=systemctl
        # shellcheck source=cell-host.sh
        . "$CH"
        "${CALL[@]}"
    ) >"$H/script.out" 2>&1
}
refused() { ! in_script; }

echo "== cell update carries the cell's config"
new_host update
CALL=(eval 'RELEASE=v2; cell_update_release /srv/release-v2 && printf "%s\n" "$REL_DIR" >"$KODUS_CELL_ROOT/rel-dir"')
t "the upgrade's cell update runs" in_script
t "it passes -preflight-config with the cell's config" has "-preflight-config $H/etc/kodus/cell/cell.yaml" "$STUB_LOG"
t "it runs with the installer's root, the release and its files" has "update -root $H/opt/kodus-cell -from /srv/release-v2 -release v2" "$STUB_LOG"
t "it arms the rollback watch (default window)" has "-rollback-window 10m" "$STUB_LOG"
t "the release's settings go into the directory cell update made" has "/opt/kodus-cell/releases/v2-bbbbbbbbbbbb" "$H/rel-dir"
t "the release cell update ran from was the current one" test -s "$H/cell.log"

new_host passthrough
CALL=(eval 'RELEASE=v2; UPDATE_EXTRA=(-retry-rolled-back -require-protocol); cell_update_release /srv/release-v2')
t "upgrade flags reach cell update" in_script
t "it passes -retry-rolled-back and -require-protocol" has "-rollback-window 10m -retry-rolled-back -require-protocol" "$STUB_LOG"
t "cell-host.sh parses the four cell update flags" sh -c '
    for f in retry-rolled-back require-protocol skip-preflight skip-protocol-check; do
        grep -q -- "--$f)" "$0" || grep -q -- "--$f |" "$0" || grep -q -- "| --$f" "$0" || { echo "--$f not parsed"; exit 1; }
    done' "$CH"

new_host refused
CALL=(eval 'RELEASE=v2; export STUB_EXIT=1; cell_update_release /srv/release-v2')
t "a refused cell update stops the upgrade" refused
t "it says the installed release stays current" has "stays current" "$H/script.out"
t "and it does" sh -c '[ "$(readlink "$0/opt/kodus-cell/current")" = /opt/kodus-cell/releases/v1-aaaaaaaaaaaa ]' "$H"

t "every cell update in cell-host.sh carries -preflight-config" sh -c '
    n=$(grep -cE "(update -root|bin/cell\"? update)" "$0")
    [ "$n" -ge 1 ] || { echo "no cell update call found"; exit 1; }
    grep -nE "(update -root|bin/cell\"? update)" "$0" | grep -v -- "-preflight-config" && exit 1
    exit 0' "$CH"

echo "== upgrade --from"
new_host from
t "--from without --release is refused" sh -c 'KODUS_CELL_ROOT="$1" "$0" upgrade --from /srv/x --dry-run 2>&1 | grep -q "\-\-from needs \-\-release"' "$CH" "$H"

echo "== rollback by hand"
new_host rollback
mkdir -p "$H/opt/kodus-cell/releases/v2-bbbbbbbbbbbb/bin"
ln -sfn /opt/kodus-cell/releases/v1-aaaaaaaaaaaa "$H/opt/kodus-cell/previous"
ln -sfn /opt/kodus-cell/releases/v2-bbbbbbbbbbbb "$H/opt/kodus-cell/current"
printf 'KODUS_CELL_RELEASE=v2\n' >"$H/etc/kodus/cell/cell.env"
printf 'v2 unit\n' >"$H/etc/systemd/system/kodus-cell.service"
printf '{}\n' >"$H/opt/kodus-cell/update-pending.json"
CALL=(eval 'DRY_RUN=1; cmd_rollback')
t "rollback runs" in_script
t "current is the release before, previous the one rolled back" sh -c '[ "$(readlink "$0/opt/kodus-cell/current")" = /opt/kodus-cell/releases/v1-aaaaaaaaaaaa ] && [ "$(readlink "$0/opt/kodus-cell/previous")" = /opt/kodus-cell/releases/v2-bbbbbbbbbbbb ]' "$H"
t "the release gets its settings back" has "KODUS_CELL_RELEASE=v1" "$H/etc/kodus/cell/cell.env"
t "and its units" has "v1 unit" "$H/etc/systemd/system/kodus-cell.service"
t "the automatic watch is off" test ! -e "$H/opt/kodus-cell/update-pending.json"
t "and it says so" has "update-pending.json removed" "$H/script.out"
t "the cell restarts" has "systemctl restart kodus-cell.target" "$H/script.out"

echo "== the watch's units"
t "installed with the others" sh -c 'grep -q "kodus-cell-update-watch.service kodus-cell-update-watch.timer" "$0"' "$CH"
U="$HERE/../../runtime/cell/systemd"
t "the service runs the release before, only while an update is on probation" sh -c 'grep -qx "ConditionPathExists=/opt/kodus-cell/update-pending.json" "$0/kodus-cell-update-watch.service" && grep -q "^ExecStart=/opt/kodus-cell/previous/bin/cell update-watch -root /opt/kodus-cell" "$0/kodus-cell-update-watch.service"' "$U"
t "the timer fires every minute by the wall clock" grep -qx "OnCalendar=minutely" "$U/kodus-cell-update-watch.timer"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
