#!/bin/bash
# scripts/setup-db.sh

echo "Setting up database..."

if [ "${RUN_LEGACY_DB_SETUP:-false}" != "true" ]; then
    echo "Skipping legacy setup: migrations and seeds run automatically on app startup."
    echo "If you need to run this script, set RUN_LEGACY_DB_SETUP=true."
    exit 0
fi

# Detectar qual versão do Docker Compose está disponível
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    echo "Error: Docker Compose is not installed"
    exit 1
fi

# Criar arquivo de configuração dentro do container
$DOCKER_COMPOSE exec -T api bash -c 'cat > /usr/src/app/datasource.js << EOL
const MainSeeder = require("./dist/config/database/typeorm/seed/main.seeder").default;
const { DataSource } = require("typeorm");
module.exports = new DataSource({
  type: "postgres",
  host: process.env.API_PG_DB_HOST,
  port: 5432,
  username: process.env.API_PG_DB_USERNAME,
  password: process.env.API_PG_DB_PASSWORD,
  database: process.env.API_PG_DB_DATABASE,
  ssl: false,
  entities: [
    "./dist/core/infrastructure/adapters/repositories/typeorm/schema/*.model.js",
    "./dist/modules/**/infra/typeorm/entities/*.js"
  ],
  migrations: ["./dist/config/database/typeorm/migrations/*.js"],
  migrationsTransactionMode: "each",
  seeds: [MainSeeder]
});
EOL'

# Criar arquivo de configuração temporário para o seed
$DOCKER_COMPOSE exec -T api bash -c 'cat > /usr/src/app/seed-datasource.js << EOL
const MainSeeder = require("./dist/config/database/typeorm/seed/main.seeder").default;
const { DataSource } = require("typeorm");
const dataSourceInstance = new DataSource({
  type: "postgres",
  host: process.env.API_PG_DB_HOST,
  port: 5432,
  username: process.env.API_PG_DB_USERNAME,
  password: process.env.API_PG_DB_PASSWORD,
  database: process.env.API_PG_DB_DATABASE,
  ssl: false,
  entities: [
    "./dist/core/infrastructure/adapters/repositories/typeorm/schema/*.model.js",
    "./dist/modules/**/infra/typeorm/entities/*.js"
  ],
  seeds: [MainSeeder]
});
module.exports = { dataSourceInstance };
EOL'

# Criar extensão vector no banco de dados
echo "Creating vector extension..."
$DOCKER_COMPOSE exec -T api bash -c 'cd /usr/src/app && yarn typeorm query "CREATE EXTENSION IF NOT EXISTS vector;" -d datasource.js'

# Verificar se a extensão foi criada com sucesso
echo "Verifying vector extension..."
$DOCKER_COMPOSE exec -T api bash -c 'cd /usr/src/app && yarn typeorm query "SELECT extname, extversion FROM pg_extension WHERE extname = '\''vector'\'';" -d datasource.js'

# Rodar migrations dentro do container
echo "Running migrations..."
$DOCKER_COMPOSE exec -T api bash -c 'cd /usr/src/app && yarn typeorm migration:run -d datasource.js'

# Rodar seeds dentro do container com o novo arquivo de configuração
echo "Running seeds..."
$DOCKER_COMPOSE exec -T api bash -c '
cd /usr/src/app && 
export NODE_PATH=/usr/src/app/dist && 
node -e "
const { runSeeders } = require('\''typeorm-extension'\'');
const { dataSourceInstance } = require('\''./seed-datasource.js'\'');

async function runSeeds() {
  try {
    await dataSourceInstance.initialize();
    await runSeeders(dataSourceInstance);
    process.exit(0);
  } catch (error) {
    console.error('\''Error running seeds:'\'', error);
    process.exit(1);
  }
}

runSeeds();
"'

echo "Database setup completed!"
