#!/usr/bin/env bash
# validate-env.sh
#
# Validates the operator's .env (and optionally the env actually loaded by the
# running containers) against the schema shipped from kodus-ai.
#
# Sources of truth (both auto-generated upstream from kodus-ai/.env.schema):
#   - scripts/schema-vars.sh    : KODUS_REQUIRED_VARS + KODUS_AUTOGEN_SECRETS
#   - .env.example              : per-var "# (type: ...)" annotations
#
# Checks performed:
#   1. Each required var is set and non-empty in .env
#   2. Each value parses as its declared type (port/number/boolean/url/email/
#      cron/enum)
#   3. Vars present in .env but absent from the schema are reported (typo or
#      deprecated) — warning only
#   4. Drift: when containers are running, runtime env is compared with .env
#      and mismatches are surfaced (operator edited .env but didn't recreate)
#
# Exits 0 on success or warnings only, 1 on errors.
#
# VALIDATE_ENV_REPORT=<file>: also append one line per finding,
# "<fail|unknown>\t<title>\t<fix>", for scripts/doctor.sh to show in its report
# (warnings exit 0, so the exit code alone never carried them).

set -u

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

errors=0
warnings=0

section() {
    echo -e "\n${YELLOW}== $1 ==${NC}"
}
ok() {
    echo -e "${GREEN}OK${NC} $1"
}
warn() {
    echo -e "${YELLOW}WARN${NC} $1"
    warnings=$((warnings + 1))
}
err() {
    echo -e "${RED}ERROR${NC} $1"
    errors=$((errors + 1))
    report fail "$1"
}
# report <fail|unknown> <title> [fix] — a line for doctor.sh (see the header).
report() {
    [ -n "${VALIDATE_ENV_REPORT:-}" ] || return 0
    printf '%s\t%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" "$(printf '%s' "${3:-}" | tr '\t\n' '  ')" >> "$VALIDATE_ENV_REPORT"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
ENV_EXAMPLE="${ENV_EXAMPLE:-$ROOT_DIR/.env.example}"
SCHEMA_VARS="${SCHEMA_VARS:-$SCRIPT_DIR/schema-vars.sh}"

# ---------------------------------------------------------------------------
# Schema source
# ---------------------------------------------------------------------------

section "Schema source"

if [ ! -f "$ENV_EXAMPLE" ]; then
    err ".env.example not found at $ENV_EXAMPLE — needed for type metadata. Pull the latest installer."
    exit 1
fi
ok ".env.example found ($(basename "$ENV_EXAMPLE"))."

if [ -f "$SCHEMA_VARS" ]; then
    # shellcheck disable=SC1090
    . "$SCHEMA_VARS"
    ok "schema-vars.sh loaded (${#KODUS_REQUIRED_VARS[@]} required, ${#KODUS_AUTOGEN_SECRETS[@]} autogen)."
else
    warn "schema-vars.sh not found at $SCHEMA_VARS — required-var checks will be skipped."
    report unknown "scripts/schema-vars.sh is missing, so required .env variables were not checked." \
        "Pull the latest installer (git pull)."
    KODUS_REQUIRED_VARS=()
    KODUS_AUTOGEN_SECRETS=()
fi

if [ ! -f "$ENV_FILE" ]; then
    err ".env not found at $ENV_FILE. Copy .env.example and fill the required vars."
    exit 1
fi
ok ".env found ($(basename "$ENV_FILE"))."

# ---------------------------------------------------------------------------
# Parse .env.example -> SCHEMA_NAMES + ENV_TYPE_<NAME>
# ---------------------------------------------------------------------------
#
# Format we recognize (generated from .env.schema):
#   # human-readable description (any number of lines)
#   # (type: enum(a,b,c))         <-- optional, last comment before the var
#   VAR_NAME=default_value
#
# Section markers ("## ---- TITLE ----") and blank lines reset the buffer.

SCHEMA_NAMES=""

parse_schema_example() {
    local pending_type=""
    local line key
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"

        # Opt-in variable, commented out ("# MONGODB_URI="): known, not typed.
        case "$line" in
            "# "[A-Z]*=*)
                key="${line#\# }"; key="${key%%=*}"
                case "$key" in
                    *[!A-Z0-9_]*) ;;
                    *) SCHEMA_NAMES="$SCHEMA_NAMES $key" ;;
                esac
                pending_type=""
                continue
                ;;
        esac

        # Variable assignment.
        case "$line" in
            [A-Z]*=*)
                key="${line%%=*}"
                # Skip if the key has weird chars (defensive).
                case "$key" in
                    *[!A-Z0-9_]*) ;;
                    *)
                        SCHEMA_NAMES="$SCHEMA_NAMES $key"
                        eval "ENV_TYPE_${key}=\$pending_type"
                        ;;
                esac
                pending_type=""
                continue
                ;;
        esac

        # Type annotation.
        # Match: "# (type: <whatever-up-to-closing-paren>)"
        case "$line" in
            "# (type: "*")"*)
                # Strip the prefix and the trailing ")" (and anything after).
                pending_type="${line#\# (type: }"
                pending_type="${pending_type%)*}"
                continue
                ;;
        esac

        # Reset buffer on blank or section header.
        if [ -z "${line// }" ] || [ "${line#\#\# }" != "$line" ]; then
            pending_type=""
        fi
    done < "$ENV_EXAMPLE"
}

