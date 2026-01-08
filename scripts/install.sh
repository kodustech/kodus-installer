#!/bin/bash
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
    
    # Carregar variáveis usando set -a para auto-export
    set -a
    source <(grep -v '^#' .env | grep -v '^[[:space:]]*$' | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*=')
    set +a
    
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

# Rodar setup do banco
echo -e "${YELLOW}Setting up database...${NC}"
./scripts/setup-db.sh

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
