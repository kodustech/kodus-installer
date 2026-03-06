---
name: kodus-install
description: Install and configure Kodus self-hosted using Docker Compose. Guides through .env setup, secret generation, service startup, and health verification.
user-invocable: true
disable-model-invocation: true
---

You are helping the user install Kodus self-hosted. Follow each phase in order. Be conversational but concise. Always confirm before writing to .env or running scripts.

## Phase 1 — Prerequisites

Run the following checks before anything else:

1. Check Docker is installed: `docker --version`
2. Check Docker daemon is running: `docker info`
3. Check Docker Compose is available: `docker compose version` (fall back to `docker-compose version`)
4. Confirm the current working directory contains `docker-compose.yml` and `scripts/install.sh`. If not, tell the user to `cd` into the kodus-installer directory and stop.

If any prerequisite fails, explain what is missing and stop. Do not proceed until all pass.

---

## Phase 2 — .env Setup

Check if `.env` exists in the current directory.

**If `.env` does not exist:**
- Copy `.env.example` to `.env`: `cp .env.example .env`
- Tell the user you're starting fresh from the example file.

**If `.env` already exists:**
- Ask the user: do they want to (a) keep existing config and go straight to install, or (b) review and update the config?
- If they choose (a), skip to Phase 5.

---

## Phase 3 — Configuration Walkthrough

Read the current `.env` file, then go through each section below. For each variable, check if it already has a non-empty value. If it does, show the current value and ask if they want to keep it or change it. If it is empty, ask for the value.

Use `Edit` to update variables in `.env` as the user provides answers. Never rewrite the whole file — only edit specific lines.

### 3.1 — Basic Settings

| Variable | Description | Default |
|---|---|---|
| `WEB_PORT` | Port for the Kodus web UI | `3000` |
| `API_WEBHOOKS_PORT` | Port for the webhooks service | `3332` |
| `NEXTAUTH_URL` | Full URL where users will access Kodus (e.g. `http://localhost:3000` or `https://kodus.yourdomain.com`) | — |
| `WEB_HOSTNAME_API` | Hostname only (no scheme, no path) where the API is reachable from Git providers for webhooks (e.g. `api.yourdomain.com`). If running locally without public access, use `localhost`. | — |

Tip for the user: `NEXTAUTH_URL` is the browser URL, `WEB_HOSTNAME_API` is what Git providers use to send webhooks.

### 3.2 — Database

Ask: will they use local Docker containers or external databases?

**Local (USE_LOCAL_DB=true):**
- Set `USE_LOCAL_DB=true`
- Ask for: `API_PG_DB_PASSWORD`, `API_MG_DB_PASSWORD`
- The rest can stay as defaults from `.env.example`

**External (USE_LOCAL_DB=false):**
- Set `USE_LOCAL_DB=false`
- Ask for: `API_PG_DB_HOST`, `API_PG_DB_PORT`, `API_PG_DB_USERNAME`, `API_PG_DB_PASSWORD`, `API_PG_DB_DATABASE`
- Ask for: `API_MG_DB_HOST`, `API_MG_DB_PORT`, `API_MG_DB_USERNAME`, `API_MG_DB_PASSWORD`, `API_MG_DB_DATABASE`

### 3.3 — RabbitMQ

Ask: local container or external?

**Local (USE_LOCAL_RABBITMQ=true):**
- Set `USE_LOCAL_RABBITMQ=true`
- Ask for `RABBITMQ_DEFAULT_USER` and `RABBITMQ_DEFAULT_PASS` (or keep defaults `kodus`/`kodus` — warn that defaults are insecure in production)
- Update `API_RABBITMQ_URI` to match: `amqp://{user}:{pass}@rabbitmq:5672/kodus-ai`

**External (USE_LOCAL_RABBITMQ=false):**
- Set `USE_LOCAL_RABBITMQ=false`
- Ask for the full `API_RABBITMQ_URI` (e.g. `amqp://user:pass@host:5672/kodus-ai`)

### 3.4 — LLM API Keys

Ask which LLM provider they want to use. At minimum, `API_OPEN_AI_API_KEY` or `API_LLM_PROVIDER_MODEL` needs to be configured for Kodus to perform reviews.

| Variable | Description |
|---|---|
| `API_OPEN_AI_API_KEY` | OpenAI API key |
| `API_OPENAI_FORCE_BASE_URL` | Optional: custom OpenAI-compatible base URL (e.g. Azure, local LLM) |
| `API_LLM_PROVIDER_MODEL` | Optional: override the model (e.g. `gpt-4o`, `claude-3-5-sonnet`) |

Also ask about optional review enhancers:

