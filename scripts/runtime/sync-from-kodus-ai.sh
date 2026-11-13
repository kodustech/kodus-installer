#!/usr/bin/env bash
# Copies the Runtime files the installer vendors from a kodus-ai checkout:
# OpenBao's config and policies and the Runtime's grant scripts, each with a
# header naming the commit. --check only reports drift (exit 1), for CI.
#
# Usage: scripts/runtime/sync-from-kodus-ai.sh --from <kodus-ai checkout> [--check]
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

FROM='' CHECK=0
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM=${2:?}; shift 2 ;;
        --check) CHECK=1; shift ;;
        -h | --help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ -d "$FROM/apps/runtime" ] || rt_die "--from must be a kodus-ai checkout that has apps/runtime"
SHA=$(git -C "$FROM" log -1 --format=%h -- docker/openbao scripts/runtime)
BRANCH=$(git -C "$FROM" rev-parse --abbrev-ref HEAD)

# source in kodus-ai -> destination here -> comment prefix
MAP="docker/openbao/config/openbao.hcl runtime/openbao/config/openbao.hcl #
docker/openbao/config/initialize.hcl runtime/openbao/config/initialize.hcl #
docker/openbao/policies/kodus-runtime-api.hcl runtime/openbao/policies/kodus-runtime-api.hcl #
docker/openbao/policies/kodus-runtime-injector.hcl runtime/openbao/policies/kodus-runtime-injector.hcl #
docker/openbao/create-database.sql runtime/sql/openbao-database.sql --
scripts/runtime/runtime-reader-grants.sql runtime/sql/runtime-reader-grants.sql --
scripts/runtime/runtime-secrets-reader-grants.sql runtime/sql/runtime-secrets-reader-grants.sql --"

drift=0
while read -r src dest c; do
    tmp=$(mktemp)
    {
        printf '%s Vendored from kodustech/kodus-ai@%s (%s) %s.\n' "$c" "$SHA" "$BRANCH" "$src"
        printf '%s Re-sync with scripts/runtime/sync-from-kodus-ai.sh; do not edit by hand.\n' "$c"
        cat "$FROM/$src"
    } >"$tmp"
    if [ "$CHECK" = 1 ]; then
        # Compare the content, not the header's commit.
        if ! diff -q <(tail -n +3 "$tmp") <(tail -n +3 "$RT_ROOT/$dest") >/dev/null; then
            rt_warn "$dest differs from kodus-ai $src"
            drift=1
        fi
        rm -f "$tmp"
    else
        mv "$tmp" "$RT_ROOT/$dest"
        rt_info "synced $dest"
    fi
done <<<"$MAP"
[ "$drift" = 0 ] || exit 1
[ "$CHECK" = 1 ] && rt_ok "Vendored Runtime files match kodus-ai@$SHA."
exit 0
