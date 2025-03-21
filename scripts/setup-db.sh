#!/bin/bash
# scripts/setup-db.sh

echo "Setting up database..."

# Criar arquivo de configuração dentro do container
docker-compose exec -T kodus-orchestrator bash -c 'cat > /usr/src/app/datasource.js << EOL
const { DataSource } = require("typeorm");
module.exports = new DataSource({
  type: "postgres",
  host: "db_kodus_postgres",
  port: 5432,
  username: process.env.API_PG_DB_USERNAME,
  password: process.env.API_PG_DB_PASSWORD,
  database: process.env.API_PG_DB_DATABASE,
  ssl: false,
  entities: ["./dist/modules/**/infra/typeorm/entities/*.js"],
  migrations: ["./dist/config/database/typeorm/migrations/*.js"]
});
EOL'

# Criar arquivo de configuração temporário para o seed
docker-compose exec -T kodus-orchestrator bash -c 'cat > /usr/src/app/seed-datasource.js << EOL
const { DataSource } = require("typeorm");
const dataSourceInstance = new DataSource({
  type: "postgres",
  host: "db_kodus_postgres",
  port: 5432,
  username: process.env.API_PG_DB_USERNAME,
  password: process.env.API_PG_DB_PASSWORD,
  database: process.env.API_PG_DB_DATABASE,
  ssl: false,
  entities: ["./dist/modules/**/infra/typeorm/entities/*.js"]
});
module.exports = { dataSourceInstance };
EOL'

# Rodar migrations dentro do container
echo "Running migrations..."
docker-compose exec -T kodus-orchestrator bash -c 'cd /usr/src/app && yarn typeorm migration:run -d datasource.js'

# Rodar seeds dentro do container com o novo arquivo de configuração
echo "Running seeds..."
docker-compose exec -T kodus-orchestrator bash -c '
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