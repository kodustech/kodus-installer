#!/usr/bin/env bash
# Verifies a Kody Runtime install end to end (docs/runtime.md, "Verify"):
#   - OpenBao is unsealed, the hub answers, the runtime-worker runs;
#   - at least one cell is connected to the hub;
#   - a code sandbox starts on a cell, runs a command, reaches a host on its
#     allow-list, and is refused a host off it (scripts/runtime/smoke-sandbox.js,
#     run inside the runtime-worker).
#
# Usage: scripts/runtime/smoke.sh --org <organizationId> [--allowed-host github.com] [--denied-host example.com]
# The organization id is the org's uuid in the product database
# (SELECT uuid FROM organizations). The sandbox is released at the end; its
# audit rows stay in runtime.runtime_sandbox_audit.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

ORG='' ALLOWED=github.com DENIED=example.com
while [ $# -gt 0 ]; do
    case "$1" in
        --org) ORG=${2:?}; shift 2 ;;
        --allowed-host) ALLOWED=${2:?}; shift 2 ;;
        --denied-host) DENIED=${2:?}; shift 2 ;;
        -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ -n "$ORG" ] || rt_die "--org <organizationId> is required"

fail=0
state() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo absent; }
for c in kodus-runtime-openbao:healthy kodus-runtime-hub:healthy kodus-runtime-worker:running; do
    name=${c%%:*} want=${c#*:} got=$(state "${c%%:*}")
    if [ "$got" = "$want" ]; then rt_ok "ok      $name $got"; else printf 'FAILED  %s is %s, not %s\n' "$name" "$got" "$want"; fail=1; fi
done

cells=$(RUNTIME_INIT_MODE=connected-cells rt_compose run --rm -T runtime-init 2>/dev/null | tr -d '[:space:]' || true)
if [ -n "$cells" ] && [ "$cells" != 0 ]; then
    rt_ok "ok      $cells cell(s) connected with a free slot"
else
    printf 'FAILED  no cell is connected to the hub with a free slot; a cell that just connected reports its slots with its first heartbeat (cell-host.sh status on the cell host; journalctl -u kodus-cell)\n'
    fail=1
fi
[ "$fail" = 0 ] || exit 1

rt_compose exec -T -e SMOKE_ORG="$ORG" -e SMOKE_ALLOWED_HOST="$ALLOWED" -e SMOKE_DENIED_HOST="$DENIED" \
    runtime-worker node /runtime/smoke-sandbox.js
rt_ok "Smoke check passed. The cell's egress log names the refusal: journalctl -u kodus-cell-egress | grep $DENIED"
