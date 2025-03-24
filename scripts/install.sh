#!/bin/bash
# install.sh

# Output colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to generate secure key
generate_secret_key() {
    openssl rand -base64 32
}

# Function to generate database password (alphanumeric)
generate_db_password() {
    openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16
}

# Function to update variable in .env file
update_env_var() {
    local key=$1
    local value=$2
    local file=$3
    
    # Escape special characters for sed
    value=$(printf "%s" "$value" | sed 's/[\/&]/\\&/g')
    
    # Replace variable in file
    sed -i.bak "s|^$key=.*|$key=$value|" "$file"
}

# Function to comment out variable in .env file
comment_env_var() {
    local key=$1
    local file=$2
    
    # Comment out variable in file
    sed -i.bak "s|^$key=|# $key=|" "$file"
}

# Check if .env exists
if [ ! -f .env ]; then
    # First ask which tool to use BEFORE creating .env
    # Clear screen to ensure prompt visibility
    clear
    
    # Display the configuration menu
    echo ""
    echo -e "${BLUE}========== TOOL CONFIGURATION ===========${NC}"
    echo -e "${BLUE}Which code management tool will you use?${NC}"
    echo -e "   1) GitHub"
    echo -e "   2) GitLab"
    echo -e "   3) Bitbucket"
    echo -e "   4) Multiple or all"
    echo -e "${YELLOW}-----------------------------------------------${NC}"
    echo -e "${YELLOW}Please enter a number between 1 and 4 and press ENTER${NC}"
    echo -e "${YELLOW}(If no input in 30 seconds, option 4 - all tools - will be used)${NC}"
    echo ""
    
    # Prompt with a forced delay to ensure it's visible
    echo -n "Your choice (1-4): "
    
    # Read user input with a timeout
    read -t 30 tool_choice || tool_choice=4
    
    # Determine which tool to use based on user input
    case $tool_choice in
        1)
            CODE_TOOL="github"
            ;;
        2)
            CODE_TOOL="gitlab"
            ;;
        3)
            CODE_TOOL="bitbucket"
            ;;
        4 | *)
            CODE_TOOL="all"
            if [ "$tool_choice" != "4" ]; then
                echo -e "${RED}Invalid option or timeout. Using default configuration (all tools).${NC}"
            fi
            ;;
    esac
    
    # Now create the .env file AFTER user has made their choice
    echo -e "${YELLOW}Creating .env file...${NC}"
    cp .env.example .env
    
    # Generate secure keys for NextAuth and JWT
    NEXTAUTH_SECRET=$(generate_secret_key)
    JWT_SECRET_KEY=$(generate_secret_key)
    
    # Generate database passwords
    PG_PASSWORD=$(generate_db_password)
    MG_PASSWORD=$(generate_db_password)
    API_JWT_SECRET=$(generate_secret_key)
    
    # Update values in .env file
    update_env_var WEB_NEXTAUTH_SECRET "$NEXTAUTH_SECRET" .env
    update_env_var WEB_JWT_SECRET_KEY "$JWT_SECRET_KEY" .env
    update_env_var API_PG_DB_PASSWORD "$PG_PASSWORD" .env
    update_env_var API_MG_DB_PASSWORD "$MG_PASSWORD" .env
    update_env_var API_JWT_SECRET "$API_JWT_SECRET" .env
    
    # Comment out unused variables based on chosen tool
    if [ "$CODE_TOOL" != "all" ]; then
        if [ "$CODE_TOOL" != "github" ]; then
            comment_env_var WEB_GITHUB_INSTALL_URL .env
            comment_env_var WEB_OAUTH_GITHUB_CLIENT_ID .env
            comment_env_var WEB_OAUTH_GITHUB_CLIENT_SECRET .env
            comment_env_var API_GITHUB_CODE_MANAGEMENT_WEBHOOK .env
            comment_env_var API_GITHUB_APP_ID .env
            comment_env_var API_GITHUB_CLIENT_SECRET .env
            comment_env_var API_GITHUB_PRIVATE_KEY .env
            comment_env_var GLOBAL_GITHUB_CLIENT_ID .env
            comment_env_var GLOBAL_GITHUB_REDIRECT_URI .env
        fi
        
        if [ "$CODE_TOOL" != "gitlab" ]; then
            comment_env_var WEB_GITLAB_SCOPES .env
            comment_env_var WEB_GITLAB_OAUTH_URL .env
            comment_env_var WEB_OAUTH_GITLAB_CLIENT_ID .env
            comment_env_var WEB_OAUTH_GITLAB_CLIENT_SECRET .env
            comment_env_var API_GITLAB_CODE_MANAGEMENT_WEBHOOK .env
            comment_env_var API_GITLAB_TOKEN_URL .env
            comment_env_var GLOBAL_GITLAB_CLIENT_ID .env
            comment_env_var GLOBAL_GITLAB_CLIENT_SECRET .env
            comment_env_var GLOBAL_GITLAB_REDIRECT_URL .env
        fi
        
        if [ "$CODE_TOOL" != "bitbucket" ]; then
            comment_env_var WEB_BITBUCKET_INSTALL_URL .env
            comment_env_var GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK .env
        fi
    fi
    
    # Remove backup file (macOS creates .bak automatically)
    rm -f .env.bak
    
    echo -e "${GREEN}Generated secure keys and passwords:${NC}"
    echo -e "${GREEN}- NextAuth Secret${NC}"
    echo -e "${GREEN}- JWT Secret Key${NC}"
    echo -e "${GREEN}- PostgreSQL Password${NC}"
    echo -e "${GREEN}- MongoDB Password${NC}"
    echo -e "${GREEN}- API JWT Secret${NC}"
    
    if [ "$CODE_TOOL" != "all" ]; then
        echo -e "${GREEN}Configured to use ${CODE_TOOL^}${NC}"
    else
        echo -e "${GREEN}Configured to use multiple code management tools${NC}"
    fi
    
    echo -e "${GREEN}Please review your .env file and run this script again${NC}"
    exit 0
