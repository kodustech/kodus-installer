#!/bin/bash

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
}

warn() {
    echo -e "${YELLOW}WARN${NC} $1"
    warnings=$((warnings + 1))
}

err() {
    echo -e "${RED}ERROR${NC} $1"
    errors=$((errors + 1))
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
        set -a
        source <(grep -v '^#' .env | grep -v '^[[:space:]]*$' | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*=')
        set +a
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

    required_vars=(
        API_PG_DB_USERNAME
        API_PG_DB_PASSWORD
        API_PG_DB_DATABASE
        API_MG_DB_USERNAME
        API_MG_DB_PASSWORD
        API_MG_DB_DATABASE
        API_RABBITMQ_URI
        API_RABBITMQ_ENABLED
    )

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            err "Missing required variable: ${var}"
        fi
    done

    if [ "$api_mcp_enabled" = "true" ]; then
        mcp_required_vars=(
            API_KODUS_SERVICE_MCP_MANAGER
            API_KODUS_MCP_SERVER_URL
        )
        for var in "${mcp_required_vars[@]}"; do
            if [ -z "${!var}" ]; then
                err "Missing MCP variable: ${var}"
            fi
        done
    fi

    api_rabbitmq_enabled=$(printf '%s' "$API_RABBITMQ_ENABLED" | tr '[:upper:]' '[:lower:]')
    if [ "$api_rabbitmq_enabled" != "true" ]; then
        warn "API_RABBITMQ_ENABLED is not true (RabbitMQ is required)."
    fi

    if [ -n "$API_RABBITMQ_URI" ] && ! printf '%s' "$API_RABBITMQ_URI" | grep -Eq '/(kodus-ai|kodus-ast)$'; then
        warn "API_RABBITMQ_URI does not end with /kodus-ai or /kodus-ast."
    fi

    if [ "$use_local_db" != "true" ]; then
        warn "USE_LOCAL_DB=false: skipping local DB container checks."
    fi

    if [ "$use_local_rabbitmq" != "true" ]; then
        warn "USE_LOCAL_RABBITMQ=false: skipping local RabbitMQ container checks."
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
    for opt in "${optional_services[@]}"; do
        if [ "$opt" = "$svc" ]; then
            return 0
        fi
    done
    return 1
}

services=$($DOCKER_COMPOSE config --services 2>/dev/null)
if [ -z "$services" ]; then
    warn "No services found in compose config."
else
    for service in $services; do
        container_id=$($DOCKER_COMPOSE ps -q "$service")
        if [ -z "$container_id" ]; then
            if [ "$service" = "migration" ]; then
                ok "Service ${service} is not running (one-off)."
            elif is_optional_service "$service"; then
                ok "Service ${service} is not running (disabled by config)."
            else
                warn "Service ${service} is not running."
            fi
            continue
        fi

        status=$(docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null)
        if [ "$status" = "running" ]; then
            ok "Service ${service} is running."
        else
            err "Service ${service} status is ${status}."
        fi

        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id" 2>/dev/null)
        if [ -n "$health" ]; then
            if [ "$health" = "healthy" ]; then
                ok "Service ${service} is healthy."
            elif [ "$health" = "unhealthy" ]; then
                err "Service ${service} is unhealthy."
            else
                warn "Service ${service} health is ${health}."
            fi
        fi
    done
fi

section "Connectivity checks"

postgres_id=$($DOCKER_COMPOSE ps -q db_kodus_postgres 2>/dev/null)
if [ "$use_local_db" = "true" ]; then
    if [ -z "$postgres_id" ]; then
        warn "Skipping Postgres check (container not running)."
    else
        if $DOCKER_COMPOSE exec -T db_kodus_postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' &> /dev/null; then
            ok "Postgres is accepting connections."
        else
            err "Postgres is not accepting connections."
        fi
    fi

    mongo_id=$($DOCKER_COMPOSE ps -q db_kodus_mongodb 2>/dev/null)
    if [ -z "$mongo_id" ]; then
        warn "Skipping MongoDB check (container not running)."
    else
        if $DOCKER_COMPOSE exec -T db_kodus_mongodb sh -c 'mongosh --quiet "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/admin" --eval "db.runCommand({ ping: 1 }).ok" | grep -q 1' &> /dev/null; then
            ok "MongoDB is accepting connections."
        else
            err "MongoDB is not accepting connections."
        fi
    fi
else
    if command -v pg_isready &> /dev/null; then
        if PGPASSWORD="$API_PG_DB_PASSWORD" pg_isready -h "$API_PG_DB_HOST" -p "${API_PG_DB_PORT:-5432}" -U "$API_PG_DB_USERNAME" -d "$API_PG_DB_DATABASE" &> /dev/null; then
            ok "External Postgres is accepting connections."
        else
            err "External Postgres is not accepting connections."
        fi
    else
        warn "pg_isready not found; skipping external Postgres check."
    fi

    if command -v mongosh &> /dev/null; then
        if mongosh --quiet "mongodb://${API_MG_DB_USERNAME}:${API_MG_DB_PASSWORD}@${API_MG_DB_HOST}:${API_MG_DB_PORT:-27017}/admin" --eval "db.runCommand({ ping: 1 }).ok" | grep -q 1; then
            ok "External MongoDB is accepting connections."
        else
            err "External MongoDB is not accepting connections."
        fi
    else
        warn "mongosh not found; skipping external MongoDB check."
    fi
fi

rabbit_id=$($DOCKER_COMPOSE ps -q rabbitmq 2>/dev/null)
if [ "$use_local_rabbitmq" = "true" ]; then
    if [ -z "$rabbit_id" ]; then
        warn "Skipping RabbitMQ check (container not running)."
    else
        if $DOCKER_COMPOSE exec -T rabbitmq rabbitmq-diagnostics -q check_running &> /dev/null; then
            ok "RabbitMQ is running."
        else
            err "RabbitMQ is not running."
        fi
    fi
else
    if command -v nc &> /dev/null; then
        rabbit_uri="${API_RABBITMQ_URI}"
        rabbit_no_scheme="${rabbit_uri#*://}"
        rabbit_hostport="${rabbit_no_scheme%%/*}"
        rabbit_hostport="${rabbit_hostport#*@}"
        rabbit_host="${rabbit_hostport%%:*}"
        rabbit_port="${rabbit_hostport##*:}"
        if [ "$rabbit_hostport" = "$rabbit_host" ]; then
            rabbit_port="5672"
        fi

        if nc -z -w 3 "$rabbit_host" "$rabbit_port" &> /dev/null; then
            ok "External RabbitMQ is reachable at ${rabbit_host}:${rabbit_port}."
        else
            err "External RabbitMQ is not reachable at ${rabbit_host}:${rabbit_port}."
        fi
    else
        warn "nc not found; skipping external RabbitMQ check."
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

web_port=${WEB_PORT:-3000}
api_port=${API_PORT:-3001}
webhooks_port=${WEBHOOKS_PORT:-3332}

http_check "kodus-web" "http://localhost:${web_port}/health"
http_check "api" "http://localhost:${api_port}/health"
http_check "webhooks" "http://localhost:${webhooks_port}/health"

if [ "$api_mcp_enabled" = "true" ]; then
    http_check "kodus-mcp-manager" "http://localhost:${mcp_manager_port}/health"
fi

section "Database structure checks"

if [ "$use_local_db" != "true" ]; then
    warn "Skipping schema and seed checks (USE_LOCAL_DB=false)."
elif [ -z "$postgres_id" ]; then
    warn "Skipping schema and seed checks (Postgres not running)."
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

section "Summary"

if [ "$errors" -gt 0 ]; then
    echo -e "${RED}Doctor found ${errors} error(s) and ${warnings} warning(s).${NC}"
    exit 1
fi

if [ "$warnings" -gt 0 ]; then
    echo -e "${YELLOW}Doctor found ${warnings} warning(s).${NC}"
else
    echo -e "${GREEN}All checks passed.${NC}"
fi
