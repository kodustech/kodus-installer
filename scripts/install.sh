#!/usr/bin/env bash
# install.sh

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Verificar se Docker está instalado
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi

# Verificar se Docker Compose está disponível
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo -e "${RED}Error: Docker Compose is not installed${NC}"
    exit 1
fi

echo -e "${GREEN}Using: $DOCKER_COMPOSE${NC}"

# Verifica se .env existe
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo -e "${YELLOW}Please create a .env file with all required variables${NC}"
    exit 1
fi

# Validar e carregar variáveis do arquivo .env
if [ -f .env ]; then
    echo -e "${YELLOW}Loading environment variables from .env file...${NC}"
    
    # Verificar se o arquivo .env tem conteúdo válido
    if ! grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*=' .env; then
        echo -e "${RED}Error: .env file does not contain valid environment variables${NC}"
        echo -e "${YELLOW}Expected format: VARIABLE_NAME=value${NC}"
        echo -e "${YELLOW}Please check your .env file and ensure it has proper environment variables${NC}"
        exit 1
    fi
    
    # Desabilitar glob expansion temporariamente
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
                            value="${value%%#*}"
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

    # Reabilitar glob expansion
    set +o noglob
fi

# Normalize booleans
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

normalize_host() {
    local host=$1
    host="${host#http://}"
    host="${host#https://}"
    host="${host%%/*}"
    host="${host%%:*}"
    printf '%s' "$host"
}

