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

# Criar networks Docker necessárias
echo -e "${YELLOW}Creating Docker networks...${NC}"
docker network create shared-network 2>/dev/null || true
docker network create monitoring-network 2>/dev/null || true
docker network create kodus-backend-services 2>/dev/null || true

# Subir os containers
echo -e "${YELLOW}Starting containers...${NC}"
$DOCKER_COMPOSE up -d --force-recreate

# Esperar o banco ficar pronto (você pode usar wait-for-it.sh aqui)
echo -e "${YELLOW}Waiting for database to be ready...${NC}"
sleep 10

# Rodar setup do banco
echo -e "${YELLOW}Setting up database...${NC}"
./scripts/setup-db.sh

# Aguardar o build do kodus-web
echo -e "${YELLOW}Waiting for kodus-web to be ready...${NC}"
max_attempts=30
attempt=1

while ! $DOCKER_COMPOSE logs kodus-web | grep -q "Ready in"; do
    if [ $attempt -gt $max_attempts ]; then
        echo -e "${YELLOW}Timeout waiting for kodus-web. Please check the logs with: $DOCKER_COMPOSE logs kodus-web${NC}"
        exit 1
    fi
    echo "Waiting for kodus-web to be ready... (attempt $attempt/$max_attempts)"
    sleep 10
    attempt=$((attempt + 1))
done

echo -e "${GREEN}Installation completed!${NC}"
echo -e "${GREEN}You can access Kodus at: http://localhost:${WEB_PORT:-3000}${NC}"