parse_schema_example
schema_count=$(printf '%s\n' $SCHEMA_NAMES | wc -l | tr -d ' ')
ok "Schema parsed: $schema_count vars known."

get_type() {
    local var="ENV_TYPE_$1"
    eval "printf '%s' \"\${$var-}\""
}

# Read only by this repo's docker-compose.yml / scripts, never by kodus-ai, so
# they are not in the schema synced from kodus-ai. scripts/install.sh writes
# KODUS_MONGO_IMAGE itself on Linux kernels 6.19+.
INSTALLER_ONLY_VARS="IMAGE_TAG KODUS_MONGO_IMAGE COMPOSE_PROFILES COMPOSE_PROJECT_NAME"

# Read by the app and documented for self-hosted Enterprise (license, Cockpit
# analytics), but left out of the generated .env.example (audience
# self-hosted-enterprise in kodus-ai .env.schema). Listed here so a
# regenerated .env.example cannot turn them back into "unknown".
APP_DOCUMENTED_VARS="KODUS_LICENSE_KEY
    ANALYTICS_PG_DB_HOST ANALYTICS_PG_DB_PORT ANALYTICS_PG_DB_USERNAME ANALYTICS_PG_DB_PASSWORD
    ANALYTICS_PG_DB_DATABASE ANALYTICS_PG_DB_SCHEMA ANALYTICS_PG_POOL_MAX
    ANALYTICS_INGESTION_CRON ANALYTICS_INGESTION_DISABLED ANALYTICS_INGESTION_RUN_ON_BOOT
    ANALYTICS_CLASSIFIER_CRON ANALYTICS_CLASSIFIER_DISABLED
    API_PG_ANALYTICS_HOST API_PG_ANALYTICS_PORT API_PG_ANALYTICS_USERNAME API_PG_ANALYTICS_PASSWORD
    API_PG_ANALYTICS_DATABASE API_PG_ANALYTICS_SCHEMA
    WEB_ANALYTICS_HOSTNAME WEB_ANALYTICS_SECRET WEB_PORT_ANALYTICS GLOBAL_ANALYTICS_CONTAINER_NAME
    MONGODB_URI API_MG_DB_URI"

