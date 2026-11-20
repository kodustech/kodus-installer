#!/usr/bin/env bash
# Shared helpers of the Kody Runtime scripts (sourced, never run). Bash 3.2
# compatible: the control-plane scripts also run on macOS hosts.
# shellcheck shell=bash

RT_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT_ROOT="$(cd "$RT_SCRIPTS_DIR/../.." && pwd)"
# shellcheck disable=SC2034 # read by the scripts that source this file
RT_DATA="$RT_ROOT/runtime"
RT_STATE="${KODUS_RUNTIME_STATE:-$RT_ROOT/runtime/state}"
RT_COMPAT="${KODUS_RUNTIME_COMPAT_FILE:-$RT_DATA/compatibility.tsv}"
RT_LOCK="${KODUS_RUNTIME_IMAGES_LOCK:-$RT_DATA/images.lock}"
# shellcheck disable=SC2034
RT_GVISOR="${KODUS_RUNTIME_GVISOR_PINS:-$RT_DATA/gvisor.tsv}"

if [ -t 1 ]; then
    RT_RED=$'\033[0;31m' RT_GREEN=$'\033[0;32m' RT_YELLOW=$'\033[1;33m' RT_NC=$'\033[0m'
else
    RT_RED='' RT_GREEN='' RT_YELLOW='' RT_NC=''
fi

rt_info() { printf '%s\n' "$*"; }
rt_ok() { printf '%s%s%s\n' "$RT_GREEN" "$*" "$RT_NC"; }
rt_warn() { printf '%sWarning: %s%s\n' "$RT_YELLOW" "$*" "$RT_NC" >&2; }
rt_die() {
    printf '%sError: %s%s\n' "$RT_RED" "$*" "$RT_NC" >&2
    exit 1
}

# rt_rows FILE: the data lines of a tab-separated table (no comments, no blanks).
rt_rows() {
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" || true
}

# rt_compat_field PRODUCT COLUMN: one column (1-based) of the product's row.
rt_compat_field() {
    rt_rows "$RT_COMPAT" | awk -F '\t' -v p="$1" -v c="$2" '$1 == p { print $c; exit }'
}

# rt_protocol_fits HUB_PROTOCOL CELL_PROTOCOLS: true when the comma list holds it.
rt_protocol_fits() {
    case ",$2," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# rt_cell_release_for PRODUCT [CELL_RELEASE]: the cell release that fits the
# product's hub, the one asked for when given (and refused when it does not
# fit), else the last fitting row of the table.
rt_cell_release_for() {
    local product=$1 wanted=${2:-} hub
    hub=$(rt_compat_field "$product" 2)
    [ -n "$hub" ] || rt_die "product release '$product' is not in $(basename "$RT_COMPAT"); pin IMAGE_TAG to a release listed there, or KODUS_RUNTIME_RELEASE=unreleased for local builds"
    rt_rows "$RT_COMPAT" | awk -F '\t' -v hub="$hub" -v want="$wanted" '
        { n = split($4, ps, ","); fits = 0; for (i = 1; i <= n; i++) if (ps[i] == hub) fits = 1 }
        fits && (want == "" || $3 == want) { last = $3 }
        END { if (last != "") print last }'
}

# rt_cell_backends CELL_RELEASE: the backends column of the cell release.
rt_cell_backends() {
    rt_rows "$RT_COMPAT" | awk -F '\t' -v r="$1" '$3 == r { print $5; exit }'
}

# rt_override_var COMPONENT: the env var that names a local or mirrored build.
rt_override_var() {
    printf 'KODUS_RUNTIME_%s_IMAGE' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
}

# rt_lock_field RELEASE COMPONENT COLUMN
rt_lock_field() {
    rt_rows "$RT_LOCK" | awk -F '\t' -v r="$1" -v c="$2" -v col="$3" '($1 == r || $1 == "any") && $2 == c { print $col; exit }'
}

# rt_image RELEASE COMPONENT [optional]: the image reference to run.
#   1. KODUS_RUNTIME_<COMPONENT>_IMAGE when set (a local build or a mirror);
#   2. the lock's reference when it is published, with its registry host
#      replaced by KODUS_RUNTIME_REGISTRY when that is set (offline bundle);
#   3. otherwise an error that names the component, or nothing for an
#      optional one.
rt_image() {
    local release=$1 component=$2 optional=${3:-} var ref status
    var=$(rt_override_var "$component")
    if [ -n "${!var:-}" ]; then
        printf '%s\n' "${!var}"
        return 0
    fi
    ref=$(rt_lock_field "$release" "$component" 3)
    status=$(rt_lock_field "$release" "$component" 4)
    if [ -n "$ref" ] && [ "$ref" != "-" ] && [ "$status" = "published" ]; then
        if [ -n "${KODUS_RUNTIME_REGISTRY:-}" ]; then
            ref="${KODUS_RUNTIME_REGISTRY%/}/${ref#*/}"
        fi
        printf '%s\n' "$ref"
        return 0
    fi
    [ -n "$optional" ] && return 0
    if [ -z "$ref" ]; then
        rt_die "images.lock has no '$component' for release '$release'"
    fi
    [ "$ref" = "-" ] && ref=''
    rt_die "the '$component' image of release '$release' is not published in any registry yet${ref:+ (pinned: $ref)}; build it locally and set $var (docs/runtime.md, \"Images that do not exist yet\")"
}

# rt_repo REF: the repository of name[:tag]@sha256:digest, without tag or digest.
rt_repo() {
    local name=${1%@*}
    case "${name##*/}" in *:*) name=${name%:*} ;; esac
    printf '%s' "$name"
}

