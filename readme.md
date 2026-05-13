<div align="center">

<img src="https://kodus.io/wp-content/uploads/2025/04/kodusinstaller.png" alt="Kodus Installer Banner">

</div>

## Kodus Installer 

This repository contains the configuration needed to deploy Kodus in your own infrastructure.

## 🛠️ Prerequisites

- Docker
- Docker Compose
- Git

## 🔧 Installation

`./scripts/install.sh`

For a full walkthrough on deploying, check out our docs: https://docs.kodus.io/how_to_deploy/en/deploy_kodus/generic_vm

### Guided install with Claude Code

If you use [Claude Code](https://claude.ai/claude-code), you can run an interactive installation that walks you through every configuration option, generates secrets automatically, and verifies the deployment at the end.

```bash
npx skills add kodustech/kodus-installer@kodus-install
```

Then inside Claude Code, run:

```
/kodus-install
```

## External Databases or RabbitMQ

If you already have PostgreSQL/MongoDB or RabbitMQ, you can disable the local containers and point Kodus to the external services.

Example `.env`:
```bash
USE_LOCAL_DB=false
USE_LOCAL_RABBITMQ=false

API_PG_DB_HOST=your-postgres-host
API_PG_DB_PORT=5432
API_MG_DB_HOST=your-mongodb-host
API_MG_DB_PORT=27017

API_RABBITMQ_URI=amqp://user:pass@your-rabbitmq-host:5672/kodus-ai
```

When set to `false`, the installer skips starting local services and related health checks.

## End-to-end smoke test (local)

`scripts/test-e2e.sh` boots the full stack with a fresh `.env`, exposes the webhooks port through ngrok, opens a real PR on a test repo, waits for Kodus to post a review comment, and then tears everything down (containers, volumes, webhook, ngrok, PR).

Designed for **local** use against the published `ghcr.io/kodustech/*` images — not for CI, since CI doesn't have the freshly-built images yet.

One-time setup — create `.env.test-e2e` (gitignored) in the repo root:

```bash
TEST_REPO=your-org/kodus-test-sandbox        # GitHub repo to receive the PR
GH_TEST_TOKEN=ghp_xxx                    # PAT with `repo` + `admin:repo_hook`
NGROK_AUTHTOKEN=xxx                          # only if ngrok isn't already configured
```

Then run:

```bash
./scripts/test-e2e.sh
```

The script will (1) back up your current `.env`, (2) regenerate one from `.env.example` with fresh secrets, (3) inject the ngrok URL into the GitHub webhook config, (4) `./scripts/install.sh`, (5) sign up a test user via Playwright, (6) open a PR via `gh` on `TEST_REPO`, (7) poll the PR for a Kodus review comment, then (8) tear everything down. Pass `TEST_KEEP_RUNNING=1` to skip teardown for debugging.

If signup fails, check `scripts/test-e2e/failure.png` — the Playwright selectors are best-effort and may need tweaking for your UI version (see the `SELECTORS` block at the top of `signup.mjs`).

### On a Hetzner ephemeral VM (`scripts/test-e2e-vm.sh`)

Same flow but provisions a fresh CX22 (~$0.006/h), installs Docker + cloudflared via cloud-init, exposes the webhooks port through a free `https://*.trycloudflare.com` tunnel (no ngrok required), runs the test, and destroys the server. Closer to a real customer's install.

Extra env required in `.env.test-e2e`:

```bash
HCLOUD_TOKEN=xxx     # Hetzner Cloud API token (Read/Write)
# Optional:
HCLOUD_LOCATION=nbg1
HCLOUD_SERVER_TYPE=cx22
HCLOUD_IMAGE=ubuntu-24.04
```

Then:

```bash
./scripts/test-e2e-vm.sh
```

On failure, set `TEST_KEEP_RUNNING=1` to keep the VM up — the script prints the `ssh` command to connect and inspect logs (`docker compose logs api worker webhooks`). Remember to destroy the server manually afterwards at hetzner.cloud/servers, or it keeps billing.

## Troubleshooting

Start with the doctor script to pinpoint common setup issues: `./scripts/doctor.sh`

For `.env` problems specifically, run the schema validator (also invoked by doctor): `./scripts/validate-env.sh`

It checks each variable against the upstream schema (`.env.example` types + `scripts/schema-vars.sh` required list), flags type mismatches and missing required values, and — when containers are running — diffs your `.env` against what each container actually loaded so you can spot stale config that wasn't picked up by a recreate.

Common fixes:
- Docker daemon not running: `docker info`
- Ports already in use: `3000`, `3001`, `3101`, `3332`, `5432`, `27017`, `5672`, `15672`, `15692`
- `.env` missing or invalid: copy `.env.example` and fill required vars
- RabbitMQ connection errors: ensure `API_RABBITMQ_URI` matches `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, and vhost `kodus-ai`
- Database errors: confirm Postgres/Mongo credentials, then rerun `./scripts/setup-db.sh`
- Service crash or boot loop: check logs with `docker compose logs -f api` (or `worker`, `webhooks`, `rabbitmq`)

## Service Architecture

```mermaid
flowchart LR
  user((User)) --> web[kodus-web]
  web --> api[api]
  web --> webhooks[webhooks]
  api --> mcp[kodus-mcp-manager]
  api --> rabbitmq[(rabbitmq)]
  worker[worker] --> rabbitmq
  api --> pg[(db_kodus_postgres)]
  api --> mongo[(db_kodus_mongodb)]
  mcp --> pg
  webhooks --> pg
  webhooks --> mongo
```

## 📦 Available Services

- **kodus-web**: Application frontend
- **api**: Application API
- **worker**: Background jobs
- **webhooks**: Webhooks service
- **kodus-mcp-manager**: MCP manager service (optional, set `API_MCP_SERVER_ENABLED=true`)
- **rabbitmq**: Message broker
- **db_kodus_postgres**: PostgreSQL database
- **db_kodus_mongodb**: MongoDB database

## 🔐 Security

- All credentials are managed through environment variables
- Secure inter-service communication
- Container isolation
- Dedicated Docker networks

## 🤝 Contributing

Contributions are always welcome! Please read the contribution guidelines before submitting a pull request.

1. Fork the project
2. Create your Feature Branch (`git checkout -b feat/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feat/amazing-feature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📞 Support

For support, email support@kodus.io or open an issue in the repository.

---

<div align="center">
Made with ❤️ by the Kodus Team
</div>
