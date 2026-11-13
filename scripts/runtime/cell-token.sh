#!/usr/bin/env bash
# Creates a one-time cell registration token (single use, 15 minutes, bound to
# the org and the topology `self_hosted`) through the API, as the org owner:
# POST /runtime/cells/registration-tokens. The web app has no screen for it
# yet. The token goes to stdout or to --out (0600), never to a log.
#
# Usage: scripts/runtime/cell-token.sh --api-url <url> [--email <owner email>] [--out <file>]
#   KODUS_ACCESS_TOKEN  an owner's access token; without it the script signs
#                       in with --email and a password read from the terminal
#   --topology          self_hosted (default) or hybrid
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

API_URL='' EMAIL='' OUT='' TOPOLOGY=self_hosted
while [ $# -gt 0 ]; do
    case "$1" in
        --api-url) API_URL=${2:?}; shift 2 ;;
        --email) EMAIL=${2:?}; shift 2 ;;
        --out) OUT=${2:?}; shift 2 ;;
        --topology) TOPOLOGY=${2:?}; shift 2 ;;
        -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) rt_die "unknown argument $1" ;;
    esac
done
[ -n "$API_URL" ] || rt_die "--api-url is required (the API's base URL, e.g. https://api.example.com)"
rt_require_cmds curl
API_URL=${API_URL%/}

json_field() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }

TOKEN=${KODUS_ACCESS_TOKEN:-}
if [ -z "$TOKEN" ]; then
    [ -n "$EMAIL" ] || rt_die "set KODUS_ACCESS_TOKEN or pass --email"
    printf 'Password for %s: ' "$EMAIL" >&2
    IFS= read -rs PASSWORD
    printf '\n' >&2
    body=$(printf '{"email":"%s","password":"%s"}' "$EMAIL" "$(printf '%s' "$PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')")
    TOKEN=$(printf '%s' "$body" | curl -fsS -X POST "$API_URL/auth/login" -H 'content-type: application/json' --data-binary @- | json_field accessToken) ||
        rt_die "sign-in failed"
    unset PASSWORD body
    [ -n "$TOKEN" ] || rt_die "sign-in returned no access token"
fi

res=$(printf '{"topology":"%s"}' "$TOPOLOGY" | curl -fsS -X POST "$API_URL/runtime/cells/registration-tokens" \
    -H 'content-type: application/json' -H @<(printf 'authorization: Bearer %s\n' "$TOKEN") --data-binary @-) ||
    rt_die "the API refused the token request (the caller must be the org owner; the Runtime must be installed)"
cell_token=$(printf '%s' "$res" | json_field token)
case "$cell_token" in kcr_*) ;; *) rt_die "the API answered without a registration token" ;; esac
if [ -n "$OUT" ]; then
    (umask 077 && printf '%s\n' "$cell_token" >"$OUT")
    rt_ok "Registration token written to $OUT (expires $(printf '%s' "$res" | json_field expiresAt))."
else
    printf '%s\n' "$cell_token"
fi
