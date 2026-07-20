# Kodus on Docker Compose

The fastest way to self-host [Kodus](https://github.com/kodustech/kodus-ai) — the
AI code reviewer whose agent Kody reviews your pull requests — on a single VM or
host. For clusters, use the [Helm charts](../charts/README.md) instead. New here?
Read the [root README](../readme.md) first for what Kodus is and how it works.

This guide is the in-repo companion to the hosted walkthrough at
[docs.kodus.io](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/generic_vm).

## Requirements

- **Docker** and **Docker Compose** (v2 `docker compose` or legacy `docker-compose`)
- **Git**
- A host reachable by your Git provider **for webhooks** (a public hostname, or a
  tunnel like ngrok/cloudflared for local testing)
- An **LLM API key** (OpenAI or Anthropic) — reviews don't run without one

## Quick start

```bash
# 1. Get the config template and mint secrets
cp .env.example .env
./scripts/generate-secrets.sh        # fills JWT/crypto/etc. secrets in .env

# 2. Edit .env — set the required values (see Configuration below)

# 3. Validate, then install
./scripts/validate-env.sh            # checks required vars & types against the schema
./scripts/install.sh                 # starts the stack, waits for health
```

`install.sh` refuses to start until the required variables are set and the webhook
URLs are well-formed, so fix anything it reports before re-running. When it
finishes, open **http://localhost:${WEB_PORT:-3000}**.

> Migrations and seeds run **automatically** when the `api` container starts — there
> is no separate migration step.

### Guided install with Claude Code

Prefer an interactive install that walks every option, generates secrets, and
verifies the result? See the [root README](../readme.md) (Quick start → Option A).

## Configuration

Required values live in `.env`. The authoritative required-list is generated from
kodus-ai's schema (`scripts/schema-vars.sh`) and enforced by both `validate-env.sh`
and `install.sh`. The ones you'll always set:

| Variable | What it is |
|----------|------------|
| `WEB_HOSTNAME_API` | Hostname **only** (no scheme/path) the web uses to reach the API. Required once webhooks are configured. |
| `NEXTAUTH_URL` | Full URL of the web UI (`https://…` in production). Used for sign-in/OAuth callbacks. |
| `API_<provider>_CODE_MANAGEMENT_WEBHOOK` | Public `https://` URL the Git provider calls, e.g. `https://<host>/github/webhook`. **At least one is required** (GitHub, GitLab, Bitbucket, Azure Repos, Forgejo). |
| `API_RABBITMQ_ENABLED` | Must be `true` — RabbitMQ is required. |
| Secrets (JWT, crypto, …) | Minted by `./scripts/generate-secrets.sh`; never hand-write them. |

**LLM key (for reviews).** Kodus is bring-your-own-key. Set `API_OPEN_AI_API_KEY`
in `.env` **or** add it later in the UI (**Settings → BYOK**). Anthropic/Claude
keys go in the **same** `API_OPEN_AI_API_KEY` slot — Kodus picks the SDK from the
model id. Not required to boot, but no reviews run without it.

**Version pinning.** `IMAGE_TAG` selects the Kodus version for every app image
(defaults to `latest` — pin a real tag like `2.1.24` in production).

### Optional services

- **MCP manager** — set `API_MCP_SERVER_ENABLED=true` and `install.sh` starts the
  `kodus-mcp-manager` container (it provisions Model Context Protocol servers per
  organization). Requires `API_KODUS_SERVICE_MCP_MANAGER` and
  `API_KODUS_MCP_SERVER_URL`.
- **Analytics worker** — behind the `analytics` Compose profile. Start it with:
  ```bash
  docker compose --profile analytics up -d worker-analytics
  ```

## Your first review

Once the stack is healthy:

1. Open **http://localhost:${WEB_PORT:-3000}** and create an account.
2. Ensure an **LLM key** is set (`.env` or **Settings → BYOK**).
3. Under **Git Settings**, connect a repository — Kodus registers the webhook on
   the provider using the `API_<provider>_CODE_MANAGEMENT_WEBHOOK` URL, which must
   be reachable from the internet.
4. Open a pull request. Kody reviews it automatically, or comment
   `@kody start-review`.

See the [root README](../readme.md#your-first-review) for the same flow condensed.

## External databases or RabbitMQ

Already run PostgreSQL (with pgvector), MongoDB, or RabbitMQ? Point Kodus at them
and skip the local containers:

```bash
USE_LOCAL_DB=false
USE_LOCAL_RABBITMQ=false

API_PG_DB_HOST=your-postgres-host      # needs the pgvector extension
API_PG_DB_PORT=5432
API_MG_DB_HOST=your-mongodb-host
API_MG_DB_PORT=27017

API_RABBITMQ_URI=amqp://user:pass@your-rabbitmq-host:5672/kodus-ai
```

With `false`, `install.sh` doesn't start (or health-check) the corresponding local
service. The RabbitMQ vhost must be `kodus-ai`, and the URI credentials must match
`RABBITMQ_DEFAULT_USER` / `RABBITMQ_DEFAULT_PASS` when using the bundled broker.

## Updating to a new version

```bash
# 1. Pin the new version
#    edit .env → IMAGE_TAG=<new-tag>

# 2. Pull and recreate (migrations run on api startup)
docker compose pull
./scripts/install.sh          # or: docker compose up -d --force-recreate
```

Pull the latest installer too (`git pull`) so `docker-compose.yml`,
`scripts/schema-vars.sh`, and `.env.example` stay in sync with the release.

## Data & backups

Persistent data lives in named Docker volumes — back these up:

| Volume | Contents |
|--------|----------|
| `pgdata` | PostgreSQL (primary data) |
| `mongodbdata` | MongoDB |
| `rabbitmq-data-prod` | RabbitMQ state |
| `log_volume` | Service logs |

`docker compose down` stops the stack **without** deleting these volumes; add `-v`
only when you intend to wipe all data.

## Verify the deployment

```bash
./scripts/doctor.sh            # health of every service + config sanity
./scripts/validate-env.sh      # .env vs schema; diffs against what containers loaded
```

`doctor.sh` is the first thing to run when something looks off — it pinpoints
missing/invalid config, unhealthy containers, and common webhook mistakes.

## Ports

| Port | Service |
|------|---------|
| 3000 | web UI |
| 3001 | api |
| 3101 | mcp-manager (when enabled) |
| 3332 | webhooks |
| 5432 | PostgreSQL |
| 27017 | MongoDB |
| 5672 | RabbitMQ (AMQP) |
| 15672 | RabbitMQ management UI |
| 15692 | RabbitMQ Prometheus metrics |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `install.sh` reports missing/invalid vars | Set them in `.env`; re-run `validate-env.sh` |
| Docker daemon not running | `docker info` |
| Port already in use | Free the port or remap it in `.env` (see the table above) |
| RabbitMQ connection errors | `API_RABBITMQ_URI` must match user/pass and use vhost `kodus-ai` |
| DB errors | Check Postgres/Mongo credentials; Postgres needs the pgvector extension |
| Service crash / boot loop | `docker compose logs -f api` (or `worker`, `webhooks`, `rabbitmq`) |
| **Reviews never trigger** | No LLM key set, or the webhook URL isn't reachable from your Git provider — see [Your first review](#your-first-review) |

## Security notes

- Secrets are generated into `.env` (and read as env vars) — keep `.env` out of
  version control (`.gitignore` already excludes it).
- Databases and RabbitMQ are only published on the host for convenience; in
  production, restrict those ports with a firewall or remove the host port
  mappings and reach them over the internal Compose networks only.
- Pin `IMAGE_TAG` to a real release (never `latest`) for reproducible deploys.
- For encryption in transit/at rest, air-gapped setups, and SOC 2-oriented
  hardening, the [Helm deployment](../charts/README.md) has dedicated guidance.

## Related docs

Official docs at [docs.kodus.io](https://docs.kodus.io) go deeper on:

- [Architecture](https://docs.kodus.io/how_to_deploy/en/kodus_architecture) — services, networks, data flow
- [Production install (VM)](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/generic_vm) · [Updating](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/updating) · [Reverse proxy](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/reverse_proxy) · [Troubleshooting](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/troubleshooting)
- [MCP manager](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/mcp_manager) · [Analytics worker](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/analytics_worker)
- Git provider webhooks: [GitHub](https://docs.kodus.io/how_to_deploy/en/platforms/github/github_webhook) · [GitLab](https://docs.kodus.io/how_to_deploy/en/platforms/gitlab/gitlab_webhook) · [Bitbucket](https://docs.kodus.io/how_to_deploy/en/platforms/bitbucket/bitbucket_webhook) · [Azure DevOps](https://docs.kodus.io/how_to_deploy/en/platforms/azure_devops/azdevops_webhook) · [Forgejo](https://docs.kodus.io/how_to_deploy/en/platforms/forgejo/forgejo_webhook)
- [BYOK / LLM keys](https://docs.kodus.io/how_to_use/en/byok)

---

Deploying to Kubernetes or OpenShift instead? See [charts/README.md](../charts/README.md).