# rt_env_get FILE KEY: a value from a dotenv file (unquoted), empty when absent.
rt_env_get() {
    [ -f "$1" ] || return 0
    { grep -E "^${2}=" "$1" || true; } | tail -n1 | sed -E "s/^${2}=//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}

# rt_url_part URL host|port|path|user: one part of scheme://user:pw@host:port/path
rt_url_part() {
    local rest=${1#*://} auth hostport
    case "$rest" in
        *@*) auth=${rest%%@*}; rest=${rest#*@} ;;
        *) auth='' ;;
    esac
    hostport=${rest%%/*}
    case "$2" in
        host) printf '%s' "${hostport%%:*}" ;;
        port) case "$hostport" in *:*) printf '%s' "${hostport##*:}" ;; esac ;;
        path) case "$rest" in */*) printf '%s' "${rest#*/}" | sed 's/[?#].*//' ;; esac ;;
        user) printf '%s' "${auth%%:*}" ;;
    esac
}

rt_require_cmds() {
    local c missing=''
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] || rt_die "missing commands:$missing"
}

# rt_compose ARGS...: docker compose over the product stack plus the Runtime,
# with the generated non-secret settings (images, binds, public URLs).
# KODUS_RUNTIME_COMPOSE_EXTRA adds one more compose file (the tests use it to
# isolate networks and names). docker-compose.override.yml, which Compose loads
# only when no -f is given, is added last when present, as scripts/install.sh
# does: an operator's image pins for the API and the worker (for example a
# build of the product that carries the Runtime) hold here too.
rt_compose() {
    local override=()
    [ ! -f "$RT_ROOT/docker-compose.override.yml" ] || override=(-f "$RT_ROOT/docker-compose.override.yml")
    [ -f "$RT_STATE/compose.env" ] || rt_die "$RT_STATE/compose.env is missing: run scripts/runtime/install.sh first"
    KODUS_RUNTIME_STATE="$RT_STATE" docker compose \
        --project-directory "$RT_ROOT" \
        --env-file "$RT_ROOT/.env" --env-file "$RT_STATE/compose.env" \
        -f "$RT_ROOT/docker-compose.yml" -f "$RT_ROOT/docker-compose.runtime.yml" \
        ${KODUS_RUNTIME_COMPOSE_EXTRA:+-f "$KODUS_RUNTIME_COMPOSE_EXTRA"} \
        ${override[@]+"${override[@]}"} \
        --profile runtime "$@"
}
