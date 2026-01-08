#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ENV_FILE=".env"

echo -e "${YELLOW}Generating security keys...${NC}"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

WEB_NEXTAUTH_SECRET=$(openssl rand -base64 32)
WEB_JWT_SECRET_KEY=$(openssl rand -base64 32)
API_CRYPTO_KEY=$(openssl rand -hex 32)
API_JWT_SECRET=$(openssl rand -base64 32)
API_JWT_REFRESHSECRET=$(openssl rand -base64 32)
CODE_MANAGEMENT_SECRET=$(openssl rand -hex 32)
CODE_MANAGEMENT_WEBHOOK_TOKEN=$(openssl rand -base64 32 | tr -d '=' | tr '/+' '_-')
API_MCP_MANAGER_ENCRYPTION_SECRET=$(openssl rand -hex 32)
API_MCP_MANAGER_JWT_SECRET=$(openssl rand -base64 32)

update_or_add_var() {
    local key=$1
    local value=$2
    
    if grep -q "^${key}=" "$ENV_FILE"; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
        else
            sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
        fi
        echo -e "${GREEN}✓ Updated ${key}${NC}"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
        echo -e "${GREEN}✓ Added ${key}${NC}"
    fi
}

echo -e "\n${YELLOW}Updating .env file...${NC}"
update_or_add_var "WEB_NEXTAUTH_SECRET" "$WEB_NEXTAUTH_SECRET"
update_or_add_var "WEB_JWT_SECRET_KEY" "$WEB_JWT_SECRET_KEY"
update_or_add_var "API_CRYPTO_KEY" "$API_CRYPTO_KEY"
update_or_add_var "API_JWT_SECRET" "$API_JWT_SECRET"
update_or_add_var "API_JWT_REFRESHSECRET" "$API_JWT_REFRESHSECRET"
update_or_add_var "CODE_MANAGEMENT_SECRET" "$CODE_MANAGEMENT_SECRET"
update_or_add_var "CODE_MANAGEMENT_WEBHOOK_TOKEN" "$CODE_MANAGEMENT_WEBHOOK_TOKEN"
update_or_add_var "API_MCP_MANAGER_ENCRYPTION_SECRET" "$API_MCP_MANAGER_ENCRYPTION_SECRET"
update_or_add_var "API_MCP_MANAGER_JWT_SECRET" "$API_MCP_MANAGER_JWT_SECRET"

echo -e "\n${GREEN}All security keys have been generated and updated in .env file!${NC}"