is_localhost() {
    local host
    host=$(normalize_host "$1")
    case "$host" in
        localhost|127.0.0.1|0.0.0.0)
            return 0
            ;;
        *)
            return 1
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
    local expected_host=$5

    if [ -z "$url" ]; then
        return 0
    fi

    if [[ "$url" != https://* ]]; then
        validation_errors+=("${var_name} (${label}) must start with https://")
    fi

    local host
    host=$(normalize_host "$url")
    if [ -z "$host" ]; then
        validation_errors+=("${var_name} (${label}) must include a valid host.")
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
        validation_errors+=("${var_name} (${label}) path must be one of ${expected_path} (example: https://${expected_host}${expected_paths[0]}).")
    fi
}

use_local_db=$(normalize_bool "${USE_LOCAL_DB:-true}")
use_local_rabbitmq=$(normalize_bool "${USE_LOCAL_RABBITMQ:-true}")
api_mcp_enabled=$(normalize_bool "${API_MCP_SERVER_ENABLED:-false}")

# Check required variables
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

missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    echo -e "${RED}Error: Missing required environment variables in .env:${NC}"
    for var in "${missing_vars[@]}"; do
        echo -e "${YELLOW}- ${var}${NC}"
    done
    exit 1
fi

if [ -z "$API_WEBHOOKS_PORT" ] && [ -n "$WEBHOOKS_PORT" ]; then
    echo -e "${YELLOW}Warning: WEBHOOKS_PORT is deprecated; use API_WEBHOOKS_PORT. Using WEBHOOKS_PORT for this run.${NC}"
    export API_WEBHOOKS_PORT="$WEBHOOKS_PORT"
fi

validation_errors=()
validation_warnings=()

if [ -n "$WEB_HOSTNAME_API" ]; then
    case "$WEB_HOSTNAME_API" in
        http://*|https://*)
            validation_errors+=("WEB_HOSTNAME_API must be hostname only (no scheme). Example: api.kodus.io")
            ;;
    esac
    if [[ "$WEB_HOSTNAME_API" == */* ]]; then
        validation_errors+=("WEB_HOSTNAME_API must not include path or trailing slash.")
    fi
    if is_localhost "$WEB_HOSTNAME_API"; then
        validation_warnings+=("WEB_HOSTNAME_API is localhost; cloud Git webhooks will not reach it unless your Git server is on the same network.")
    fi
fi

if [ -n "$NEXTAUTH_URL" ]; then
    case "$NEXTAUTH_URL" in
        http://*|https://*)
            ;;
        *)
            validation_errors+=("NEXTAUTH_URL must include http:// or https:// and be a full URL (e.g. https://kodus-web.yourdomain.com).")
            ;;
    esac
    nextauth_host=$(normalize_host "$NEXTAUTH_URL")
    if [ -z "$nextauth_host" ]; then
        validation_errors+=("NEXTAUTH_URL must include a valid host.")
    fi
    if is_localhost "$NEXTAUTH_URL"; then
        validation_warnings+=("NEXTAUTH_URL is localhost; cloud Git webhooks will not reach it unless your Git server is on the same network.")
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

if [ ${#webhook_providers[@]} -eq 0 ]; then
    validation_errors+=("At least one Git webhook URL must be configured (GitHub, GitLab, Bitbucket, or Azure Repos). See https://docs.kodus.io/how_to_deploy/en/deploy_kodus/generic_vm#git-provider-configuration")
else
    if [ -z "$WEB_HOSTNAME_API" ]; then
        validation_errors+=("WEB_HOSTNAME_API is required when configuring Git webhooks.")
    else
        expected_host=$(normalize_host "$WEB_HOSTNAME_API")
        validate_webhook_url "GitHub" "API_GITHUB_CODE_MANAGEMENT_WEBHOOK" "$API_GITHUB_CODE_MANAGEMENT_WEBHOOK" "/github/webhook" "$expected_host"
        validate_webhook_url "GitLab" "API_GITLAB_CODE_MANAGEMENT_WEBHOOK" "$API_GITLAB_CODE_MANAGEMENT_WEBHOOK" "/gitlab/webhook" "$expected_host"
        validate_webhook_url "Bitbucket" "GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK" "$GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK" "/bitbucket/webhook" "$expected_host"
        validate_webhook_url "Azure Repos" "GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK" "$GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK" "/azdevops/webhook|/azure-repos/webhook" "$expected_host"
    fi
fi

if [ ${#validation_errors[@]} -gt 0 ]; then
    echo -e "${RED}Error: invalid environment variables in .env:${NC}"
    for msg in "${validation_errors[@]}"; do
        echo -e "${YELLOW}- ${msg}${NC}"
    done
    exit 1
fi

if [ ${#validation_warnings[@]} -gt 0 ]; then
    for msg in "${validation_warnings[@]}"; do
        echo -e "${YELLOW}Warning: ${msg}${NC}"
    done
fi

if [ "$api_mcp_enabled" = "true" ]; then
    mcp_required_vars=(
        API_KODUS_SERVICE_MCP_MANAGER
        API_KODUS_MCP_SERVER_URL
    )
    mcp_missing_vars=()
    for var in "${mcp_required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            mcp_missing_vars+=("$var")
        fi
    done
    if [ ${#mcp_missing_vars[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing MCP environment variables in .env:${NC}"
        for var in "${mcp_missing_vars[@]}"; do
            echo -e "${YELLOW}- ${var}${NC}"
        done
        exit 1
    fi
fi

api_rabbitmq_enabled=$(printf '%s' "$API_RABBITMQ_ENABLED" | tr '[:upper:]' '[:lower:]')
if [ "$api_rabbitmq_enabled" != "true" ]; then
    echo -e "${RED}Error: API_RABBITMQ_ENABLED must be true (RabbitMQ is required).${NC}"
    exit 1
fi

if [ "$use_local_db" != "true" ]; then
    echo -e "${YELLOW}Using external databases (USE_LOCAL_DB=false).${NC}"
fi

if [ "$use_local_rabbitmq" != "true" ]; then
    echo -e "${YELLOW}Using external RabbitMQ (USE_LOCAL_RABBITMQ=false).${NC}"
fi

# Warn about legacy .env from 1.x
legacy_hits=()
if [ "${GLOBAL_API_CONTAINER_NAME}" = "kodus-orchestrator" ]; then
    legacy_hits+=("GLOBAL_API_CONTAINER_NAME=kodus-orchestrator")
fi
if [ "$use_local_rabbitmq" = "true" ]; then
    if [ -z "${RABBITMQ_DEFAULT_USER}" ]; then
        legacy_hits+=("missing RABBITMQ_DEFAULT_USER")
    fi
    if [ -z "${RABBITMQ_DEFAULT_PASS}" ]; then
        legacy_hits+=("missing RABBITMQ_DEFAULT_PASS")
    fi
    if [ -z "${RABBITMQ_HOSTNAME}" ]; then
        legacy_hits+=("missing RABBITMQ_HOSTNAME")
    fi
fi

if [ ${#legacy_hits[@]} -gt 0 ]; then
    echo -e "${YELLOW}Warning: detected a 1.x-style .env. Please review MIGRATION.md.${NC}"
    for hit in "${legacy_hits[@]}"; do
        echo -e "${YELLOW}- ${hit}${NC}"
    done
fi

# Wait helpers
wait_for_health() {
    local service_name=$1
    local timeout=${2:-120}
    local interval=${3:-5}
    local start_time
    start_time=$(date +%s)

    echo -e "${YELLOW}Waiting for ${service_name} to be healthy...${NC}"
    while true; do
        local container_id
        container_id=$($DOCKER_COMPOSE ps -q "$service_name")
        if [ -n "$container_id" ]; then
            local status
            status=$(docker inspect -f '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)
            if [ "$status" = "healthy" ]; then
                echo -e "${GREEN}${service_name} is healthy.${NC}"
                return 0
            fi
            if [ "$status" = "unhealthy" ]; then
                echo -e "${RED}${service_name} is unhealthy. Check logs with: $DOCKER_COMPOSE logs ${service_name}${NC}"
                return 1
            fi
        fi

        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            echo -e "${RED}Timeout waiting for ${service_name} to become healthy.${NC}"
            return 1
        fi
        sleep "$interval"
    done
}

wait_for_postgres() {
    local timeout=${1:-120}
    local interval=${2:-5}
    local start_time
    start_time=$(date +%s)

    echo -e "${YELLOW}Waiting for Postgres to be ready...${NC}"
    while true; do
        if $DOCKER_COMPOSE exec -T db_kodus_postgres pg_isready -U "$API_PG_DB_USERNAME" -d "$API_PG_DB_DATABASE" > /dev/null 2>&1; then
            echo -e "${GREEN}Postgres is ready.${NC}"
            return 0
        fi

        if [ $(( $(date +%s) - start_time )) -ge "$timeout" ]; then
            echo -e "${RED}Timeout waiting for Postgres.${NC}"
            return 1
        fi
        sleep "$interval"
    done
}

# Criar networks Docker necessárias
echo -e "${YELLOW}Creating Docker networks...${NC}"
docker network create shared-network 2>/dev/null || true
docker network create monitoring-network 2>/dev/null || true
docker network create kodus-backend-services 2>/dev/null || true

# Subir os containers
echo -e "${YELLOW}Starting containers...${NC}"
services=(kodus-web api worker webhooks)
if [ "$api_mcp_enabled" = "true" ]; then
    services+=(kodus-mcp-manager)
fi
if [ "$use_local_rabbitmq" = "true" ]; then
    services+=(rabbitmq)
fi
if [ "$use_local_db" = "true" ]; then
    services+=(db_kodus_postgres db_kodus_mongodb)
fi
$DOCKER_COMPOSE up -d --force-recreate "${services[@]}"

if [ "$use_local_rabbitmq" = "true" ]; then
    # Wait for RabbitMQ to be healthy
    wait_for_health rabbitmq 180 5
fi

if [ "$use_local_db" = "true" ]; then
    # Esperar o banco ficar pronto
    wait_for_postgres 180 5
fi

# Migrations and seeds now run automatically when the app starts.
echo -e "${YELLOW}Database migrations and seeds will run on app startup.${NC}"

# Aguardar o build do kodus-web
echo -e "${YELLOW}Waiting for kodus-web to be ready...${NC}"
max_attempts=30
attempt=1

while [ $attempt -le $max_attempts ]; do
    if $DOCKER_COMPOSE logs --tail 50 kodus-web 2>/dev/null | grep -Eq "Ready in|ready - started server"; then
        echo -e "${GREEN}kodus-web is ready.${NC}"
        break
    fi
    echo "Waiting for kodus-web to be ready... (attempt $attempt/$max_attempts)"
    sleep 10
    attempt=$((attempt + 1))
done

if [ $attempt -gt $max_attempts ]; then
    echo -e "${YELLOW}kodus-web may still be starting. Please check logs with: $DOCKER_COMPOSE logs kodus-web${NC}"
fi

echo -e "${GREEN}Installation completed!${NC}"
echo -e "${GREEN}You can access Kodus at: http://localhost:${WEB_PORT:-3000}${NC}"