fi

# Load environment variables from .env file
if [ -f .env ]; then
    echo -e "${YELLOW}Loading environment variables from .env file...${NC}"
    export $(grep -v '^#' .env | xargs)
fi

# Define required keys
REQUIRED_KEYS=(
    "WEB_NEXTAUTH_SECRET"
    "WEB_JWT_SECRET_KEY"
    "API_PG_DB_PASSWORD"
    "API_MG_DB_PASSWORD"
    "API_JWT_SECRET"
)

# Validate required keys
MISSING_KEYS=()
for KEY in "${REQUIRED_KEYS[@]}"; do
    # Check if variable is empty
    VALUE=$(eval echo \$${KEY})
    if [ -z "$VALUE" ]; then
        MISSING_KEYS+=("$KEY")
    fi
done

# If there are missing keys, display message and exit
if [ ${#MISSING_KEYS[@]} -gt 0 ]; then
    echo -e "${RED}The following required keys are missing or empty in the .env file:${NC}"
    for KEY in "${MISSING_KEYS[@]}"; do
        echo -e "${RED}- $KEY${NC}"
    done
    echo -e "${YELLOW}Please fill in these keys in the .env file and run this script again.${NC}"
    exit 1
fi

# Create required Docker networks
echo -e "${YELLOW}Creating Docker networks...${NC}"
docker network create shared-network 2>/dev/null || true
docker network create monitoring-network 2>/dev/null || true
docker network create kodus-backend-services 2>/dev/null || true

# Start containers
echo -e "${YELLOW}Starting containers...${NC}"
docker-compose up -d --force-recreate

# Wait for database to be ready
echo -e "${YELLOW}Waiting for database to be ready...${NC}"
sleep 10

# Run database setup
echo -e "${YELLOW}Setting up database...${NC}"
./scripts/setup-db.sh

# Wait for kodus-web build
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