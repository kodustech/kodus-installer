#!/usr/bin/env bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

errors=0
warnings=0
env_loaded=false
use_local_db="true"
use_local_rabbitmq="true"
api_mcp_enabled="false"
mcp_manager_port="3101"
mcp_manager_schema="mcp-manager"

section() {
    echo -e "\n${YELLOW}== $1 ==${NC}"
}

ok() {
    echo -e "${GREEN}OK${NC} $1"
    doctor_add ok infra "" "$1"
}

warn() {
    echo -e "${YELLOW}WARN${NC} $1"
    warnings=$((warnings + 1))
    doctor_add unknown infra "" "$1"
}

# A check that was skipped on purpose (external DB, missing local tool).
note() {
    echo -e "${YELLOW}NOTE${NC} $1"
    doctor_add info infra "" "$1"
}

# err <what> [impact] [fix]
err() {
    echo -e "${RED}ERROR${NC} $1"
    errors=$((errors + 1))
    doctor_add fail infra "" "$1" "${2:-Kodus depends on this; reviews may not run until it is fixed.}" "${3:-}"
}

normalize_bool() {
    local value
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        false|0|no|off)
            echo "false"
            ;;
        *)
            echo "true"
            ;;
    esac
}

extract_url_path() {
    local url=$1
    local without_scheme="${url#*://}"
    local path="/"
    if [ "$without_scheme" != "${without_scheme#*/}" ]; then
        path="/${without_scheme#*/}"
    fi
    path="${path%%\?*}"
    path="${path%%\#*}"
    printf '%s' "$path"
}

validate_webhook_url() {
    local label=$1
    local var_name=$2
    local url=$3
    local expected_path=$4

    if [ -z "$url" ]; then
        return 0
    fi

    case "$(printf '%s' "${url%%://*}" | tr '[:upper:]' '[:lower:]')://" in
        https://) ;;
        http://)
            # The app does not require https, and a Git server on the same
            # network (GitLab, Forgejo, Bitbucket Data Center) works over http.
            warnings=$((warnings + 1))
            doctor_add unknown infra "" \
                "The ${label} webhook URL uses http:// (${var_name})." "" \
                "Nothing to do if your Git server reaches it on your network; a Git provider on the internet should get an https:// URL."
            ;;
        *)
            err "${var_name} (${label}) must be a full URL starting with https:// or http://." \
                "${label} cannot be told about new pull requests: saving repositories fails or no webhook is delivered." \
                "Set ${var_name} to the URL your Git provider uses to reach the webhooks service, ending in ${expected_path%%|*}."
            ;;
    esac

    # WEB_HOSTNAME_API is how the web reaches the api, not where Git providers
    # send webhooks (the webhooks service), so the two hosts are not compared.
    # Parsed as URL parsers do (doctor-lib.sh): the scheme is case-insensitive,
    # so HTTPS://host/... has a host, and HTTPS:// alone has none.
    local host
    host=$(doctor_url_host "$url")
    if [ -z "$host" ]; then
        err "${var_name} (${label}) must include a valid host."
    fi

    local path
    path=$(extract_url_path "$url")
    local path_ok="false"
    IFS='|' read -r -a expected_paths <<< "$expected_path"
    for expected in "${expected_paths[@]}"; do
        if [ "$path" = "$expected" ]; then
            path_ok="true"
            break
        fi
    done
    if [ "$path_ok" != "true" ]; then
        err "${var_name} (${label}) path must be one of ${expected_path} (example: https://${host:-<webhooks-host>}${expected_paths[0]})."
    fi
}

DOCTOR_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/doctor-lib.sh
. "$DOCTOR_SCRIPT_DIR/doctor-lib.sh"
# .env and docker compose are read from the installer root: run from anywhere
# else, every check would fail on a missing .env or compose project.
cd "$DOCTOR_SCRIPT_DIR/.." || exit 1

for arg in "$@"; do
    case "$arg" in
        -v|--verbose) DOCTOR_VERBOSE=true ;;
        -h|--help)
            echo "Usage: $0 [--verbose]"
            echo "Prints whether reviews run, then every problem worst first."
            exit 0
            ;;
    esac
done

doctor_capture_start