is_in_schema() {
    local target=$1
    local v
    for v in $SCHEMA_NAMES $INSTALLER_ONLY_VARS $APP_DOCUMENTED_VARS; do
        [ "$v" = "$target" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Parse .env -> USER_VARS + USER_VAL_<NAME>
# ---------------------------------------------------------------------------

USER_VARS=""

parse_user_env() {
    local line key value
    set -o noglob
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        # Trim leading whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        # Skip blanks and comments.
        [ -z "$line" ] && continue
        [ "${line#\#}" != "$line" ] && continue
        # Strip optional "export ".
        [ "${line#export }" != "$line" ] && line="${line#export }"

        case "$line" in
            [A-Za-z_]*=*)
                key="${line%%=*}"
                value="${line#*=}"
                # Strip leading whitespace from value.
                value="${value#"${value%%[![:space:]]*}"}"
                # Strip surrounding quotes OR inline "# comment" tail.
                case "$value" in
                    \"*)
                        value="${value#\"}"
                        value="${value%%\"*}"
                        ;;
                    \'*)
                        value="${value#\'}"
                        value="${value%%\'*}"
                        ;;
                    *)
                        # Drop trailing inline comment ("VAR=foo  # note").
                        value="${value%%#*}"
                        # Strip trailing whitespace.
                        value="${value%"${value##*[![:space:]]}"}"
                        ;;
                esac
                USER_VARS="$USER_VARS $key"
                eval "USER_VAL_${key}=\$value"
                ;;
        esac
    done < "$ENV_FILE"
    set +o noglob
}

parse_user_env

get_user_value() {
    local var="USER_VAL_$1"
    eval "printf '%s' \"\${$var-}\""
}

user_var_set() {
    # 0 if the var was assigned in .env (even if empty), 1 otherwise.
    local target=$1 v
    for v in $USER_VARS; do
        [ "$v" = "$target" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Sensitive masking
# ---------------------------------------------------------------------------

is_sensitive() {
    local name=$1
    # Same suffixes as the app's doctor (apps/api/src/doctor/doctor-report.ts):
    # a *_URI carries credentials (amqp://user:pass@...).
    case "$name" in
        *PASSWORD|*PASSWD|*PASS|*PWD|*SECRET|*KEY|*TOKEN|*DSN|*URI|*CREDENTIAL|*CREDENTIALS|*PRIVATE)
            return 0
            ;;
    esac
    # Cross-check autogen list (these are always secrets the installer mints).
    local entry stripped
    for entry in ${KODUS_AUTOGEN_SECRETS[@]+"${KODUS_AUTOGEN_SECRETS[@]}"}; do
        stripped="${entry%%=*}"
        [ "$stripped" = "$name" ] && return 0
    done
    return 1
}

mask() {
    local v=$1
    local len=${#v}
    if [ "$len" -le 6 ]; then
        printf '****'
    else
        printf '%s***%s' "${v:0:2}" "${v: -2}"
    fi
}

display_value() {
    local name=$1
    local value=$2
    if is_sensitive "$name"; then
        mask "$value"
    else
        # Any other URL can still hold user:password@.
        printf '%s' "$value" | sed -E 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]*:[^/[:space:]]*@#\1<redacted>@#g'
    fi
}

# ---------------------------------------------------------------------------
# Type validation
# ---------------------------------------------------------------------------

validate_type() {
    local name=$1
    local value=$2
    local type=$3

    # Empty values are not type-checked here; required-vs-empty is handled
    # by validate_required().
    [ -z "$value" ] && return 0
    [ -z "$type" ] && return 0

    case "$type" in
        port)
            if ! printf '%s' "$value" | grep -Eq '^[0-9]+$'; then
                err "$name=$(display_value "$name" "$value") is not a valid port (1-65535)"
                return
            fi
            if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
                err "$name=$(display_value "$name" "$value") is out of port range (1-65535)"
            fi
            ;;
        number)
            if ! printf '%s' "$value" | grep -Eq '^-?[0-9]+$'; then
                err "$name=$(display_value "$name" "$value") is not a valid integer"
            fi
            ;;
        boolean)
            local lower
            lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
            case "$lower" in
                true|false) ;;
                *)
                    err "$name=$(display_value "$name" "$value") is not a valid boolean (expected true|false)"
                    ;;
            esac
            ;;
        url)
            case "$value" in
                http://*|https://*) ;;
                *)
                    err "$name=$(display_value "$name" "$value") must start with http:// or https://"
                    ;;
            esac
            ;;
        email)
            if ! printf '%s' "$value" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; then
                err "$name=$(display_value "$name" "$value") is not a valid email"
            fi
            ;;
        cron)
            local fields
            fields=$(printf '%s' "$value" | awk '{print NF}')
            if [ "$fields" -lt 5 ] || [ "$fields" -gt 6 ]; then
                err "$name=$(display_value "$name" "$value") is not a valid cron expression (expected 5 or 6 fields, got $fields)"
            fi
            ;;
        enum\(*\))
            local options="${type#enum(}"
            options="${options%)}"
            local found="false"
            local saved_ifs="$IFS"
            IFS=','
            for opt in $options; do
                if [ "$value" = "$opt" ]; then
                    found="true"
                    break
                fi
            done
            IFS="$saved_ifs"
            if [ "$found" != "true" ]; then
                err "$name=$(display_value "$name" "$value") is not in enum($options)"
            fi
            ;;
        *)
            # Unknown type (forward-compatibility): don't fail, just note.
            warn "$name has unknown type '$type' in .env.example — skipping value check"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# .env vs schema
# ---------------------------------------------------------------------------

section "Required variables"

if [ "${#KODUS_REQUIRED_VARS[@]}" -eq 0 ]; then
    warn "No required-vars list (schema-vars.sh missing) — skipping."
else
    missing=0
    for var in ${KODUS_REQUIRED_VARS[@]+"${KODUS_REQUIRED_VARS[@]}"}; do
        if ! user_var_set "$var" || [ -z "$(get_user_value "$var")" ]; then
            err "Missing or empty required variable: $var"
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -eq 0 ]; then
        ok "All ${#KODUS_REQUIRED_VARS[@]} required variables are set."
    fi
fi

section "Type checks"

type_errors_before=$errors
checked=0
for var in $SCHEMA_NAMES; do
    user_var_set "$var" || continue
    type=$(get_type "$var")
    [ -z "$type" ] && continue
    value=$(get_user_value "$var")
    validate_type "$var" "$value" "$type"
    checked=$((checked + 1))
done
if [ "$errors" -eq "$type_errors_before" ]; then
    ok "$checked typed values OK."
fi

section "Variables not in self-hosted schema"

