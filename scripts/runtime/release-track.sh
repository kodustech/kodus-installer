#!/usr/bin/env bash
# Lists the organizations and their release track, or sets one. Kody Runtime
# is released to an organization on the `alpha` track, in cloud and
# self-hosted alike; a self-hosted install has no screen for the track, so the
# operator sets it here once the owner has signed up. Runs as the product's
# Postgres admin through the runtime-init one-shot (bundled or external
# Postgres alike) and prints no credential.
#
# Usage: scripts/runtime/release-track.sh                      list
#        scripts/runtime/release-track.sh --org <id> --track alpha
#        scripts/runtime/release-track.sh --all --track alpha
#   A signed-in user sees the change on the next page load.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

ORG='' TRACK=''
while [ $# -gt 0 ]; do
    case "$1" in
        --org) ORG=${2:?}; shift 2 ;;
        --all) ORG=all; shift ;;
        --track) TRACK=${2:?}; shift 2 ;;
        -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown option $1 (see --help)" ;;
    esac
done
if [ -n "$ORG$TRACK" ]; then
    [ -n "$ORG" ] || rt_die "--track needs --org <id> or --all"
    case "$TRACK" in stable | beta | alpha) ;; *) rt_die "--track must be stable, beta or alpha" ;; esac
fi

RUNTIME_INIT_MODE=release-track rt_compose run --rm -T \
    -e RUNTIME_INIT_ORG="$ORG" -e RUNTIME_INIT_TRACK="$TRACK" runtime-init