if [ -x "$DOCTOR_SCRIPT_DIR/validate-env.sh" ]; then
    # Its findings come back as lines in a report file: its warnings exit 0,
    # so the exit code alone never reached this report.
    ve_report=$(mktemp "${TMPDIR:-/tmp}/kodus-doctor-env.XXXXXX")
    VALIDATE_ENV_REPORT="$ve_report" "$DOCTOR_SCRIPT_DIR/validate-env.sh"
    ve_rc=$?
    ve_errors=$(grep -c '^fail	' "$ve_report" 2>/dev/null)
    ve_first=$(grep '^fail	' "$ve_report" 2>/dev/null | cut -f2 | head -3 | paste -sd ';' - | sed 's/;/; /g')
    if [ "$ve_rc" -ne 0 ]; then
        errors=$((errors + 1))
        title=".env has missing or invalid variables"
        if [ -n "$ve_first" ]; then
            title="${title}: ${ve_first}"
            [ "${ve_errors:-0}" -gt 3 ] && title="${title}; and $((ve_errors - 3)) more"
        fi
        doctor_add fail env.schema "" "${title}." \
            "Services may fail to start or behave unexpectedly." \
            "Fix them in .env (./scripts/validate-env.sh lists them), then recreate the services ('docker compose up -d')."
    fi
    while IFS=$'\t' read -r ve_status ve_title ve_fix; do
        [ "$ve_status" = unknown ] || continue
        warnings=$((warnings + 1))
        doctor_add unknown env.schema "" "$ve_title" "" "$ve_fix"
    done < "$ve_report"
    rm -f "$ve_report"
fi

section "Prerequisites"

if ! command -v docker &> /dev/null; then
    err "Docker is not installed."
    exit 1
fi

if ! docker info &> /dev/null; then
    err "Docker daemon is not running."
    exit 1
fi
ok "Docker is installed and running."

if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    err "Docker Compose is not installed."
    exit 1
fi
ok "Using: $DOCKER_COMPOSE"

psql_exec() {
    local query=$1
    $DOCKER_COMPOSE exec -T db_kodus_postgres sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tA -c \"$query\"" 2>/dev/null | tr -d '[:space:]'
}

section ".env validation"

if [ ! -f .env ]; then
    err ".env file not found."
else
    if ! grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*=' .env; then
        err ".env file does not contain valid environment variables."
    else
        set -o noglob

        load_env() {
            while IFS= read -r line || [ -n "$line" ]; do
                line="${line#"${line%%[![:space:]]*}"}"
                line="${line%"${line##*[![:space:]]}"}"
                if [ -z "$line" ] || [ "${line#\#}" != "$line" ]; then
                    continue
                fi

                if [ "${line#export }" != "$line" ]; then
                    line="${line#export }"
                fi

                case "$line" in
                    [A-Za-z_]*=*)
                        key="${line%%=*}"
                        value="${line#*=}"
                        value="${value#"${value%%[![:space:]]*}"}"
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
                                value="${value%%[[:space:]]#*}"  # a comment starts at " #", as in compose
                                value="${value%"${value##*[![:space:]]}"}"
                                ;;
                        esac
                        export "$key=$value"
                        ;;
                    *)
                        ;;
                esac
            done < .env
        }

        load_env
        set +o noglob
        env_loaded=true
        ok ".env loaded."
    fi
fi

