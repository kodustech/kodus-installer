#!/bin/bash
# install.sh

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Verifica se .env existe
if [ ! -f .env ]; then
    echo -e "${YELLOW}Creating .env file...${NC}"
    cp .env.example .env
    echo -e "${GREEN}Please configure your .env file and run this script again${NC}"
    exit 0
fi

# Carregar variáveis do arquivo .env
if [ -f .env ]; then
    echo -e "${YELLOW}Loading environment variables from .env file...${NC}"
    export $(grep -v '^#' .env | xargs)
fi

# Criar networks Docker necessárias
echo -e "${YELLOW}Creating Docker networks...${NC}"
docker network create shared-network 2>/dev/null || true
docker network create monitoring-network 2>/dev/null || true
docker network create kodus-backend-services 2>/dev/null || true

# Subir os containers
echo -e "${YELLOW}Starting containers...${NC}"
docker-compose up -d --force-recreate

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

while ! docker-compose logs kodus-web | grep -q "Ready in"; do
    if [ $attempt -gt $max_attempts ]; then
        echo -e "${YELLOW}Timeout waiting for kodus-web. Please check the logs with: docker-compose logs kodus-web${NC}"
        exit 1
    fi
    echo "Waiting for kodus-web to be ready... (attempt $attempt/$max_attempts)"
    sleep 10
    attempt=$((attempt + 1))
done

echo -e "${GREEN}Installation completed!${NC}"
echo -e "${GREEN}You can access Kodus at: http://localhost:${WEB_PORT:-3000}${NC}"