| Variable | Description |
|---|---|
| `API_MORPHLLM_API_KEY` | MorphLLM API key — improves code review quality (optional) |
| `SANDBOX_PROVIDER` | Sandbox for cross-file context: `local` (recommended for self-hosted), `e2b` (cloud, needs `API_E2B_KEY`), `none` (disabled), `auto` (default — uses E2B if key set, otherwise disabled) |
| `API_E2B_KEY` | E2B API key — only needed if `SANDBOX_PROVIDER=e2b` (optional) |

### 3.5 — Git Provider Webhooks

At least one Git provider must be configured. Ask which provider(s) they use.

For each selected provider, explain the expected webhook URL format and ask the user to fill it in. The URL must start with `https://` and use `WEB_HOSTNAME_API` as the host.

| Provider | Variable | Expected path |
|---|---|---|
| GitHub | `API_GITHUB_CODE_MANAGEMENT_WEBHOOK` | `/github/webhook` |
| GitLab | `API_GITLAB_CODE_MANAGEMENT_WEBHOOK` | `/gitlab/webhook` |
| Bitbucket | `GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK` | `/bitbucket/webhook` |
| Azure Repos | `GLOBAL_AZURE_REPOS_CODE_MANAGEMENT_WEBHOOK` | `/azdevops/webhook` |
| Forgejo / Gitea | `API_FORGEJO_CODE_MANAGEMENT_WEBHOOK` | `/forgejo/webhook` |

Example: if `WEB_HOSTNAME_API=api.yourdomain.com`, then GitHub webhook = `https://api.yourdomain.com/github/webhook`

### 3.6 — AST Code Review (default: enabled)

`API_ENABLE_CODE_REVIEW_AST` defaults to `true` — this starts the `kodus-service-ast` container which powers deeper code analysis during reviews.

Ask if they want to keep it enabled. If they say no, set `API_ENABLE_CODE_REVIEW_AST=false`.

If enabled, confirm `API_SERVICE_AST_URL=http://kodus-service-ast:3002` is set (this is the internal Docker network address — no changes needed when using local containers).

### 3.7 — MCP (default: disabled)

`API_MCP_SERVER_ENABLED` defaults to `false`. Ask if they want to enable the MCP manager service.

If yes:
- Set `API_MCP_SERVER_ENABLED=true`
- Ask for or confirm: `API_KODUS_SERVICE_MCP_MANAGER` (e.g. `http://kodus-mcp-manager:3101`) and `API_KODUS_MCP_SERVER_URL` (e.g. `http://localhost:3001/mcp`)
- Ask for `API_MCP_MANAGER_COMPOSIO_API_KEY` if they want Composio integration (optional)

---

## Phase 4 — Generate Secrets

Before installing, run the secrets generator to fill in all cryptographic keys automatically:

```bash
bash scripts/generate-secrets.sh
```

This fills: `WEB_NEXTAUTH_SECRET`, `WEB_JWT_SECRET_KEY`, `API_CRYPTO_KEY`, `API_JWT_SECRET`, `API_JWT_REFRESHSECRET`, `CODE_MANAGEMENT_SECRET`, `CODE_MANAGEMENT_WEBHOOK_TOKEN`, `API_MCP_MANAGER_ENCRYPTION_SECRET`, `API_MCP_MANAGER_JWT_SECRET`.

Tell the user these are generated securely and do not need to be set manually.

---

## Phase 5 — Pre-flight Check

Show the user a summary of the key settings before proceeding:

- Web URL: `NEXTAUTH_URL`
- API hostname: `WEB_HOSTNAME_API`
- Database: local or external
- RabbitMQ: local or external
- Git providers configured
- AST enabled/disabled
- MCP enabled/disabled

Ask for confirmation before starting the install.

---

## Phase 6 — Install

Run the install script:

```bash
bash scripts/install.sh
```

Stream the output to the user. If it exits with a non-zero code, show the error and stop. Do not retry automatically — explain what went wrong and suggest fixes based on the error message.

Common errors and fixes:
- Missing required variable → go back to Phase 3 and fill the missing value
- Docker network error → usually harmless if the network already exists
- Port already in use → ask the user to change the port in `.env` or free the port

---

## Phase 7 — Health Check

After a successful install, wait ~15 seconds for services to initialize, then run:

```bash
bash scripts/doctor.sh
```

Show the full output. If there are errors:
- `Schema missing` → seeds/migrations didn't run yet; wait a moment and rerun doctor
- Service not running → `docker compose logs <service>` to investigate
- HTTP check failing → service may still be starting; wait and retry

If all checks pass, tell the user Kodus is ready and print the access URL:
`http://localhost:{WEB_PORT}` (or their configured `NEXTAUTH_URL`).

---

## Important rules

- Never overwrite `.env` wholesale. Always use targeted edits.
- Never run `install.sh` without user confirmation.
- Never generate or expose secrets to the user in plain text in the conversation — they are written directly to `.env`.
- If the user is upgrading from a previous version, mention `MIGRATION.md` before proceeding.
- If anything looks wrong or ambiguous, ask before acting.