if [ "$env_loaded" = true ]; then
    use_local_db=$(normalize_bool "${USE_LOCAL_DB:-true}")
    use_local_rabbitmq=$(normalize_bool "${USE_LOCAL_RABBITMQ:-true}")
    api_mcp_enabled=$(normalize_bool "${API_MCP_SERVER_ENABLED:-false}")
    mcp_manager_port="${API_MCP_MANAGER_PORT:-3101}"
    mcp_manager_schema="${API_MCP_MANAGER_PG_DB_SCHEMA:-mcp-manager}"

    # Required-vars + per-type checks are handled upstream by validate-env.sh
    # (invoked at the top of this script). Here we only run the cross-var
    # consistency checks the schema can't express.

    if [ -z "$API_WEBHOOKS_PORT" ] && [ -n "$WEBHOOKS_PORT" ]; then
        warn "WEBHOOKS_PORT is deprecated; use API_WEBHOOKS_PORT."
    fi

    # WEB_HOSTNAME_API is how the web's server reaches the api, not a public
    # address: `localhost` (the default) means the api container, by
    # GLOBAL_API_CONTAINER_NAME (apps/web/src/core/utils/helpers.ts), and a
    # scheme is honoured. Whether the web really reaches the api is tested
    # from inside the web container under "HTTP checks".
    web_api_host="${WEB_HOSTNAME_API#http://}"
    web_api_host="${web_api_host#https://}"
    if [ -z "$WEB_HOSTNAME_API" ]; then
        err "WEB_HOSTNAME_API is empty: the web cannot reach the api." \
            "Nobody can sign in, and every page fails." \
            "Set WEB_HOSTNAME_API=localhost and WEB_PORT_API=3001 in .env (the web then calls the api container), and run '$DOCKER_COMPOSE up -d kodus-web'."
    elif [[ "$web_api_host" == */* ]]; then
        err "WEB_HOSTNAME_API must not include a path or a trailing slash." \
            "The web builds a broken api address: nobody can sign in, and every page fails." \
            "Set WEB_HOSTNAME_API to a host name only (the default is localhost), and run '$DOCKER_COMPOSE up -d kodus-web'."
    fi

    if [ -n "$NEXTAUTH_URL" ]; then
        case "$(printf '%s' "${NEXTAUTH_URL%%://*}" | tr '[:upper:]' '[:lower:]')://" in
            http://|https://)
                ;;
            *)
                err "NEXTAUTH_URL must include http:// or https:// and be a full URL (e.g. https://kodus-web.yourdomain.com)."
                ;;
        esac
        nextauth_host=$(doctor_url_host "$NEXTAUTH_URL")
        if [ -z "$nextauth_host" ]; then
            err "NEXTAUTH_URL must include a valid host."
        fi

    fi

    webhook_providers=()
    if [ -n "$API_GITHUB_CODE_MANAGEMENT_WEBHOOK" ]; then
        webhook_providers+=("github")
    fi
    if [ -n "$API_GITLAB_CODE_MANAGEMENT_WEBHOOK" ]; then
        webhook_providers+=("gitlab")
    fi
    if [ -n "$GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK" ]; then
        webhook_providers+=("bitbucket")
    fi
    if [ -n "$GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK" ]; then
        webhook_providers+=("azure-repos")
    fi
    if [ -n "$API_FORGEJO_CODE_MANAGEMENT_WEBHOOK" ]; then
        webhook_providers+=("forgejo")
    fi

    if [ ${#webhook_providers[@]} -eq 0 ]; then
        err "At least one Git webhook URL must be configured (GitHub, GitLab, Bitbucket, Azure Repos, or Forgejo). See https://docs.kodus.io/how_to_deploy/en/deploy_kodus/generic_vm#git-provider-configuration"
    else
        validate_webhook_url "GitHub" "API_GITHUB_CODE_MANAGEMENT_WEBHOOK" "$API_GITHUB_CODE_MANAGEMENT_WEBHOOK" "/github/webhook"
        validate_webhook_url "GitLab" "API_GITLAB_CODE_MANAGEMENT_WEBHOOK" "$API_GITLAB_CODE_MANAGEMENT_WEBHOOK" "/gitlab/webhook"
        validate_webhook_url "Bitbucket" "GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK" "$GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK" "/bitbucket/webhook"
        validate_webhook_url "Azure Repos" "GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK" "$GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK" "/azdevops/webhook|/azure-repos/webhook"
        validate_webhook_url "Forgejo" "API_FORGEJO_CODE_MANAGEMENT_WEBHOOK" "$API_FORGEJO_CODE_MANAGEMENT_WEBHOOK" "/forgejo/webhook"
    fi

    if [ "$api_mcp_enabled" = "true" ]; then
        mcp_required_vars=(
            API_KODUS_SERVICE_MCP_MANAGER
            API_KODUS_MCP_SERVER_URL
            # The mcp-manager verifies the signature of the access token the
            # web forwards, so an empty secret makes every MCP request 401 while
            # the unauthenticated /health probe still passes — a silent break
            # the health check can't see. The installer always generates this.
            API_JWT_SECRET
        )
        for var in "${mcp_required_vars[@]}"; do
            if [ -z "${!var}" ]; then
                err "Missing MCP variable: ${var}"
            fi
        done
    fi

    # The app turns the queue off only for the exact value "false"; unset or
    # anything else means on (libs/core/infrastructure/config/loaders/rabbitmq.loader.ts).
    if [ "${API_RABBITMQ_ENABLED:-}" = "false" ]; then
        err "API_RABBITMQ_ENABLED=false turns the message queue off." \
            "No review job is queued or taken, so no review runs." \
            "Set API_RABBITMQ_ENABLED=true in .env (or remove the line) and run '$DOCKER_COMPOSE up -d'."
    fi

    if [ -n "$API_RABBITMQ_URI" ] && ! printf '%s' "$API_RABBITMQ_URI" | grep -Eq '/kodus-ai$'; then
        warn "API_RABBITMQ_URI does not end with /kodus-ai."
    fi
fi

section "Docker networks"

networks=(shared-network monitoring-network kodus-backend-services)
for net in "${networks[@]}"; do
    if docker network inspect "$net" &> /dev/null; then
        ok "Network ${net} exists."
    else
        warn "Network ${net} does not exist. Run install to create it."
    fi
done

section "Docker Compose config"

if $DOCKER_COMPOSE config &> /dev/null; then
    ok "Compose config is valid."
else
    err "Compose config is invalid. Run '$DOCKER_COMPOSE config' to inspect."
fi

section "Service status"

optional_services=()
if [ "$use_local_db" != "true" ]; then
    optional_services+=(db_kodus_postgres db_kodus_mongodb)
fi
if [ "$use_local_rabbitmq" != "true" ]; then
    optional_services+=(rabbitmq)
fi
if [ "$api_mcp_enabled" != "true" ]; then
    optional_services+=(kodus-mcp-manager)
fi

is_optional_service() {
    local svc=$1
    for opt in ${optional_services[@]+"${optional_services[@]}"}; do
        if [ "$opt" = "$svc" ]; then
            return 0
        fi
    done
    return 1
}

# What a stopped service costs decides its mark: ✘ when reviews (or the whole
# app) stop, ! when a feature the admin turned on stops, ? for a service this
# script does not know. Bundled datastores only get here when they are in use
# (otherwise they are optional above).
service_down_status() {
    case "$1" in
        api|worker|webhooks|kodus-web|rabbitmq|db_kodus_postgres|db_kodus_mongodb) echo fail ;;
        kodus-mcp-manager|worker-analytics) echo warn ;;
        *) echo unknown ;;
    esac
}

service_down_impact() {
    case "$1" in
        api) echo "Nothing can be reviewed, and the review checks cannot run." ;;
        worker) echo "No review runs: pull request events wait in the queue until a worker takes them." ;;
        webhooks) echo "Kodus is not told about new pull requests, so none is reviewed." ;;
        kodus-web) echo "Nobody can sign in or change settings." ;;
        rabbitmq) echo "No review job can be queued or taken, so no review runs." ;;
        db_kodus_postgres|db_kodus_mongodb) echo "Kodus has no database: nothing works until it is back." ;;
        kodus-mcp-manager) echo "Reviews run without the MCP tools your organizations connected." ;;
        worker-analytics) echo "Cockpit analytics stop updating; reviews are not affected." ;;
    esac
}

# Services found stopped, so later checks do not report the same cause again (#2021).
down_services=" "

# report_service_down <service> <title> [fix]
report_service_down() {
    local svc=$1 title=$2 fix=${3:-} status
    status=$(service_down_status "$svc")
    down_services+="$svc "
    [ -n "$fix" ] || fix="Start it with '$DOCKER_COMPOSE up -d $svc'; if it stops again, '$DOCKER_COMPOSE logs --tail 200 $svc' shows why."
    echo -e "${RED}DOWN${NC} $title"
    [ "$status" = fail ] && errors=$((errors + 1))
    doctor_add "$status" infra "" "$title" "$(service_down_impact "$svc")" "$fix"
}

is_down() {
    case "$down_services" in *" $1 "*) return 0 ;; esac
    return 1
}

# Crash loop: restart: unless-stopped brings a crashing service back, so it
# reads "running" between crashes. RESTART_LOOP_MIN or more restarts with the
# last start inside RESTART_LOOP_MINUTES means it is crashing now; a service
# that has stayed up longer than that is not. RestartCount only counts
# restarts by the restart policy, and resets when the container is recreated
# (upgrade, `up -d` after an .env change).
RESTART_LOOP_MIN=3
RESTART_LOOP_MINUTES=5
loop_cutoff=$(date -u -d "-${RESTART_LOOP_MINUTES} minutes" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -u -v-"${RESTART_LOOP_MINUTES}"M +%Y-%m-%dT%H:%M:%S 2>/dev/null)

# Containers the kernel killed for memory recently. .State.OOMKilled alone
# misses one that already restarted, as Docker clears it on start. The daemon
# keeps only its last 256 events (minutes on a host with health checks), so this
# catches recent kills only; it never reports an old one.
oom_names=" $(docker events --since 24h --until "$(date +%s)" --filter event=oom \
    --format '{{.Actor.Attributes.name}}' 2>/dev/null | sort -u | tr '\n' ' ') "

report_service_loop() { # <service> <restarts> <started>
    local svc=$1 impact
    case "$svc" in
        api|worker|webhooks) impact="Reviews stop each time it restarts." ;;
        *) impact=$(service_down_impact "$svc") ;;
    esac
    down_services+="$svc "
    echo -e "${RED}LOOP${NC} ${svc}: $2 restarts, last start $3"
    [ "$(service_down_status "$svc")" = fail ] && errors=$((errors + 1))
    doctor_add "$(service_down_status "$svc")" infra "" \
        "The ${svc} service keeps restarting ($2 restarts, last start ${3%%.*} UTC)." \
        "$impact" "See why: '$DOCKER_COMPOSE logs --tail 200 $svc'."
}

report_service_oom() {
    local svc=$1
    doctor_add warn infra "" "The ${svc} service was killed for running out of memory." \
        "The work it was doing stopped (a review in progress fails), and it happens again when it needs that much memory." \
        "Give the machine more memory, or remove a memory limit set on ${svc}; '$DOCKER_COMPOSE logs --tail 200 $svc' shows what it was doing."
}

services=$($DOCKER_COMPOSE config --services 2>/dev/null)
if [ -z "$services" ]; then
    warn "No services found in compose config."
else
    for service in $services; do
        # -a: a stopped container is still listed, so its state can be told.
        container_id=$($DOCKER_COMPOSE ps -a -q "$service" 2>/dev/null | head -1)
        state=""
        [ -n "$container_id" ] && state=$(docker inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.State.StartedAt}}|{{.Name}}' "$container_id" 2>/dev/null)
        IFS='|' read -r status exit_code health restarts oom_killed started cname <<< "$state"
        cname=${cname#/}
        oom=false
        if [ "$oom_killed" = "true" ] || { [ -n "$cname" ] && [ "${oom_names#* "$cname" }" != "$oom_names" ]; }; then
            oom=true
        fi
        # Killed for memory and still down: one line, with the memory fix.
        if [ "$oom" = true ] && [ "$status" = "exited" ] && ! is_optional_service "$service"; then
            report_service_down "$service" "The ${service} service was killed for running out of memory (exited with code ${exit_code:-?})." \
                "Give the machine more memory, or remove a memory limit set on ${service}, then '$DOCKER_COMPOSE up -d $service'; '$DOCKER_COMPOSE logs --tail 200 $service' shows what it was doing."
            continue
        fi
        [ "$oom" = true ] && ! is_optional_service "$service" && report_service_oom "$service"
        if [ "$status" != "running" ]; then
            if [ "$service" = "migration" ]; then
                ok "Service ${service} is not running (one-off)."
            elif is_optional_service "$service"; then
                ok "Service ${service} is not running (disabled by config)."
            elif [ -z "$status" ]; then
                report_service_down "$service" "The ${service} service is not running."
            elif [ "$status" = "restarting" ]; then
                report_service_loop "$service" "${restarts:-?}" "${started:-?}"
            elif [ "$status" = "exited" ]; then
                report_service_down "$service" "The ${service} service is stopped (exited with code ${exit_code:-?})."
            else
                report_service_down "$service" "The ${service} service is ${status}."
            fi
            continue
        fi

        if [ "${restarts:-0}" -ge "$RESTART_LOOP_MIN" ] 2>/dev/null && [ -n "$loop_cutoff" ] \
            && [[ "$started" > "$loop_cutoff" ]]; then
            report_service_loop "$service" "$restarts" "$started"
            continue
        fi

        ok "Service ${service} is running."
        if [ -n "$health" ]; then
            if [ "$health" = "healthy" ]; then
                ok "Service ${service} is healthy."
            elif [ "$health" = "unhealthy" ]; then
                report_service_down "$service" "The ${service} service is unhealthy." \
                    "'$DOCKER_COMPOSE logs --tail 200 $service' shows why its health check fails."
            else
                warn "Service ${service} health is ${health}."
            fi
        fi
    done
fi

section "Connectivity checks"

# An external datastore is reached by the app, not by this machine. Probing it
# from the host gave false ✘: host.docker.internal and private DNS resolve only
# inside the containers, mongodb+srv (Atlas), TLS and the MONGODB_URI /
# API_MG_DB_URI the app prefers were ignored, and a password with @ or : broke
# the URI. The review checks run inside the api with the app's own settings and
# report Postgres and MongoDB there. The bundled containers are still checked.
pg_source=""; mongo_source=""; rabbit_source=""
if [ "$use_local_db" != "true" ]; then
    pg_source="USE_LOCAL_DB=false"; mongo_source="USE_LOCAL_DB=false"
fi
case "${API_PG_DB_HOST:-db_kodus_postgres}" in
    db_kodus_postgres) ;;
    *) [ -n "$pg_source" ] || pg_source="API_PG_DB_HOST=${API_PG_DB_HOST}" ;;
esac
if [ -n "${MONGODB_URI:-}" ]; then
    mongo_source="MONGODB_URI"
elif [ -n "${API_MG_DB_URI:-}" ]; then
    mongo_source="API_MG_DB_URI"
else
    case "${API_MG_DB_HOST:-db_kodus_mongodb}" in
        db_kodus_mongodb) ;;
        *) [ -n "$mongo_source" ] || mongo_source="API_MG_DB_HOST=${API_MG_DB_HOST}" ;;
    esac
fi
if [ "$use_local_rabbitmq" != "true" ]; then
    rabbit_source="USE_LOCAL_RABBITMQ=false"
elif [ -n "${API_RABBITMQ_URI:-}" ]; then
    # The driver reads the host as doctor_url_host does: the authority ends at
    # the first / ? or #. An @ after that point can be read two ways, and the
    # text cannot tell which: a generated (base64) password with an unencoded
    # / (kodus:pa/ss@rabbitmq:5672/kodus-ai, common) or an @ in the vhost
    # (rabbitmq:5672/kodus@ai, rare). So, failing safe: one ? line that is
    # right either way (encode it), and the broker counts as the bundled one if
    # either reading names it, so its checks are not skipped on a guess.
    rabbit_rest=${API_RABBITMQ_URI#*://}
    rabbit_authority=${rabbit_rest%%[/?#]*}
    rabbit_host=$(doctor_url_host "$API_RABBITMQ_URI")
    rabbit_hosts=$rabbit_host
    case "${rabbit_rest#"$rabbit_authority"}" in
        *@*)
            warnings=$((warnings + 1))
            doctor_add unknown infra "" \
                "API_RABBITMQ_URI has an @ after its host, so it can be read two ways." "" \
                "If the @ ends the user name and password, write any / ? # in them as %2F %3F %23; if it is part of the vhost, write it as %40. As written, the app connects to '${rabbit_host}'."
            rabbit_hosts="$rabbit_host $(doctor_url_host "amqp://${rabbit_rest##*@}")"
            ;;
    esac
    rabbit_bundled=""
    for h in $rabbit_hosts; do
        case "$h" in
            rabbitmq|rabbitmq-prod|"$(printf '%s' "${RABBITMQ_HOSTNAME:-rabbitmq}" | tr '[:upper:]' '[:lower:]')") rabbit_bundled=1 ;;
        esac
    done
    [ -n "$rabbit_bundled" ] || rabbit_source="API_RABBITMQ_URI host ${rabbit_host}"
fi
[ -n "$pg_source" ] && note "Postgres is external (${pg_source}): the review checks test it from inside the api, with the app's own settings."
[ -n "$mongo_source" ] && note "MongoDB is external (${mongo_source}): the review checks test it from inside the api, with the app's own settings."
[ -n "$rabbit_source" ] && note "RabbitMQ is external (${rabbit_source}): the review checks test it from inside the api, with the app's own settings."

postgres_id=$($DOCKER_COMPOSE ps -q db_kodus_postgres 2>/dev/null)
is_down db_kodus_postgres && postgres_id=""
if [ "$use_local_db" = "true" ]; then
    if [ -z "$postgres_id" ]; then
        # Already reported by the service status section (#2021).
        echo -e "${YELLOW}NOTE${NC} Skipping Postgres check (container not running)."
    else
        if $DOCKER_COMPOSE exec -T db_kodus_postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' &> /dev/null; then
            ok "Postgres is accepting connections."
        else
            err "Postgres is not accepting connections."
        fi
    fi

    mongo_id=$($DOCKER_COMPOSE ps -q db_kodus_mongodb 2>/dev/null)
    if [ -z "$mongo_id" ]; then
        # A mongod that refuses the kernel exits at once, so the container is
        # simply "not running". Say why when that is the reason.
        if docker logs db_kodus_mongodb 2>&1 | tail -20 | grep -q "SERVER-121912"; then
            err "MongoDB cannot start on this kernel (SERVER-121912)." \
                "Kodus has no database until MongoDB starts." \
                "Set KODUS_MONGO_IMAGE=docker.io/mongo:8.2.11 in .env and run docker compose up -d db_kodus_mongodb."
        else
            echo -e "${YELLOW}NOTE${NC} Skipping MongoDB check (container not running)."
        fi
    elif ! is_down db_kodus_mongodb; then
        # Credentials as quoted flags, not in a URI: a password with @ : / %
        # would break the URI and report a healthy MongoDB as down.
        if $DOCKER_COMPOSE exec -T db_kodus_mongodb sh -c 'mongosh --quiet --host 127.0.0.1 -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "db.runCommand({ ping: 1 }).ok" | grep -q 1' &> /dev/null; then
            ok "MongoDB is accepting connections."
        else
            err "MongoDB is not accepting connections."
        fi
    fi
fi

rabbit_id=$($DOCKER_COMPOSE ps -q rabbitmq 2>/dev/null)
is_down rabbitmq && rabbit_id=""
if [ "$use_local_rabbitmq" = "true" ]; then
    if [ -z "$rabbit_id" ]; then
        # The service status section already reported it; saying it again
        # turns one stopped broker into several lines (#2021).
        echo -e "${YELLOW}NOTE${NC} Skipping RabbitMQ check (container not running)."
    else
        if $DOCKER_COMPOSE exec -T rabbitmq rabbitmq-diagnostics -q check_running &> /dev/null; then
            ok "RabbitMQ is running."
            # The bundled broker's rabbitmq.conf (kodus-ai docker/rabbitMQ)
            # sets disk_free_limit.relative = 1.2 and
            # vm_memory_high_watermark.relative = 0.4.
            alarm_out=$($DOCKER_COMPOSE exec -T rabbitmq rabbitmq-diagnostics -q check_alarms 2>&1)
            alarm_rc=$?
            echo "$alarm_out"
            doctor_check_rabbit_alarms "$alarm_rc" "$alarm_out" \
                "Free disk space on this machine ('df -h /var/lib/docker'): the bundled RabbitMQ stops taking jobs while free disk is below 1.2 times the machine's RAM (disk_free_limit.relative = 1.2), and starts again by itself once there is room." \
                "RabbitMQ is holding more than 40% of the machine's memory (vm_memory_high_watermark.relative = 0.4), usually jobs piling up in a queue nothing takes: check '$DOCKER_COMPOSE exec rabbitmq rabbitmqctl list_queues -p kodus-ai name messages consumers', or give the machine more memory."
        else
            err "RabbitMQ is not running."
        fi
    fi
fi

section "HTTP checks"

http_check() {
    local name=$1
    local url=$2

    if ! command -v curl &> /dev/null; then
        warn "curl not found; skipping ${name} check (${url})."
        return 0
    fi

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$url" || true)
    if [ "$status" = "000" ] || [ -z "$status" ]; then
        err "${name} is not responding at ${url}."
        return 1
    fi

    if [ "$status" -ge 500 ] 2>/dev/null; then
        warn "${name} responded with ${status} at ${url}."
        return 0
    fi

    ok "${name} is responding (${status}) at ${url}."
    return 0
}

http_check_optional() {
    local name=$1
    local url=$2

    if ! command -v curl &> /dev/null; then
        warn "curl not found; skipping ${name} check (${url})."
        return 0
    fi

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$url" || true)
    if [ "$status" = "000" ] || [ -z "$status" ]; then
        warn "${name} is not responding at ${url}."
        return 0
    fi

    if [ "$status" -ge 500 ] 2>/dev/null; then
        warn "${name} responded with ${status} at ${url}."
        return 0
    fi

    ok "${name} is responding (${status}) at ${url}."
    return 0
}

web_port=${WEB_PORT:-3000}
api_port=${API_PORT:-3001}
webhooks_port=${API_WEBHOOKS_PORT:-${WEBHOOKS_PORT:-3332}}

# A stopped service was reported above; probing its port would only say it again.
for probe in "kodus-web|http://localhost:${web_port}/api/health" \
             "api|http://localhost:${api_port}/health" \
             "webhooks|http://localhost:${webhooks_port}/health"; do
    if is_down "${probe%%|*}"; then
        echo -e "${YELLOW}NOTE${NC} Skipping ${probe%%|*} HTTP check (service not running)."
    else
        http_check "${probe%%|*}" "${probe#*|}"
    fi
done

if [ "$api_mcp_enabled" = "true" ] && ! is_down kodus-mcp-manager; then
    http_check_optional "kodus-mcp-manager" "http://localhost:${mcp_manager_port}/health"
fi

# The web's server calls the api for sign-in and every page. Ask the web
# container itself, so its own env, DNS and networks are what is tested, and
# resolve the address exactly as pathToApiUrl/createUrl do
# (apps/web/src/core/utils/helpers.ts): WEB_HOSTNAME_API, where `localhost`
# means GLOBAL_API_CONTAINER_NAME (default kodus_api), a scheme in it is kept,
# and WEB_PORT_API. Any HTTP answer means the api is reachable; its health is
# checked on its own. Prints: url, host, 1 if localhost was mapped, result.
WEB_API_PROBE_JS=$(cat <<'JS'
const e = process.env;
let host = e.WEB_HOSTNAME_API || "";
let mapped = 0;
if (host === "localhost") { host = e.GLOBAL_API_CONTAINER_NAME || "kodus_api"; mapped = 1; }
let scheme = "";
if (host.startsWith("http://")) { scheme = "http"; host = host.slice(7); }
else if (host.startsWith("https://")) { scheme = "https"; host = host.slice(8); }
const port = e.WEB_PORT_API || "";
let base;
if (port) base = (scheme || "http") + "://" + host + ":" + port;
else if (scheme) base = scheme + "://" + host;
else if (e.WEB_NODE_ENV === "production" || (e.WEB_NODE_ENV === "self-hosted" && host !== "localhost")) base = "https://" + host;
else base = "http://" + host;
const url = base + "/health/simple";
const out = (r) => console.log([url, host, mapped, r].join("\t"));
fetch(url, { signal: AbortSignal.timeout(8000), redirect: "manual" })
  .then((res) => out(res.status))
  .catch((err) => out("ERR:" + ((err && err.cause && err.cause.code) || (err && err.name) || "error")));
JS
)

if [ -z "$WEB_HOSTNAME_API" ] || is_down kodus-web || [ -z "$($DOCKER_COMPOSE ps -q kodus-web 2>/dev/null)" ]; then
    echo -e "${YELLOW}NOTE${NC} Skipping the web-to-api check (kodus-web not running, or WEB_HOSTNAME_API empty; reported above)."
else
    probe=$($DOCKER_COMPOSE exec -T kodus-web node -e "$WEB_API_PROBE_JS" 2>/dev/null | tail -1)
    echo "web -> api: $probe"
    IFS=$'\t' read -r probe_url probe_host probe_mapped probe_result <<< "$probe"
    api_cname=$(docker inspect -f '{{.Name}}' "$($DOCKER_COMPOSE ps -q api 2>/dev/null | head -1)" 2>/dev/null)
    api_cname=${api_cname#/}
    case "$probe_result" in
        [0-9]*)
            ok "The web reaches the api at ${probe_url} (HTTP ${probe_result})."
            ;;
        ERR:TimeoutError|ERR:AbortError|ERR:UND_ERR_CONNECT_TIMEOUT|ERR:UND_ERR_HEADERS_TIMEOUT)
            warnings=$((warnings + 1))
            doctor_add unknown infra "" "The web's call to the api at ${probe_url} timed out." "" \
                "Check that the api is up ('$DOCKER_COMPOSE logs --tail 200 api'), then run this again."
            ;;
        ERR:*)
            if [ "$probe_mapped" = "1" ] && [ -n "$api_cname" ] && [ "$probe_host" != "$api_cname" ] && [ "$probe_host" != "api" ]; then
                web_api_fix="With WEB_HOSTNAME_API=localhost the web calls the api container by GLOBAL_API_CONTAINER_NAME ('${probe_host}'), but the api container is named '${api_cname}'. Set GLOBAL_API_CONTAINER_NAME=${probe_host} in .env and run '$DOCKER_COMPOSE up -d' (it recreates the api under that name)."
            else
                web_api_fix="Set WEB_HOSTNAME_API=localhost and WEB_PORT_API=3001 in .env (the web then calls the api container directly), and run '$DOCKER_COMPOSE up -d kodus-web'."
            fi
            err "The web cannot reach the api at ${probe_url} (${probe_result#ERR:})." \
                "Nobody can sign in, and every page fails." "$web_api_fix"
            ;;
        *)
            warnings=$((warnings + 1))
            doctor_add unknown infra "" "Could not check whether the web reaches the api." "" \
                "Run '$DOCKER_COMPOSE exec kodus-web node -v' to see that the web container answers, then run this again."
            ;;
    esac
fi

section "Database structure checks"

if [ -n "$pg_source" ]; then
    # The bundled container is not the database the app uses: its schemas say
    # nothing. The api's own checks read the real one.
    echo -e "${YELLOW}NOTE${NC} Skipping schema and seed checks (Postgres is external: ${pg_source})."
elif [ -z "$postgres_id" ]; then
    echo -e "${YELLOW}NOTE${NC} Skipping schema and seed checks (Postgres not running)."
else
    schemas=(public kodus_workflow)
    api_mcp_enabled=$(printf '%s' "$API_MCP_SERVER_ENABLED" | tr '[:upper:]' '[:lower:]')
    if [ "$api_mcp_enabled" = "true" ]; then
        schemas+=("$mcp_manager_schema")
    fi

    for schema in "${schemas[@]}"; do
        schema_exists=$(psql_exec "SELECT 1 FROM information_schema.schemata WHERE schema_name='${schema}' LIMIT 1;")
        if [ "$schema_exists" = "1" ]; then
            ok "Schema ${schema} exists."
        else
            err "Schema ${schema} is missing."
        fi
    done

    automation_exists=$(psql_exec "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='automation' LIMIT 1;")
    if [ "$automation_exists" = "1" ]; then
        ok "Table public.automation exists."
        automation_count=$(psql_exec "SELECT COUNT(*) FROM public.automation;")
        if [ -n "$automation_count" ] && [ "$automation_count" -gt 0 ] 2>/dev/null; then
            ok "Automation seed detected (${automation_count} row(s))."
        else
            err "Automation table is empty. Seeds may not have run."
        fi
    else
        err "Table public.automation not found."
    fi
fi

section "Message queue job time limit"

if [ -n "$rabbit_source" ] && [ "$use_local_rabbitmq" = "true" ]; then
    echo -e "${YELLOW}NOTE${NC} Skipping the job time limit check (the app uses another broker: ${rabbit_source})."
elif [ "$use_local_rabbitmq" = "true" ] && [ -n "$rabbit_id" ]; then
    doctor_check_consumer_timeout "$($DOCKER_COMPOSE exec -T rabbitmq rabbitmqctl eval 'application:get_env(rabbit, consumer_timeout).' 2>/dev/null)"
elif [ "$use_local_rabbitmq" = "true" ]; then
    # Bundled broker, stopped: already reported, and not "external" (#2021).
    echo -e "${YELLOW}NOTE${NC} Skipping the job time limit check (RabbitMQ container not running)."
else
    doctor_add unknown broker.consumer_timeout "" \
        "Could not check the message queue's job time limit (external RabbitMQ)." \
        "" "Make sure consumer_timeout is at least 7200000 (2 hours) on your broker."
fi

section "Reviews"

if is_down api; then
    echo -e "${YELLOW}NOTE${NC} Skipping the review checks (the api is not running; reported above)."
elif [ -z "$($DOCKER_COMPOSE ps -q api 2>/dev/null)" ]; then
    doctor_add fail reviews.api "" "The api service is not running." \
        "Nothing can be reviewed, and the review checks cannot run." \
        "Start it with '$DOCKER_COMPOSE up -d api' and check '$DOCKER_COMPOSE logs --tail 200 api'."
else
    doctor_run_app_checks "$DOCKER_COMPOSE exec -T api"
fi

doctor_render

# 1 = reviews do not run, 2 = could not verify (doctor-lib.sh).
exit "$(doctor_exit_code)"
