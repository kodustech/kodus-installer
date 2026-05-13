#!/usr/bin/env bash
# End-to-end self-hosted smoke test.
#
# Boots the full docker-compose stack with a fresh .env, exposes the webhooks
# port via ngrok, configures a webhook on a real GitHub repo, opens a PR via
# gh, waits for Kodus to post a review comment, then tears everything down.
#
# Required env (or tests/e2e/.env in repo root):
#   TEST_REPO            owner/repo of a GitHub repo to use as the test target
#   GH_TEST_TOKEN    PAT with `repo` + `admin:repo_hook` on TEST_REPO
#   NGROK_AUTHTOKEN      ngrok auth token (or pre-configured ~/.config/ngrok)
#
# Optional env:
#   TEST_USER_EMAIL          default: e2e+$(date +%s)@kodus.test
#   TEST_USER_PASSWORD       default: random 24-char
#   TEST_TIMEOUT_REVIEW      default: 600 (seconds to wait for review comment)
#   TEST_KEEP_RUNNING        if "1", skip teardown (debug)
#   SKIP_PLAYWRIGHT          if "1", skip signup (assumes user already exists)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[e2e]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}  $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[err]${NC} $*" >&2; }

# Optional secrets file (gitignored)
if [ -f "$REPO_ROOT/tests/e2e/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$REPO_ROOT/tests/e2e/.env"; set +a
fi

# State (used by cleanup)
NGROK_PID=""
NGROK_PUBLIC_URL=""
GITHUB_HOOK_ID=""
ENV_BACKUP=""
PR_NUMBER=""
PR_BRANCH=""
TEST_REPO_CLONE=""
DOCKER_COMPOSE=""
REUSE_PR=0
SINCE_ISO=""
TRIGGER_COMMENT_ID=""

# ---------- cleanup ----------
cleanup() {
    local exit_code=$?
    set +e
    if [ "${TEST_KEEP_RUNNING:-0}" = "1" ]; then
        warn "TEST_KEEP_RUNNING=1 set, skipping teardown."
        warn "  ngrok URL:    ${NGROK_PUBLIC_URL:-?}"
        warn "  GitHub hook:  ${GITHUB_HOOK_ID:-?}"
        warn "  PR:           ${PR_NUMBER:-?} (branch ${PR_BRANCH:-?})"
        warn "  env backup:   ${ENV_BACKUP:-?}"
        exit "$exit_code"
    fi

    log "Teardown..."

    if [ -n "$PR_NUMBER" ] && [ -n "${TEST_REPO:-}" ] && [ "$REUSE_PR" != "1" ]; then
        gh pr close --repo "$TEST_REPO" --delete-branch "$PR_NUMBER" >/dev/null 2>&1 \
            && ok "Closed PR #$PR_NUMBER" \
            || warn "Could not close PR #$PR_NUMBER"
    elif [ "$REUSE_PR" = "1" ]; then
        ok "Leaving PR #$PR_NUMBER open (reuse mode)"
    fi

    if [ -n "$GITHUB_HOOK_ID" ] && [ -n "${TEST_REPO:-}" ]; then
        curl -sS -X DELETE \
            -H "Authorization: Bearer ${GH_TEST_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${TEST_REPO}/hooks/${GITHUB_HOOK_ID}" >/dev/null \
            && ok "Removed GitHub webhook $GITHUB_HOOK_ID" \
            || warn "Could not remove GitHub webhook $GITHUB_HOOK_ID"
    fi

    if [ -n "$NGROK_PID" ] && kill -0 "$NGROK_PID" 2>/dev/null; then
        kill "$NGROK_PID" 2>/dev/null || true
        ok "Killed ngrok (pid $NGROK_PID)"
    fi

    if [ -n "$DOCKER_COMPOSE" ]; then
        $DOCKER_COMPOSE down -v --remove-orphans >/dev/null 2>&1 \
            && ok "docker compose down -v" \
            || warn "docker compose down failed"
    fi

    if [ -n "$TEST_REPO_CLONE" ] && [ -d "$TEST_REPO_CLONE" ]; then
        rm -rf "$TEST_REPO_CLONE" && ok "Removed clone $TEST_REPO_CLONE"
    fi

    if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
        mv "$ENV_BACKUP" "$REPO_ROOT/.env" && ok "Restored original .env"
    elif [ -z "$ENV_BACKUP" ] && [ -f "$REPO_ROOT/.env" ]; then
        # Original .env did not exist; remove the test one we wrote.
        rm -f "$REPO_ROOT/.env" && ok "Removed test .env"
    fi

    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ---------- helpers ----------
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Missing dependency: $1"
        exit 1
    fi
}

require_env() {
    if [ -z "${!1:-}" ]; then
        err "Required env var $1 is not set (put it in tests/e2e/.env or export it)."
        exit 1
    fi
}

env_set() {
    # Set KEY=VALUE in .env, replacing any existing line.
    local key=$1 value=$2 file="$REPO_ROOT/.env"
    if grep -qE "^${key}=" "$file"; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$file"
        else
            sed -i "s|^${key}=.*|${key}=${value}|" "$file"
        fi
    else
        echo "${key}=${value}" >> "$file"
    fi
}

http_ok() {
    local url=$1
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" || echo "000")
    # Any 2xx/3xx/4xx = server up. 5xx/000 = not ready.
    [[ "$code" =~ ^[234][0-9][0-9]$ ]]
}

wait_for_http() {
    local label=$1 url=$2 timeout=${3:-180}
    local start=$(date +%s)
    log "Waiting for $label at $url (timeout ${timeout}s)..."
    while true; do
        if http_ok "$url"; then ok "$label responding"; return 0; fi
        if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
            err "$label did not respond in ${timeout}s"
            return 1
        fi
        sleep 3
    done
}

# ---------- preflight ----------
log "Preflight..."
require_cmd docker
require_cmd curl
require_cmd jq
require_cmd ngrok
require_cmd gh
require_cmd npx
require_cmd git

if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker-compose"
else
    err "Docker Compose not found"; exit 1
fi
ok "Using: $DOCKER_COMPOSE"

require_env TEST_REPO
require_env GH_TEST_TOKEN
# NGROK_AUTHTOKEN only required if not already configured globally
if ! ngrok config check >/dev/null 2>&1; then
    require_env NGROK_AUTHTOKEN
    ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null
fi

# No '+' alias — some signup validators reject plus-addressing.
TEST_USER_EMAIL="${TEST_USER_EMAIL:-kodus-qa-$(date +%s)@kodusqa.io}"
TEST_USER_PASSWORD="${TEST_USER_PASSWORD:-$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)Aa1!}"
TEST_TIMEOUT_REVIEW="${TEST_TIMEOUT_REVIEW:-600}"

ok "Test user:  $TEST_USER_EMAIL"
ok "Test repo:  $TEST_REPO"

# ---------- .env ----------
log "Preparing .env (test profile)..."
if [ -f "$REPO_ROOT/.env" ]; then
    ENV_BACKUP="$REPO_ROOT/.env.e2e-backup.$(date +%s)"
    cp "$REPO_ROOT/.env" "$ENV_BACKUP"
    ok "Backed up existing .env to $ENV_BACKUP"
fi
cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
"$REPO_ROOT/scripts/generate-secrets.sh"

# ---------- ngrok ----------
log "Starting ngrok tunnel on :3332..."
ngrok http 3332 --log=stdout >/tmp/kodus-e2e-ngrok.log 2>&1 &
NGROK_PID=$!
# Wait for the local API to expose the public URL
for i in $(seq 1 30); do
    NGROK_PUBLIC_URL=$(curl -sS http://127.0.0.1:4040/api/tunnels 2>/dev/null \
        | jq -r '.tunnels[] | select(.proto=="https") | .public_url' | head -n1)
    [ -n "$NGROK_PUBLIC_URL" ] && [ "$NGROK_PUBLIC_URL" != "null" ] && break
    sleep 1
done
if [ -z "$NGROK_PUBLIC_URL" ] || [ "$NGROK_PUBLIC_URL" = "null" ]; then
    err "ngrok did not return a public URL. Log: /tmp/kodus-e2e-ngrok.log"
    exit 1
fi
NGROK_HOST="${NGROK_PUBLIC_URL#https://}"
ok "ngrok: $NGROK_PUBLIC_URL"

# ---------- env overrides ----------
log "Applying test overrides to .env..."
# WEB_HOSTNAME_API is the Docker-internal hostname for kodus-web's
# server-side proxy to reach the api container — NOT the public webhook
# host. The public host is in API_GITHUB_CODE_MANAGEMENT_WEBHOOK.
env_set WEB_HOSTNAME_API     "kodus-api"
env_set WEB_PORT_API         "3001"
env_set NEXTAUTH_URL         "http://localhost:3000"
env_set API_GITHUB_CODE_MANAGEMENT_WEBHOOK "${NGROK_PUBLIC_URL}/github/webhook"
# DB passwords are @required but not in autogen list — mint random hex.
env_set API_PG_DB_PASSWORD   "$(openssl rand -hex 16)"
env_set API_MG_DB_PASSWORD   "$(openssl rand -hex 16)"
# Local Postgres has no SSL. API_DATABASE_DISABLE_SSL=true covers all the
# api's data sources (default + analytics). API_PG_DB_SSL kept for older builds.
env_set API_DATABASE_DISABLE_SSL "true"
env_set API_PG_DB_SSL        "false"
# Worker requires role; without it the queues are never created.
env_set WORKER_ROLE          "code-review"

# ---------- boot ----------
log "Booting stack (this can take a few minutes)..."
"$REPO_ROOT/scripts/install.sh"

wait_for_http "kodus-web" "http://localhost:${WEB_PORT:-3000}"        180
wait_for_http "api"       "http://localhost:3001"                     180
wait_for_http "webhooks"  "http://localhost:${API_WEBHOOKS_PORT:-3332}" 180

# ---------- GitHub webhook ----------
log "Creating webhook on $TEST_REPO -> $NGROK_PUBLIC_URL/github/webhook"
HOOK_RESP=$(curl -sS -X POST \
    -H "Authorization: Bearer ${GH_TEST_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${TEST_REPO}/hooks" \
    -d "$(jq -nc \
        --arg url "${NGROK_PUBLIC_URL}/github/webhook" \
        '{name:"web", active:true, events:["pull_request","push","issues","issue_comment","pull_request_review","pull_request_review_comment"], config:{url:$url, content_type:"json", insecure_ssl:"0"}}')")
GITHUB_HOOK_ID=$(echo "$HOOK_RESP" | jq -r '.id // empty')
if [ -z "$GITHUB_HOOK_ID" ]; then
    err "Failed to create webhook. Response: $HOOK_RESP"; exit 1
fi
ok "Webhook id: $GITHUB_HOOK_ID"

# ---------- signup (Playwright) ----------
if [ "${SKIP_PLAYWRIGHT:-0}" != "1" ]; then
    log "Running signup via Playwright..."
    pushd "$REPO_ROOT/tests/e2e/playwright" >/dev/null
    if [ ! -d node_modules ]; then
        log "Installing Playwright (first run only)..."
        npm install --silent
        npx playwright install chromium --with-deps >/dev/null 2>&1 || npx playwright install chromium
    fi
    KODUS_WEB_URL="http://localhost:${WEB_PORT:-3000}" \
    TEST_USER_EMAIL="$TEST_USER_EMAIL" \
    TEST_USER_PASSWORD="$TEST_USER_PASSWORD" \
    TEST_REPO="$TEST_REPO" \
    GH_TEST_TOKEN="$GH_TEST_TOKEN" \
    node signup.mjs
    popd >/dev/null
    ok "Signup complete"
else
    warn "SKIP_PLAYWRIGHT=1, assuming user already exists"
fi

# ---------- trigger review ----------
# Reuse mode: post `@kody review` on the existing PR (no clone, no push).
# Create mode: clone repo, open a brand-new PR (kody auto-reviews on open).
RUN_ID="$(date +%Y%m%d-%H%M%S)-$RANDOM"

if [ -n "${TEST_PR_NUMBER:-}" ]; then
    REUSE_PR=1
    PR_NUMBER="$TEST_PR_NUMBER"
    log "Triggering review on PR #$PR_NUMBER via @kody review comment..."
    TRIGGER_RESP=$(GH_TOKEN="$GH_TEST_TOKEN" gh api \
        --method POST \
        "repos/${TEST_REPO}/issues/${PR_NUMBER}/comments" \
        -f body="@kody review")
    TRIGGER_COMMENT_ID=$(echo "$TRIGGER_RESP" | jq -r '.id // empty')
    SINCE_ISO=$(echo "$TRIGGER_RESP" | jq -r '.created_at // empty')
    [ -n "$TRIGGER_COMMENT_ID" ] && [ -n "$SINCE_ISO" ] \
        || { err "Failed to post trigger comment: $TRIGGER_RESP"; exit 1; }
    ok "Posted @kody review (comment $TRIGGER_COMMENT_ID at $SINCE_ISO)"
else
    SINCE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    TEST_REPO_CLONE="$(mktemp -d -t kodus-e2e-XXXXXX)/repo"
    log "Cloning test repo and opening a new PR..."
    GH_TOKEN="$GH_TEST_TOKEN" gh repo clone "$TEST_REPO" "$TEST_REPO_CLONE" -- --depth=1
    cd "$TEST_REPO_CLONE"
    DEFAULT_BRANCH=$(git symbolic-ref --short HEAD)
    PR_BRANCH="kodus-e2e/$RUN_ID"
    git checkout -b "$PR_BRANCH"
    cat > kodus-e2e-touch.md <<EOF
# Kodus E2E touch file

This file was generated by tests/e2e/run-local.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ").
It exists to trigger a Kodus self-hosted review.
EOF
    git -c user.email=e2e@kodus.test -c user.name="Kodus E2E" \
        add kodus-e2e-touch.md
    git -c user.email=e2e@kodus.test -c user.name="Kodus E2E" \
        commit -m "chore: kodus e2e smoke commit" >/dev/null

    GH_TOKEN="$GH_TEST_TOKEN" git push -u origin "$PR_BRANCH" >/dev/null 2>&1

    PR_URL=$(GH_TOKEN="$GH_TEST_TOKEN" gh pr create \
        --repo "$TEST_REPO" \
        --base "$DEFAULT_BRANCH" \
        --head "$PR_BRANCH" \
        --title "Kodus E2E: smoke test $RUN_ID" \
        --body "Automated PR opened by tests/e2e/run-local.sh — safe to close.")
    PR_NUMBER=$(echo "$PR_URL" | sed -E 's|.*/pull/([0-9]+).*|\1|')
    ok "Opened PR #$PR_NUMBER: $PR_URL"
    cd "$REPO_ROOT"
fi

# ---------- wait for Kodus review ----------
log "Waiting up to ${TEST_TIMEOUT_REVIEW}s for a Kodus review on PR #$PR_NUMBER (since $SINCE_ISO)..."
START=$(date +%s)
FOUND=""
# In self-hosted with a PAT, Kody posts as the PAT owner — same identity as
# the PR author. So we can't filter by `user.login != author`. Filter only
# the explicit trigger comment + any other "@kody …" command comments.
while true; do
    REVIEW_COMMENTS=$(GH_TOKEN="$GH_TEST_TOKEN" gh api \
        "repos/${TEST_REPO}/pulls/${PR_NUMBER}/comments?since=${SINCE_ISO}" 2>/dev/null \
        | jq --argjson trigger "${TRIGGER_COMMENT_ID:-0}" \
            '[.[] | select(.id != $trigger) | select((.body // "") | ascii_downcase | startswith("@kody") | not)] | length')
    ISSUE_COMMENTS=$(GH_TOKEN="$GH_TEST_TOKEN" gh api \
        "repos/${TEST_REPO}/issues/${PR_NUMBER}/comments?since=${SINCE_ISO}" 2>/dev/null \
        | jq --argjson trigger "${TRIGGER_COMMENT_ID:-0}" \
            '[.[] | select(.id != $trigger) | select((.body // "") | ascii_downcase | startswith("@kody") | not)] | length')
    REVIEWS=$(GH_TOKEN="$GH_TEST_TOKEN" gh api \
        "repos/${TEST_REPO}/pulls/${PR_NUMBER}/reviews" 2>/dev/null \
        | jq --arg since "$SINCE_ISO" \
            '[.[] | select((.submitted_at // .created_at // "") > $since) | select((.body // "") | ascii_downcase | startswith("@kody") | not)] | length')

    if [ "${REVIEW_COMMENTS:-0}" -gt 0 ] || [ "${ISSUE_COMMENTS:-0}" -gt 0 ] || [ "${REVIEWS:-0}" -gt 0 ]; then
        FOUND="review_comments=$REVIEW_COMMENTS issue_comments=$ISSUE_COMMENTS reviews=$REVIEWS"
        break
    fi

    if [ $(( $(date +%s) - START )) -ge "$TEST_TIMEOUT_REVIEW" ]; then
        err "Timed out waiting for Kodus review on PR #$PR_NUMBER"
        err "  ngrok log:    /tmp/kodus-e2e-ngrok.log"
        err "  api logs:     $DOCKER_COMPOSE logs api"
        err "  webhook logs: $DOCKER_COMPOSE logs webhooks"
        err "  worker logs:  $DOCKER_COMPOSE logs worker"
        exit 1
    fi
    sleep 10
done

ok "Kodus review detected: $FOUND"
ok "End-to-end test PASSED"