# Vars set in .env that are NOT shipped in the self-hosted .env.example. These
# fall into three buckets, none of which we can disambiguate without the
# upstream schema:
#   - cloud-only vars an operator copied from cloud docs (harmless)
#   - deprecated/renamed vars (e.g. legacy typos that the app no longer reads)
#   - actual typos
unknown=0
unknown_names=""
for var in $USER_VARS; do
    is_in_schema "$var" && continue
    warn "$var is set but not in the self-hosted schema (cloud-only, deprecated, or typo)."
    unknown=$((unknown + 1))
    unknown_names="${unknown_names:+$unknown_names, }$var"
done
if [ "$unknown" -eq 0 ]; then
    ok "Every variable in .env is part of the self-hosted schema."
else
    report unknown "Kodus does not know ${unknown} variable(s) set in .env: ${unknown_names}." \
        "Check them for typos against .env.example; Kodus ignores a variable it does not know (it may be for Kodus Cloud only, or removed)."
fi

# ---------------------------------------------------------------------------
# Runtime drift
# ---------------------------------------------------------------------------

section "Runtime drift (.env vs running containers)"

if ! command -v docker &> /dev/null; then
    warn "docker not found — skipping runtime drift check."
elif ! docker info &> /dev/null; then
    warn "docker daemon not running — skipping runtime drift check."
else
    if docker compose version &> /dev/null; then
        DC="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DC="docker-compose"
    else
        DC=""
    fi

    if [ -z "$DC" ]; then
        warn "docker compose not available — skipping runtime drift check."
    else
        # Move into the installer root so docker compose finds the project.
        cd "$ROOT_DIR" || true
        services=$($DC config --services 2>/dev/null || true)

        # Keys a service's `environment:` block sets in the compose files
        # (RUN_MIGRATIONS=false, WORKER_ROLE=analytics, NODE_ENV...). Compose
        # applies them over env_file, so the container differs from .env there
        # on purpose: that is not drift, and recreating would not change it.
        compose_env_overrides() {
            local f
            for f in "$ROOT_DIR/docker-compose.yml" "$ROOT_DIR/docker-compose.override.yml"; do
                [ -f "$f" ] || continue
                awk -v svc="$1" '
                    /^[^[:space:]#]/ { in_services = ($0 ~ /^services:/); cur = ""; next }
                    in_services && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
                        cur = $1; sub(/:$/, "", cur); env = 0; next
                    }
                    cur != svc { next }
                    /^    environment:/ { env = 1; next }
                    /^    [^[:space:]]/ { env = 0 }
                    env {
                        line = $0
                        sub(/^[[:space:]]*(-[[:space:]]*)?/, "", line)
                        if (line == "" || line ~ /^#/) next
                        gsub(/["\047]/, "", line)
                        sub(/[=:].*/, "", line)
                        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print line
                    }' "$f"
            done
        }

        if [ -z "$services" ]; then
            warn "No compose services detected — skipping runtime drift."
        else
            any_running="false"
            for service in $services; do
                cid=$($DC ps -q "$service" 2>/dev/null)
                [ -z "$cid" ] && continue
                any_running="true"

                # Read container env into a temp file we can grep.
                envs_tmp=$(mktemp)
                docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" > "$envs_tmp" 2>/dev/null

                drift=0
                compared=0
                drift_names=""
                overrides=" $(compose_env_overrides "$service" | tr '\n' ' ') "
                for var in $USER_VARS; do
                    case "$overrides" in *" $var "*) continue ;; esac
                    container_line=$(grep -m1 "^${var}=" "$envs_tmp" 2>/dev/null || true)
                    [ -z "$container_line" ] && continue
                    compared=$((compared + 1))
                    container_value="${container_line#*=}"
                    user_value=$(get_user_value "$var")
                    if [ "$user_value" != "$container_value" ]; then
                        drift=$((drift + 1))
                        drift_names="${drift_names:+$drift_names, }$var"
                        warn "$service $var drift: .env=$(display_value "$var" "$user_value") container=$(display_value "$var" "$container_value")"
                    fi
                done
                rm -f "$envs_tmp"

                if [ "$drift" -eq 0 ]; then
                    ok "$service: $compared shared vars match .env."
                else
                    warn "$service: $drift drift(s). Recreate with '$DC up -d --force-recreate $service' to apply."
                    report unknown "The ${service} service runs with values that differ from .env: ${drift_names}." \
                        "If you changed .env on purpose, recreate it to apply: '$DC up -d --force-recreate $service'."
                fi
            done

            if [ "$any_running" != "true" ]; then
                warn "No running containers in this compose project — skipping drift."
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

section "Summary"

if [ "$errors" -gt 0 ]; then
    echo -e "${RED}validate-env: $errors error(s), $warnings warning(s).${NC}"
    exit 1
fi
if [ "$warnings" -gt 0 ]; then
    echo -e "${YELLOW}validate-env: $warnings warning(s).${NC}"
else
    echo -e "${GREEN}validate-env: all checks passed.${NC}"
fi
