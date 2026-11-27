# Kodus on Coolify

Deploy [Kodus](https://github.com/kodustech/kodus-ai) on a self-hosted [Coolify](https://coolify.io) instance using its Git-based Docker Compose resource.

## Why a separate Compose file?

The root [`docker-compose.yml`](../docker-compose.yml) expects [`scripts/install.sh`](../scripts/install.sh) to pre-create three `external: true` Docker networks and publishes service ports directly on the host. Coolify runs Docker Compose directly and routes traffic through its built-in Traefik reverse proxy, so [`coolify/docker-compose.yml`](docker-compose.yml) adjusts three things:

- Replaces host `ports` bindings with `expose` so Traefik reaches services over the Docker network and PostgreSQL, MongoDB, and RabbitMQ stay off the public interface.
- Switches `shared-network`, `monitoring-network`, and `kodus-backend-services` from `external: true` to `driver: bridge` so Compose creates them automatically.
- Points bind mounts (`../docker-entrypoint-initdb.d`, `../docker/pgbouncer/entrypoint.sh`) to the repository root.

## Setup in Coolify

1. Create a new resource: **+ New** → **Public Repository** (or your fork).
2. Set the repository URL to `https://github.com/kodustech/kodus-installer` and branch to `main`.
3. Select **Docker Compose** as the build pack and set:
   - **Base Directory:** `/`
   - **Docker Compose Location:** `/coolify/docker-compose.yml`
4. Configure domains in Coolify for the public services:

| Service | Internal port | Example domain |
|---------|---------------|----------------|
| `kodus-web` | `3000` (`WEB_PORT`) | `https://kodus.yourdomain.com:3000` |
| `api` | `3001` | `https://api.kodus.yourdomain.com:3001` |
| `webhooks` | `3332` (`API_WEBHOOKS_PORT`) | `https://webhooks.kodus.yourdomain.com:3332` |
| `kodus-mcp-manager` *(optional)* | `3101` | `https://mcp.kodus.yourdomain.com:3101` |

5. Populate **Environment Variables** in Coolify using [`.env.example`](../.env.example) as a starting point. You can generate the required secrets locally first with `cp .env.example .env && ./scripts/generate-secrets.sh` and paste the resulting `.env` into Coolify's Developer View.

Key variables to verify:

| Variable | Example |
|----------|---------|
| `IMAGE_TAG` | Pin a release tag (e.g. `2.2.12`) or leave unset for `latest` |
| `WEB_PORT` | `3000` |
| `WEB_HOSTNAME_API` | `api` *(internal Docker service name; if using a public HTTPS URL instead, include the `https://` scheme)* |
| `WEB_PORT_API` | `3001` *(or `443` when `WEB_HOSTNAME_API` uses `https://`)* |
| `NEXTAUTH_URL` | `https://kodus.yourdomain.com` |
| `API_<provider>_CODE_MANAGEMENT_WEBHOOK` | `https://webhooks.kodus.yourdomain.com/<provider>/webhook` — GitHub (`/github/webhook`), GitLab (`/gitlab/webhook`), Forgejo (`/forgejo/webhook`); for Bitbucket use `GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK` (`.../bitbucket/webhook`) and for Azure Repos use `GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK` (`.../azure-repos/webhook`) |
| `API_RABBITMQ_ENABLED` | `true` |
| `API_OPEN_AI_API_KEY` | Your OpenAI or Anthropic key *(or configure later under **Settings → BYOK**)* |

> **Linux kernel 6.19+ hosts:** MongoDB 8.3 does not start on kernels 6.19+. Set `KODUS_MONGO_IMAGE=docker.io/mongo:8.2.11` in Coolify's environment variables before the first deploy.

6. Click **Deploy**. Database migrations run automatically when `api` starts.

## Updating

- **App version:** Update `IMAGE_TAG` in Coolify's environment variables (or leave it on `latest`) and click **Redeploy**.
- **Stack updates:** Pull the latest changes and redeploy; persistent data lives in the named volumes (`pgdata`, `mongodbdata`, `rabbitmq-data-prod`, `log_volume`).

See [`docs/compose.md`](../docs/compose.md) for external databases, optional services (`analytics` / `pgbouncer` profiles), and troubleshooting.
