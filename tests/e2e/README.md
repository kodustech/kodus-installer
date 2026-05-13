# End-to-end test suite

Proves that a fresh self-hosted install actually works: boots the full stack, signs up a user, onboards a real GitHub integration, posts `@kody review` on a fixture PR, and waits for Kody to respond. Two flavours:

| Script | Where it runs | Webhook tunnel | Cost / time |
|---|---|---|---|
| `run-vm.sh` | provisions an **ephemeral DigitalOcean droplet** (Hetzner via env) and runs everything there | free `*.trycloudflare.com` quick tunnel | ~$0.04 / run, ~6 min |
| `run-local.sh` | your **local machine** against the just-pulled images | ngrok | ngrok account, ~3 min |

Both end with a `trap` that tears down everything (droplet, SSH key, GitHub webhook, ngrok tunnel, optional throwaway PR).

## Prerequisites

- Docker + Docker Compose
- `jq`, `curl`, `gh`, `rsync`, `openssl`, `ssh`, `git`, `npx`
- For `run-vm.sh`: `DIGITALOCEAN_TOKEN` (or `HCLOUD_TOKEN` for Hetzner)
- For `run-local.sh`: `ngrok` installed, `NGROK_AUTHTOKEN` configured

## One-time setup

Copy the template and fill in your tokens:

```bash
cp tests/e2e/.env.example tests/e2e/.env
$EDITOR tests/e2e/.env
```

Minimum for `run-vm.sh`:

```bash
TEST_REPO=your-org/kodus-test-sandbox        # any GitHub repo you control
TEST_PR_NUMBER=42                            # long-lived draft PR in TEST_REPO (recommended)
GH_TEST_TOKEN=ghp_xxx                        # PAT: repo + admin:repo_hook on TEST_REPO
DIGITALOCEAN_TOKEN=dop_v1_xxx                # droplet + ssh_key scopes
```

`tests/e2e/.env` is gitignored.

## Run

```bash
# Ephemeral droplet (preferred — same path the CI takes)
./tests/e2e/run-vm.sh

# Local stack (faster iteration, doesn't burn droplets)
./tests/e2e/run-local.sh
```

## What it tests

1. Boot the 7-container stack via the real `./scripts/install.sh`
2. UI smoke — `/`, `/sign-up`, `/sign-in` render (Playwright headless)
3. `GET /api/proxy/api/user/email` — proxy GET path (signup form depends on this)
4. `POST /api/proxy/api/auth/login` — proxy POST path. **Catches `WEB_HOSTNAME_API` / `WEB_PORT_API` misconfig** — the classic failure where direct `:3001` works but real users can't log in.
5. `POST /auth/signUp` + `POST /auth/login` through the proxy
6. Full onboarding via `/code-management/auth-integration` (PAT auth) → repo selection → `finish-onboarding`
7. Register webhook on the fixture repo pointing at the cloudflared tunnel
8. Post `@kody review` and poll for Kody's response (typical: ~15 s)

## Debug flags

```bash
TEST_KEEP_RUNNING=1 ./tests/e2e/run-vm.sh   # skip teardown, keep droplet alive for SSH debug
SKIP_PLAYWRIGHT=1 ./tests/e2e/run-vm.sh     # skip the UI signup attempt (uses API signup only)
TEST_VM_PROVIDER=hetzner ./tests/e2e/run-vm.sh   # use Hetzner CX22 instead of DO
TEST_TIMEOUT_REVIEW=900 ./tests/e2e/run-vm.sh    # wait longer for Kody to respond
```

## CI

Triggered automatically on every successful self-hosted release via `repository_dispatch` from `kodus-ai`'s `selfhosted-build-push.yml`. See `.github/workflows/e2e-self-hosted.yml`. Failures ping the `DISCORD_WEBHOOK_E2E` channel.

Manual run:

```bash
gh workflow run e2e-self-hosted.yml --repo kodustech/kodus-installer
```

## Layout

```
tests/e2e/
├── README.md              ← you are here
├── .env.example           ← template (real .env is gitignored)
├── run-vm.sh              ← ephemeral droplet, used in CI
├── run-local.sh           ← local stack + ngrok
└── playwright/            ← Playwright headless scripts
    ├── signup.mjs         ← debug-only: drive the UI signup form
    ├── ui-smoke.mjs       ← shallow render check
    └── package.json
```
