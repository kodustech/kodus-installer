<div align="center">

<img src="https://kodus.io/wp-content/uploads/2025/04/kodusinstaller.png" alt="Kodus Installer Banner">

</div>

# Kodus Installer — self-hosted AI code review

**Kodus is a self-hosted AI code reviewer.** Its agent, **Kody**, reviews every pull
request — flagging bugs, security issues, and quality problems and posting inline
suggestions — so feedback is instant and consistent. Everything runs in **your own
infrastructure**, so your code never leaves your network: a fit for private,
regulated, and air-gapped environments.

This repository is the **installer** — everything needed to deploy the full Kodus
stack (web, API, workers, webhooks, MCP manager, and data stores) via **Docker
Compose** or **Helm** (Kubernetes / OpenShift). The product itself lives at
[kodustech/kodus-ai](https://github.com/kodustech/kodus-ai). Full docs:
[docs.kodus.io](https://docs.kodus.io).

## How it works

1. **Connect a Git repo** (GitHub, GitLab, Bitbucket, Azure Repos) in the Kodus UI.
   Kodus registers a webhook on the provider.
2. **Open or update a pull request.** The provider calls the `webhooks` service,
   which enqueues the job.
3. **A worker runs the review** with your LLM, and Kody posts its feedback back on
   the PR — automatically, or on demand with `@kody start-review`.

```mermaid
flowchart LR
  user((User)) --> web[kodus-web]
  web --> api[api]
  web --> webhooks[webhooks]
  api --> mcp[kodus-mcp-manager]
  api --> rabbitmq[(rabbitmq)]
  worker[worker] --> rabbitmq
  api --> pg[(postgres)]
  api --> mongo[(mongodb)]
  mcp --> pg
  webhooks --> pg
  webhooks --> mongo
```

## Quick start

Pick one path. **Docker Compose** is the fastest way to try Kodus on a single VM;
**Helm** is for Kubernetes / OpenShift.

### Prerequisites

- **Docker Compose path:** Docker, Docker Compose, Git
- **Helm path:** a Kubernetes or OpenShift cluster + Helm 3

### Option A — Docker Compose

```bash
cp .env.example .env
./scripts/generate-secrets.sh   # mint secrets into .env
# edit .env (hosts, webhook URL, LLM key) — see docs/compose.md
./scripts/install.sh
```

Full guide: [docs/compose.md](docs/compose.md) (in-repo) · hosted walkthrough at
[docs.kodus.io](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/generic_vm).

**Guided install with Claude Code** — an interactive install that walks you through
every option, generates secrets, and verifies the deployment at the end:

```bash
npx skills add kodustech/kodus-installer@kodus-install
```

Then, inside [Claude Code](https://claude.ai/claude-code), run `/kodus-install`.

### Option B — Kubernetes / OpenShift (Helm)

Charts live in [`charts/`](charts/README.md).

```bash
cd charts/kodus
helm dependency build
# Kubernetes (bundled data stores — one command, no operators):
helm install kodus . -n kodus --create-namespace \
  --set imageTag=2.1.24   # one tag for the whole stack; + hosts — see charts/README.md
```

Each data store can run `bundled` (this chart brings it up), `external` (your
managed DB), or `operator` (CloudNativePG / RabbitMQ / Mongo operators for HA).
OpenShift uses `-f values-openshift.yaml` (Routes + SCC). Verify any deployment
with `./scripts/doctor-k8s.sh -n kodus`. Full guide:
[charts/README.md](charts/README.md).

## Your first review

Once the stack is up:

1. **Open the web UI** and create an account.
   - Docker Compose: `http://localhost:3000`
   - Kubernetes / OpenShift: your Ingress / Route host.
2. **Add an LLM key.** Kodus is bring-your-own-key: no reviews run without one.
   Either set it in the UI (**Settings → BYOK**) or set `API_OPEN_AI_API_KEY` in
   your config (**Anthropic / Claude keys go in the same slot** — Kodus picks the
   SDK from the model id).
3. **Connect a repository** under **Git Settings**. Kodus registers the webhook for
   you — this needs a **public** webhook URL the provider can reach
   (`API_<provider>_CODE_MANAGEMENT_WEBHOOK`, e.g.
   `https://<your-host>/github/webhook`). On Helm this is auto-derived from your
   webhooks Ingress/Route host; see [charts/README.md](charts/README.md).
4. **Open a pull request.** Kody reviews it automatically, or comment
   `@kody start-review` to trigger a review by hand.

## Documentation

Full product docs live at **[docs.kodus.io](https://docs.kodus.io)** (LLM-friendly
index: [llms.txt](https://docs.kodus.io/llms.txt)). Most useful for self-hosting:

- **Architecture** — [services, networks & data flow](https://docs.kodus.io/how_to_deploy/en/kodus_architecture)
- **Deploy** — [Production / VM](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/generic_vm) · [Local quickstart](https://docs.kodus.io/how_to_deploy/en/local_quickstart/orchestrator) · in this repo: [Docker Compose](docs/compose.md) · [Kubernetes / OpenShift](charts/README.md)
- **Operations** — [Updating](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/updating) · [Reverse proxy](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/reverse_proxy) · [Troubleshooting](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/troubleshooting) · [MCP manager](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/mcp_manager) · [Analytics worker](https://docs.kodus.io/how_to_deploy/en/deploy_kodus/analytics_worker)
- **Git providers** — [GitHub App](https://docs.kodus.io/how_to_deploy/en/platforms/github/github_app) · [GitHub webhook](https://docs.kodus.io/how_to_deploy/en/platforms/github/github_webhook) · [GitLab](https://docs.kodus.io/how_to_deploy/en/platforms/gitlab/gitlab_webhook) · [Bitbucket](https://docs.kodus.io/how_to_deploy/en/platforms/bitbucket/bitbucket_webhook) · [Azure DevOps](https://docs.kodus.io/how_to_deploy/en/platforms/azure_devops/azdevops_webhook) · [Forgejo](https://docs.kodus.io/how_to_deploy/en/platforms/forgejo/forgejo_webhook)
- **LLM keys** — [BYOK (Bring Your Own Key)](https://docs.kodus.io/how_to_use/en/byok)

## External databases or RabbitMQ

Already have PostgreSQL / MongoDB or RabbitMQ? Disable the local containers and
point Kodus at your services. Example `.env`:

```bash
USE_LOCAL_DB=false
USE_LOCAL_RABBITMQ=false

API_PG_DB_HOST=your-postgres-host
API_PG_DB_PORT=5432
API_MG_DB_HOST=your-mongodb-host
API_MG_DB_PORT=27017

API_RABBITMQ_URI=amqp://user:pass@your-rabbitmq-host:5672/kodus-ai
```

When set to `false`, the installer skips starting local services and their health
checks. (On Helm, use `postgres.mode: external` / `mongodb.mode: external` /
`rabbitmq.mode: external` instead — see [charts/README.md](charts/README.md).)

## Troubleshooting

Start with the doctor script to pinpoint common setup issues:

- Docker Compose: `./scripts/doctor.sh`
- Kubernetes / OpenShift: `./scripts/doctor-k8s.sh -n <namespace>`

For `.env` problems specifically, run the schema validator (also invoked by
doctor): `./scripts/validate-env.sh`. It checks each variable against the upstream
schema (`.env.example` types + `scripts/schema-vars.sh` required list), flags type
mismatches and missing required values, and — when containers are running — diffs
your `.env` against what each container actually loaded, so you can spot stale
config that a recreate didn't pick up.

Common fixes:

- **Docker daemon not running:** `docker info`
- **Ports already in use:** `3000`, `3001`, `3101`, `3332`, `5432`, `27017`, `5672`, `15672`, `15692`
- **`.env` missing or invalid:** copy `.env.example` and fill the required vars
- **RabbitMQ connection errors:** ensure `API_RABBITMQ_URI` matches `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, and vhost `kodus-ai`
- **Database errors:** confirm Postgres / Mongo credentials, then rerun `./scripts/setup-db.sh`
- **Service crash or boot loop:** check logs with `docker compose logs -f api` (or `worker`, `webhooks`, `rabbitmq`)
- **Reviews never trigger:** no LLM key set, or the repo webhook can't reach the `webhooks` service — see [Your first review](#your-first-review)

## Services

- **kodus-web** — application frontend
- **api** — application API
- **worker** — background jobs (runs the reviews)
- **webhooks** — receives Git provider events and enqueues review jobs
- **kodus-mcp-manager** — provisions Model Context Protocol (MCP) servers per organization (optional; Compose: `API_MCP_SERVER_ENABLED=true`, Helm: `services.mcp-manager.enabled=true`)
- **rabbitmq** — message broker
- **postgres** — primary database (pgvector)
- **mongodb** — document store

## Security

- Credentials are managed through environment variables / Secrets (never inline in production)
- Inter-service traffic stays on dedicated internal networks; databases are not exposed
- Containers run isolated; on Kubernetes, non-root with dropped capabilities and NetworkPolicy
- For hardened / air-gapped setups, see the security notes in [charts/README.md](charts/README.md)

## Contributing

Contributions are always welcome!

1. Fork the project
2. Create your feature branch (`git checkout -b feat/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feat/amazing-feature`)
5. Open a pull request

## License

Licensed under the MIT License — see [LICENSE](LICENSE).

## Support

Email support@kodus.io or open an issue in this repository.

---

<div align="center">
Made with ❤️ by the Kodus Team
</div>
