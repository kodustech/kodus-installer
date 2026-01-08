# Railway Template (Kodus Self-Hosted)

This guide documents how to build a multi-service Railway template for Kodus and generate a Deploy button.
It uses the published Docker images for the app services, and builds RabbitMQ and the API edge router from this repo.

## Services and images

Public services:
- web (kodus-web): `ghcr.io/kodustech/kodus-web:latest` (port 3000)
- edge (kodus-edge): build from `railway/nginx/Dockerfile` (port `$PORT`)

Private services:
- api (kodus-api): `ghcr.io/kodustech/kodus-ai-api:latest` (port 3001)
- webhooks (kodus-webhooks): `ghcr.io/kodustech/kodus-ai-webhook:latest` (port 3332)
- worker (kodus-worker): `ghcr.io/kodustech/kodus-ai-worker:latest`
- mcp-manager (kodus-mcp-manager): `ghcr.io/kodustech/kodus-mcp-manager:latest` (port 3101)
- rabbitmq: build from `docker/rabbitmq/Dockerfile`
- postgres: build from `docker/pgvector/Dockerfile` (port 5432)
- mongodb: `mongo:8` (port 27017)

If you rename any service, update the internal URLs accordingly.

## Edge router (API + webhooks)

The edge service routes:
- `/github|gitlab|bitbucket|azure-repos|azdevops/webhook` -> webhooks service
- everything else -> api service

Set these environment variables on the edge service:
- `API_INTERNAL_URL=http://api.railway.internal:3001`
- `WEBHOOKS_INTERNAL_URL=http://webhooks.railway.internal:3332`

If you change service names, adjust the hostnames (for example, `kodus-api.railway.internal`).

## Storage

Attach a Railway volume to keep data:
- postgres -> `/var/lib/postgresql/data`
- mongodb -> `/data/db`
- rabbitmq -> `/var/lib/rabbitmq`

## Project variables

Use `.env.example` as your base and set values as project variables in Railway.
Then apply these Railway-specific settings:

Core URLs and ports
- `WEB_HOSTNAME_API=api.yourdomain.com` (no scheme)
- `WEB_PORT_API=443`
- `WEB_PORT=3000`
- `API_PORT=3001`
- `API_WEBHOOKS_PORT=3332`
- `API_MCP_MANAGER_PORT=3101`
- `NEXTAUTH_URL=https://web.yourdomain.com`

Postgres (pgvector)
- `API_PG_DB_HOST=${{postgres.RAILWAY_PRIVATE_DOMAIN}}`
- `API_PG_DB_PORT=5432`
- `API_PG_DB_USERNAME=${{postgres.POSTGRES_USER}}`
- `API_PG_DB_PASSWORD=${{postgres.POSTGRES_PASSWORD}}`
- `API_PG_DB_DATABASE=${{postgres.POSTGRES_DB}}`

MongoDB
- `API_MG_DB_HOST=mongodb.railway.internal`
- `API_MG_DB_PORT=27017`
- `API_MG_DB_USERNAME=${{mongodb.MONGO_INITDB_ROOT_USERNAME}}`
- `API_MG_DB_PASSWORD=${{mongodb.MONGO_INITDB_ROOT_PASSWORD}}`
- `API_MG_DB_DATABASE=${{mongodb.MONGO_INITDB_DATABASE}}`

RabbitMQ
- `RABBITMQ_DEFAULT_USER=youruser`
- `RABBITMQ_DEFAULT_PASS=yourpass`
- `API_RABBITMQ_URI=amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_DEFAULT_PASS}@rabbitmq.railway.internal:5672/kodus-ai`
- `API_RABBITMQ_ENABLED=true`

MCP (optional)
- `API_MCP_SERVER_ENABLED=true`
- `API_KODUS_SERVICE_MCP_MANAGER=http://mcp-manager.railway.internal:3101`
- `API_KODUS_MCP_SERVER_URL=https://api.yourdomain.com/mcp`

Security secrets (generate and replace)
- `WEB_NEXTAUTH_SECRET`
- `WEB_JWT_SECRET_KEY`
- `API_JWT_SECRET`
- `API_JWT_REFRESHSECRET`
- `API_MCP_MANAGER_JWT_SECRET`
- `API_MCP_MANAGER_ENCRYPTION_SECRET`

## Database service variables

Set these directly on the database services:

postgres service:
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_DB`

mongodb service:
- `MONGO_INITDB_ROOT_USERNAME`
- `MONGO_INITDB_ROOT_PASSWORD`
- `MONGO_INITDB_DATABASE`

RabbitMQ service:
- `RABBITMQ_DEFAULT_USER`
- `RABBITMQ_DEFAULT_PASS`

## Postgres extension

The custom Postgres image copies `docker/pgvector/initdb.d/01-vector.sql` into
`/docker-entrypoint-initdb.d`, so the `vector` extension is created automatically
for new databases. If you attach an existing database, run the SQL once:
```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

## Create the Railway template and Deploy button

1. Create a Railway project and add all services listed above.
2. Configure public domains for `web` and `edge` only.
3. Set the environment variables and deploy.
4. In Railway, go to Project Settings -> Template -> Create Template.
5. Copy the template link and publish if needed.

Deploy button format:
```
[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/<TEMPLATE_ID>)
```

Replace `<TEMPLATE_ID>` with your template id from Railway.
