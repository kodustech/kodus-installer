#!/usr/bin/env bash
# End-to-end self-hosted smoke test on an ephemeral cloud VM.
#
# Default provider: DigitalOcean. Set TEST_VM_PROVIDER=hetzner for Hetzner.
#
# Provisions a small VM, installs Docker + cloudflared via cloud-init,
# transfers the repo, exposes :3332 through a `trycloudflare.com` quick tunnel
# (free HTTPS, no domain needed), runs install.sh on the VM, then runs the
# same signup-via-Playwright + open-PR + poll-for-review flow as test-e2e.sh,
# but against the VM's public IP. Destroys the server at the end.
#
# Required env (or .env.test-e2e):
#   TEST_REPO            owner/repo on GitHub
#   GITHUB_TEST_TOKEN    PAT with `repo` + `admin:repo_hook`
#
#   # DigitalOcean (default):
#   DIGITALOCEAN_TOKEN   DO API token (read+write)
#   # OR Hetzner:
#   TEST_VM_PROVIDER=hetzner
#   HCLOUD_TOKEN         Hetzner Cloud API token
#
# Optional env (DO):
#   DO_REGION   default: nyc3 (also: sfo3, ams3, fra1, sgp1, lon1, tor1, blr1)
#   DO_SIZE     default: s-2vcpu-4gb
#   DO_IMAGE    default: ubuntu-24-04-x64
#
# Optional env (Hetzner):
#   HCLOUD_LOCATION      default: nbg1
#   HCLOUD_SERVER_TYPE   default: cx22
#   HCLOUD_IMAGE         default: ubuntu-24.04
#
# Other:
#   TEST_USER_EMAIL      default: e2e+TS@kodus.test
#   TEST_USER_PASSWORD   default: random
#   TEST_TIMEOUT_REVIEW  default: 600
#   TEST_KEEP_RUNNING    if "1", skip teardown (debug)
#   SKIP_PLAYWRIGHT      if "1", skip signup

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[vm-e2e]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}    $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()  { echo -e "${RED}[err]${NC}   $*" >&2; }

if [ -f "$REPO_ROOT/.env.test-e2e" ]; then
    # shellcheck disable=SC1091
    set -a; . "$REPO_ROOT/.env.test-e2e"; set +a
fi

TEST_VM_PROVIDER="${TEST_VM_PROVIDER:-digitalocean}"
case "$TEST_VM_PROVIDER" in
    do|digitalocean) TEST_VM_PROVIDER=digitalocean ;;
    hetzner|hcloud)  TEST_VM_PROVIDER=hetzner ;;
    *) err "Unknown TEST_VM_PROVIDER=$TEST_VM_PROVIDER (use digitalocean|hetzner)"; exit 1 ;;
esac

# State for cleanup
SERVER_ID=""
SSH_KEY_ID=""
LOCAL_SSH_KEY=""
SERVER_IP=""
SERVER_TUNNEL_URL=""
GITHUB_HOOK_ID=""
PR_NUMBER=""
PR_BRANCH=""
TEST_REPO_CLONE=""
REUSE_PR=0
SINCE_ISO=""
TRIGGER_COMMENT_ID=""

# ---------- provider abstractions ----------

DO_API="https://api.digitalocean.com/v2"
DO_REGION="${DO_REGION:-nyc3}"
DO_SIZE="${DO_SIZE:-s-2vcpu-4gb}"
DO_IMAGE="${DO_IMAGE:-ubuntu-24-04-x64}"

HCLOUD_API="https://api.hetzner.cloud/v1"
HCLOUD_LOCATION="${HCLOUD_LOCATION:-nbg1}"
HCLOUD_SERVER_TYPE="${HCLOUD_SERVER_TYPE:-cx22}"
HCLOUD_IMAGE="${HCLOUD_IMAGE:-ubuntu-24.04}"

provision_ssh_key() {
    local name=$1 pubkey=$2
    case "$TEST_VM_PROVIDER" in
        digitalocean)
            local resp
            resp=$(curl -sS -X POST \
                -H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}" \
                -H "Content-Type: application/json" \
                "$DO_API/account/keys" \
                -d "$(jq -nc --arg n "$name" --arg k "$pubkey" '{name:$n, public_key:$k}')")
            SSH_KEY_ID=$(echo "$resp" | jq -r '.ssh_key.id // empty')
            [ -n "$SSH_KEY_ID" ] || { err "DO key upload failed: $resp"; exit 1; }
            ;;
        hetzner)
            local resp
            resp=$(curl -sS -X POST \
                -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
                -H "Content-Type: application/json" \
                "$HCLOUD_API/ssh_keys" \
                -d "$(jq -nc --arg n "$name" --arg k "$pubkey" '{name:$n, public_key:$k}')")
            SSH_KEY_ID=$(echo "$resp" | jq -r '.ssh_key.id // empty')
            [ -n "$SSH_KEY_ID" ] || { err "Hetzner key upload failed: $resp"; exit 1; }
            ;;
    esac
}

provision_server() {
    local name=$1 user_data=$2
    case "$TEST_VM_PROVIDER" in
        digitalocean)
            local resp
            resp=$(curl -sS -X POST \
                -H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}" \
                -H "Content-Type: application/json" \
                "$DO_API/droplets" \
                -d "$(jq -nc \
                    --arg name "$name" --arg region "$DO_REGION" \
                    --arg size "$DO_SIZE" --arg image "$DO_IMAGE" \
                    --argjson key "$SSH_KEY_ID" --arg ud "$user_data" \
                    '{name:$name, region:$region, size:$size, image:$image,
                      ssh_keys:[$key], user_data:$ud, ipv6:false,
                      monitoring:false, backups:false}')")
            SERVER_ID=$(echo "$resp" | jq -r '.droplet.id // empty')
            [ -n "$SERVER_ID" ] || { err "DO droplet create failed: $resp"; exit 1; }
            log "Droplet $SERVER_ID created, waiting for active status + public IP..."
            for i in $(seq 1 60); do
                local s
                s=$(curl -sS -H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}" \
                    "$DO_API/droplets/$SERVER_ID")
                SERVER_IP=$(echo "$s" | jq -r '.droplet.networks.v4[]? | select(.type=="public") | .ip_address' | head -n1)
                local status
                status=$(echo "$s" | jq -r '.droplet.status // empty')
                if [ "$status" = "active" ] && [ -n "$SERVER_IP" ]; then return 0; fi
                sleep 5
            done
            err "Droplet $SERVER_ID never became active"; exit 1
            ;;
        hetzner)
            local resp
            resp=$(curl -sS -X POST \
                -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
                -H "Content-Type: application/json" \
                "$HCLOUD_API/servers" \
                -d "$(jq -nc \
                    --arg name "$name" --arg type "$HCLOUD_SERVER_TYPE" \
                    --arg image "$HCLOUD_IMAGE" --arg location "$HCLOUD_LOCATION" \
                    --argjson key "$SSH_KEY_ID" --arg ud "$user_data" \
                    '{name:$name, server_type:$type, image:$image, location:$location,
                      ssh_keys:[$key], user_data:$ud, start_after_create:true,
                      public_net:{enable_ipv4:true, enable_ipv6:false}}')")
            SERVER_ID=$(echo "$resp" | jq -r '.server.id // empty')
            SERVER_IP=$(echo "$resp" | jq -r '.server.public_net.ipv4.ip // empty')
            [ -n "$SERVER_ID" ] && [ -n "$SERVER_IP" ] \
                || { err "Hetzner server create failed: $resp"; exit 1; }
            ;;
    esac
}

destroy_server() {
    [ -n "$SERVER_ID" ] || return 0
    case "$TEST_VM_PROVIDER" in
        digitalocean)
            curl -sS -X DELETE \
                -H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}" \
                "$DO_API/droplets/$SERVER_ID" >/dev/null \
                && ok "Destroyed DO droplet $SERVER_ID" \
                || warn "Could not destroy droplet $SERVER_ID — check at cloud.digitalocean.com/droplets!"
            ;;
        hetzner)
            curl -sS -X DELETE \
                -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
                "$HCLOUD_API/servers/$SERVER_ID" >/dev/null \
                && ok "Destroyed Hetzner server $SERVER_ID" \
                || warn "Could not destroy server $SERVER_ID — check at hetzner.cloud/servers!"
            ;;
    esac
}

destroy_ssh_key() {
    [ -n "$SSH_KEY_ID" ] || return 0
    case "$TEST_VM_PROVIDER" in
        digitalocean)
            curl -sS -X DELETE \
                -H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}" \
                "$DO_API/account/keys/$SSH_KEY_ID" >/dev/null \
                && ok "Removed DO SSH key $SSH_KEY_ID" \
                || warn "Could not remove DO SSH key — clean up at cloud.digitalocean.com/account/security"
            ;;
        hetzner)
            curl -sS -X DELETE \
                -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
                "$HCLOUD_API/ssh_keys/$SSH_KEY_ID" >/dev/null \
                && ok "Removed Hetzner SSH key $SSH_KEY_ID" \
                || warn "Could not remove SSH key — clean up at hetzner.cloud/ssh-keys"
            ;;
    esac
}

# ---------- cleanup ----------
cleanup() {
    local exit_code=$?
    set +e
    if [ "${TEST_KEEP_RUNNING:-0}" = "1" ]; then
        warn "TEST_KEEP_RUNNING=1, skipping teardown."
        warn "  Provider: $TEST_VM_PROVIDER"
        warn "  Server:   ${SERVER_ID:-?} (${SERVER_IP:-?})"
        warn "  SSH key:  $LOCAL_SSH_KEY"
        warn "  Tunnel:   ${SERVER_TUNNEL_URL:-?}"
        warn "  Hook:     ${GITHUB_HOOK_ID:-?}"
        warn "  PR:       ${PR_NUMBER:-?}"
        warn "  Connect:  ssh -i $LOCAL_SSH_KEY root@${SERVER_IP}"
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
            -H "Authorization: Bearer ${GITHUB_TEST_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${TEST_REPO}/hooks/${GITHUB_HOOK_ID}" >/dev/null \
            && ok "Removed GitHub webhook $GITHUB_HOOK_ID" \
            || warn "Could not remove GitHub webhook"
    fi
    destroy_server
    destroy_ssh_key
    if [ -n "$LOCAL_SSH_KEY" ] && [ -f "$LOCAL_SSH_KEY" ]; then
        rm -f "$LOCAL_SSH_KEY" "${LOCAL_SSH_KEY}.pub"
        ok "Removed local SSH key"
    fi
    if [ -n "$TEST_REPO_CLONE" ] && [ -d "$TEST_REPO_CLONE" ]; then
        rm -rf "$TEST_REPO_CLONE"
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ---------- helpers ----------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }
}
require_env() {
    [ -n "${!1:-}" ] || { err "Required env $1 is not set"; exit 1; }
}

ssh_vm() {
    ssh -i "$LOCAL_SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=10 \
        "root@$SERVER_IP" "$@"
}

# ---------- preflight ----------
log "Preflight (provider: $TEST_VM_PROVIDER)..."
require_cmd curl
require_cmd jq
require_cmd ssh
require_cmd rsync
require_cmd gh
require_cmd npx
require_cmd git
require_cmd openssl

require_env TEST_REPO
require_env GITHUB_TEST_TOKEN
case "$TEST_VM_PROVIDER" in
    digitalocean) require_env DIGITALOCEAN_TOKEN ;;
    hetzner)      require_env HCLOUD_TOKEN ;;
esac

# No '+' alias — some signup validators reject plus-addressing even though
# it's RFC-valid. Use a plain unique local-part instead.
TEST_USER_EMAIL="${TEST_USER_EMAIL:-kodus-qa-$(date +%s)@kodusqa.io}"
TEST_USER_PASSWORD="${TEST_USER_PASSWORD:-$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)Aa1!}"
TEST_TIMEOUT_REVIEW="${TEST_TIMEOUT_REVIEW:-600}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$RANDOM"

ok "Run ID:    $RUN_ID"
ok "Test repo: $TEST_REPO"
ok "Test user: $TEST_USER_EMAIL"

# ---------- ssh key ----------
log "Generating temporary SSH key..."
LOCAL_SSH_KEY="$(mktemp -t kodus-e2e-key-XXXXXX)"
rm -f "$LOCAL_SSH_KEY"
ssh-keygen -t ed25519 -N "" -C "kodus-e2e-$RUN_ID" -f "$LOCAL_SSH_KEY" >/dev/null
PUBKEY="$(cat "${LOCAL_SSH_KEY}.pub")"

log "Uploading SSH key to $TEST_VM_PROVIDER..."
provision_ssh_key "kodus-e2e-$RUN_ID" "$PUBKEY"
ok "SSH key id: $SSH_KEY_ID"

# ---------- provision ----------
log "Creating server..."
USER_DATA=$(cat <<'CLOUDINIT'
#cloud-config
package_update: true
packages:
  - git
  - jq
  - openssl
  - curl
  - rsync
runcmd:
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable --now docker
  - curl -fsSL -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  - chmod +x /usr/local/bin/cloudflared
  - touch /var/lib/cloud/instance/kodus-ready
CLOUDINIT
)

provision_server "kodus-e2e-$RUN_ID" "$USER_DATA"
ok "Server $SERVER_ID at $SERVER_IP"

# ---------- wait for SSH + cloud-init ----------
log "Waiting for SSH..."
for i in $(seq 1 60); do
    if ssh_vm "true" >/dev/null 2>&1; then ok "SSH up"; break; fi
    sleep 5
    if [ "$i" = 60 ]; then err "SSH never came up"; exit 1; fi
done

log "Waiting for cloud-init to finish (installs Docker — ~2min)..."
ssh_vm "cloud-init status --wait" >/dev/null
ssh_vm "test -f /var/lib/cloud/instance/kodus-ready" || { err "cloud-init runcmd failed"; exit 1; }
ok "VM provisioned"

# ---------- transfer repo ----------
log "Transferring repo to VM..."
ssh_vm "mkdir -p /opt/kodus-installer"
rsync -az --delete \
    -e "ssh -i $LOCAL_SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    --exclude='.git/' \
    --exclude='node_modules/' \
    --exclude='.env' \
    --exclude='.env.test-e2e' \
    --exclude='.env.e2e-backup.*' \
    "$REPO_ROOT/" "root@$SERVER_IP:/opt/kodus-installer/"
ssh_vm "chmod +x /opt/kodus-installer/scripts/*.sh"
ok "Repo transferred"

# ---------- start cloudflared tunnel ----------
log "Starting cloudflared quick tunnel for :3332..."
ssh_vm "cat >/etc/systemd/system/kodus-tunnel.service <<'UNIT'
[Unit]
Description=cloudflared quick tunnel for Kodus webhooks
After=network-online.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --url http://localhost:3332 --no-autoupdate --logfile /var/log/cloudflared.log
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now kodus-tunnel.service"

log "Waiting for tunnel URL to appear in log..."
for i in $(seq 1 30); do
    URL=$(ssh_vm "grep -oE 'https://[a-zA-Z0-9-]+\\.trycloudflare\\.com' /var/log/cloudflared.log 2>/dev/null | head -n1" || true)
    if [ -n "$URL" ]; then SERVER_TUNNEL_URL="$URL"; break; fi
    sleep 3
done
[ -n "$SERVER_TUNNEL_URL" ] || { err "cloudflared tunnel URL never appeared"; ssh_vm "tail -50 /var/log/cloudflared.log" || true; exit 1; }
TUNNEL_HOST="${SERVER_TUNNEL_URL#https://}"
ok "Tunnel: $SERVER_TUNNEL_URL"

# ---------- .env on VM ----------
log "Generating .env on VM..."
ssh_vm "cd /opt/kodus-installer && cp .env.example .env && ./scripts/generate-secrets.sh" >/dev/null

ssh_vm bash -s <<REMOTE
set -e
cd /opt/kodus-installer
env_set() {
    local k=\$1 v=\$2
    if grep -qE "^\${k}=" .env; then
        sed -i "s|^\${k}=.*|\${k}=\${v}|" .env
    else
        echo "\${k}=\${v}" >> .env
    fi
}
# WEB_HOSTNAME_API has dual use in kodus-web:
#   1) server-side proxy (Next.js /api/proxy/api/* route) uses it to reach
#      the api container on the internal Docker network — needs the
#      container name "kodus-api", not a public hostname.
#   2) the installer's webhook validator just checks format, not that it
#      matches the actual webhook host — so internal name is fine.
# The public webhook URL is set explicitly in API_GITHUB_CODE_MANAGEMENT_WEBHOOK.
env_set WEB_HOSTNAME_API "kodus-api"
env_set WEB_PORT_API "3001"
env_set NEXTAUTH_URL "http://$SERVER_IP:3000"
env_set API_GITHUB_CODE_MANAGEMENT_WEBHOOK "$SERVER_TUNNEL_URL/github/webhook"
# DB passwords are @required but not in autogen list (install.sh leaves them
# to the operator). For an ephemeral test stack, mint random hex passwords —
# hex avoids any URI-encoding pain in connection strings.
env_set API_PG_DB_PASSWORD "\$(openssl rand -hex 16)"
env_set API_MG_DB_PASSWORD "\$(openssl rand -hex 16)"
# Local Postgres container ships without SSL. API has multiple TypeORM data
# sources (default + analytics) — API_DATABASE_DISABLE_SSL is the global
# switch that covers all of them. API_PG_DB_SSL is kept too for older builds.
env_set API_DATABASE_DISABLE_SSL "true"
env_set API_PG_DB_SSL "false"
# Worker requires a role: "code-review" or "analytics". Without it the
# worker crashes on boot, so the queues it owns never get created — and
# api/webhooks then fail their QueueBind. Not in .env.example yet.
env_set WORKER_ROLE "code-review"
REMOTE
ok ".env ready on VM"

# ---------- boot ----------
log "Booting stack on VM (./scripts/install.sh)..."
ssh_vm "cd /opt/kodus-installer && ./scripts/install.sh"

log "Waiting for web/api/webhooks to respond (timeout 5min each)..."
svc_compose_name() {
    case "$1" in
        web) echo "kodus-web" ;;
        api) echo "api" ;;
        webhooks) echo "webhooks" ;;
    esac
}
HEALTH_FAILED=()
for label_port in "web:3000" "api:3001" "webhooks:3332"; do
    label="${label_port%:*}"; port="${label_port#*:}"
    SUCCESS=0
    for i in $(seq 1 100); do  # 100 * 3s = 5min
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://$SERVER_IP:$port" || echo 000)
        # Any 2xx/3xx/4xx = the server is up and speaking HTTP. 5xx + 000 = not ready.
        if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
            ok "$label responding ($code) on http://$SERVER_IP:$port"
            SUCCESS=1
            break
        fi
        sleep 3
    done
    if [ "$SUCCESS" = "0" ]; then
        warn "$label never responded externally on http://$SERVER_IP:$port"
        HEALTH_FAILED+=("$label_port")
    fi
done

if [ ${#HEALTH_FAILED[@]} -gt 0 ]; then
    err "Healthcheck failed for: ${HEALTH_FAILED[*]}"
    log "----- docker compose ps on VM -----"
    ssh_vm "cd /opt/kodus-installer && docker compose ps" || true
    for label_port in "${HEALTH_FAILED[@]}"; do
        label="${label_port%:*}"; port="${label_port#*:}"
        svc=$(svc_compose_name "$label")
        log "----- internal curl on VM: http://localhost:$port -----"
        ssh_vm "curl -sS -o /dev/null -w 'HTTP %{http_code} time=%{time_total}s\n' --max-time 5 http://localhost:$port || echo 'curl failed'"
        log "----- last 40 lines of $svc logs -----"
        ssh_vm "cd /opt/kodus-installer && docker compose logs $svc --tail 40 --no-color" || true
    done
    err "If internal curl works but external fails → firewall on droplet."
    err "If internal curl also fails → container crashed (check logs above)."
    err "To investigate live: re-run with TEST_KEEP_RUNNING=1"
    exit 1
fi

# ---------- UI smoke (shallow Playwright) ----------
# Visits the public auth pages headless to catch build/deploy regressions
# the API-side E2E misses (blank tree, 5xx render, JS crash on hydration).
# Does NOT submit forms — that path is bypassed via direct /auth/signUp.
if [ "${SKIP_UI_SMOKE:-0}" != "1" ]; then
    log "UI smoke (Playwright, no form submit)..."
    pushd "$REPO_ROOT/scripts/test-e2e" >/dev/null
    if [ ! -d node_modules ]; then
        log "  Installing Playwright (one-time, ~30s)..."
        npm install --silent
        npx playwright install chromium >/dev/null 2>&1 || npx playwright install chromium
    fi
    if KODUS_WEB_URL="http://$SERVER_IP:3000" node ui-smoke.mjs; then
        ok "UI smoke passed"
    else
        err "UI smoke failed. Screenshots at scripts/test-e2e/ui-smoke-*.png"
        exit 1
    fi
    popd >/dev/null
fi

# ---------- API smoke checks ----------
# Hit the same routes the frontend hits during signup. If any of these is
# broken on the self-hosted build, we'll know immediately — instead of
# blaming Playwright.
log "API smoke checks (the routes /sign-up needs)..."
api_probe() {
    local label=$1 method=$2 path=$3 body=${4:-}
    local args=(-sS -X "$method" --max-time 15 -o /tmp/kodus-probe-body -w "%{http_code}")
    if [ -n "$body" ]; then
        args+=(-H "Content-Type: application/json" -d "$body")
    fi
    local code
    code=$(curl "${args[@]}" "http://$SERVER_IP:3001$path" 2>&1 || echo "ERR")
    local snippet
    snippet=$(head -c 300 /tmp/kodus-probe-body 2>/dev/null)
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        ok "$label  $method $path → $code  body=${snippet:0:120}"
    else
        warn "$label  $method $path → $code  body=${snippet:0:200}"
    fi
}
api_probe "health    " GET  "/health" || true
api_probe "email-chk " GET  "/user/email?email=probe@kodusqa.io"
api_probe "via-proxy " GET  ""  # placeholder; do proxy probe separately below

# Proxy probe (this is what the browser actually calls during signup)
log "Proxy smoke check (kodus-web → kodus-api)..."
PROXY_CODE=$(curl -sS -X GET --max-time 15 \
    -o /tmp/kodus-probe-body -w "%{http_code}" \
    "http://$SERVER_IP:3000/api/proxy/api/user/email?email=probe2@kodusqa.io" 2>&1 || echo "ERR")
PROXY_BODY=$(head -c 300 /tmp/kodus-probe-body 2>/dev/null)
if [[ "$PROXY_CODE" =~ ^[23][0-9][0-9]$ ]]; then
    ok "proxy GET  /api/proxy/api/user/email → $PROXY_CODE  body=${PROXY_BODY:0:120}"
else
    err "proxy GET  /api/proxy/api/user/email → $PROXY_CODE  body=${PROXY_BODY:0:200}"
    err "  The UI's signup form makes this exact call. If broken here, real"
    err "  users will see a stuck/disabled Continue button. Common causes:"
    err "    - WEB_HOSTNAME_API points at a public host instead of 'kodus-api'"
    err "    - WEB_PORT_API not 3001"
    err "    - kodus-api container crashed (check docker compose logs api)"
    exit 1
fi

# Auth probe via proxy: exercises POST + body through the proxy. A GET
# that works does NOT prove that POST works (CORS, body forwarding,
# Content-Type handling can break independently). 401 means "rotated, api
# alive, credentials rejected" — exactly what we expect with garbage creds.
log "Auth proxy probe: POST /api/proxy/api/auth/login (expect 401)..."
LOGIN_PROBE_CODE=$(curl -sS -X POST --max-time 15 \
    -o /tmp/kodus-probe-body -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d '{"email":"probe@kodusqa.io","password":"definitely-wrong-1A!"}' \
    "http://$SERVER_IP:3000/api/proxy/api/auth/login" 2>&1 || echo "ERR")
LOGIN_PROBE_BODY=$(head -c 300 /tmp/kodus-probe-body 2>/dev/null)
case "$LOGIN_PROBE_CODE" in
    401|403)
        ok "proxy POST /api/proxy/api/auth/login → $LOGIN_PROBE_CODE (expected — bad creds rejected)"
        ;;
    200|201)
        warn "proxy POST /api/proxy/api/auth/login → $LOGIN_PROBE_CODE (UNEXPECTED — bad creds accepted?)"
        warn "  body=${LOGIN_PROBE_BODY:0:200}"
        ;;
    *)
        err "proxy POST /api/proxy/api/auth/login → $LOGIN_PROBE_CODE  body=${LOGIN_PROBE_BODY:0:200}"
        err "  POST through the proxy is broken — real users CANNOT log in."
        err "  The GET probe passed but POST didn't. Usually means:"
        err "    - proxy is forwarding GET but mangling POST body or Content-Type"
        err "    - api is up but rejecting requests from the web container (CORS, allowlist)"
        err "    - reverse proxy / load balancer between web and api eats POST bodies"
        exit 1
        ;;
esac

# ---------- GitHub webhook ----------
log "Creating GitHub webhook on $TEST_REPO..."
HOOK_RESP=$(curl -sS -X POST \
    -H "Authorization: Bearer ${GITHUB_TEST_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${TEST_REPO}/hooks" \
    -d "$(jq -nc --arg url "$SERVER_TUNNEL_URL/github/webhook" \
        '{name:"web", active:true, events:["pull_request","push","issue_comment","pull_request_review","pull_request_review_comment"], config:{url:$url, content_type:"json", insecure_ssl:"0"}}')")
GITHUB_HOOK_ID=$(echo "$HOOK_RESP" | jq -r '.id // empty')
[ -n "$GITHUB_HOOK_ID" ] || { err "Failed to create webhook: $HOOK_RESP"; exit 1; }
ok "Webhook id: $GITHUB_HOOK_ID"

# ---------- signup (direct API call, bypasses the UI) ----------
# The /sign-up UI has a debounced controlled input + async zod refine that
# hits /api/proxy/api/user/email — fragile to drive with Playwright in
# self-hosted. POST /auth/signUp is @Public and the kodus-web UI itself
# ends up calling it. Cut out the middleman.
if [ "${TEST_USE_PLAYWRIGHT:-0}" = "1" ]; then
    log "Running signup via Playwright (TEST_USE_PLAYWRIGHT=1)..."
    pushd "$REPO_ROOT/scripts/test-e2e" >/dev/null
    if [ ! -d node_modules ]; then
        npm install --silent
        npx playwright install chromium >/dev/null 2>&1 || npx playwright install chromium
    fi
    KODUS_WEB_URL="http://$SERVER_IP:3000" \
        TEST_USER_EMAIL="$TEST_USER_EMAIL" \
        TEST_USER_PASSWORD="$TEST_USER_PASSWORD" \
        TEST_REPO="$TEST_REPO" \
        GITHUB_TEST_TOKEN="$GITHUB_TEST_TOKEN" \
        node signup.mjs
    popd >/dev/null
else
    log "Creating user via direct API: POST http://$SERVER_IP:3001/auth/signUp"
    SIGNUP_PAYLOAD=$(jq -nc \
        --arg name "Kodus E2E" \
        --arg email "$TEST_USER_EMAIL" \
        --arg pass "$TEST_USER_PASSWORD" \
        '{name:$name, email:$email, password:$pass}')
    SIGNUP_HTTP=$(curl -sS -X POST \
        -H "Content-Type: application/json" \
        --max-time 30 \
        -d "$SIGNUP_PAYLOAD" \
        -w "\nHTTP_STATUS:%{http_code}\n" \
        "http://$SERVER_IP:3001/auth/signUp" 2>&1 || true)
    SIGNUP_CODE=$(echo "$SIGNUP_HTTP" | grep -E '^HTTP_STATUS:' | head -n1 | cut -d: -f2)
    SIGNUP_BODY=$(echo "$SIGNUP_HTTP" | sed '/^HTTP_STATUS:/d')
    if [[ ! "$SIGNUP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        # Try the lowercase route in case Nest's routing normalised it.
        log "First attempt returned ${SIGNUP_CODE:-?}, retrying with /auth/signup (lowercase)..."
        SIGNUP_HTTP=$(curl -sS -X POST \
            -H "Content-Type: application/json" \
            --max-time 30 \
            -d "$SIGNUP_PAYLOAD" \
            -w "\nHTTP_STATUS:%{http_code}\n" \
            "http://$SERVER_IP:3001/auth/signup" 2>&1 || true)
        SIGNUP_CODE=$(echo "$SIGNUP_HTTP" | grep -E '^HTTP_STATUS:' | head -n1 | cut -d: -f2)
        SIGNUP_BODY=$(echo "$SIGNUP_HTTP" | sed '/^HTTP_STATUS:/d')
    fi
    if [[ "$SIGNUP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        ok "Signup succeeded (HTTP $SIGNUP_CODE)"
    else
        err "Signup failed (HTTP ${SIGNUP_CODE:-no-response})"
        err "  Response body: $SIGNUP_BODY"
        err "  Payload: $SIGNUP_PAYLOAD"
        exit 1
    fi
fi

# ---------- Onboard the GitHub integration & target repo ----------
# Without these steps the webhook arrives but is ignored (no org owns the
# repo). Sequence:
#   1) POST /auth/login          → accessToken
#   2) decode JWT                → organizationId
#   3) GET  /team/               → teamId (signup auto-creates "<name> - team")
#   4) POST /code-management/auth-integration  authMode=token, token=PAT
#   5) GET  /code-management/repositories/org  → find TEST_REPO in available list
#   6) POST /code-management/repositories      → register it (replace mode)
#   7) POST /code-management/finish-onboarding → finalize
# Login VIA THE PROXY — same path the UI uses. Catches the "API up but
# the web→api wiring is broken" class of bugs (wrong WEB_HOSTNAME_API,
# wrong WEB_PORT_API, networking misconfig, etc).
log "Logging in via /api/proxy/api/auth/login (real UI path)..."
LOGIN_RESP=$(curl -sS -X POST -H "Content-Type: application/json" --max-time 20 \
    -d "$(jq -nc --arg e "$TEST_USER_EMAIL" --arg p "$TEST_USER_PASSWORD" \
        '{email:$e, password:$p}')" \
    "http://$SERVER_IP:3000/api/proxy/api/auth/login")
ACCESS_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.data.accessToken // empty')
if [ -z "$ACCESS_TOKEN" ]; then
    err "Login via proxy failed — real users CANNOT log in to this deploy."
    err "  Response: $(echo "$LOGIN_RESP" | head -c 400)"
    err "  Falling back to direct :3001 login to isolate the proxy:"
    LOGIN_DIRECT=$(curl -sS -X POST -H "Content-Type: application/json" --max-time 20 \
        -d "$(jq -nc --arg e "$TEST_USER_EMAIL" --arg p "$TEST_USER_PASSWORD" \
            '{email:$e, password:$p}')" \
        "http://$SERVER_IP:3001/auth/login")
    DIRECT_TOKEN=$(echo "$LOGIN_DIRECT" | jq -r '.data.accessToken // empty')
    if [ -n "$DIRECT_TOKEN" ]; then
        err "  ✗ Proxy login broken, but direct :3001 login works."
        err "    → kodus-api is fine. The web→api proxy is misconfigured."
        err "    → Check WEB_HOSTNAME_API / WEB_PORT_API in .env."
    else
        err "  ✗ Direct :3001 login also failed. api is broken or creds rejected."
        err "    Response: $(echo "$LOGIN_DIRECT" | head -c 400)"
    fi
    exit 1
fi
ok "Logged in via proxy (token length ${#ACCESS_TOKEN})"

# Decode JWT body (2nd dot segment, base64url) to get organizationId.
JWT_BODY=$(echo "$ACCESS_TOKEN" | awk -F. '{print $2}' | tr '_-' '/+')
PAD=$(( 4 - ${#JWT_BODY} % 4 )); [ $PAD -lt 4 ] && JWT_BODY="${JWT_BODY}$(printf '=%.0s' $(seq 1 $PAD))"
ORG_ID=$(printf '%s' "$JWT_BODY" | base64 -d 2>/dev/null | jq -r '.organizationId // empty')
[ -n "$ORG_ID" ] || { err "Could not extract organizationId from JWT"; exit 1; }

TEAM_RESP=$(curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" --max-time 15 \
    "http://$SERVER_IP:3001/team/")
TEAM_ID=$(echo "$TEAM_RESP" | jq -r '.data[0].uuid // empty')
[ -n "$TEAM_ID" ] || { err "Could not find a team. Response: $TEAM_RESP"; exit 1; }
ok "Org=$ORG_ID  Team=$TEAM_ID"

log "Registering GitHub integration with PAT..."
AUTH_INT_RESP=$(curl -sS -X POST --max-time 30 \
    -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg token "$GITHUB_TEST_TOKEN" --arg orgId "$ORG_ID" --arg teamId "$TEAM_ID" \
        '{integrationType:"GITHUB", authMode:"token", token:$token,
          organizationAndTeamData:{organizationId:$orgId, teamId:$teamId}}')" \
    "http://$SERVER_IP:3001/code-management/auth-integration")
AUTH_INT_STATUS=$(echo "$AUTH_INT_RESP" | jq -r '.data.status // empty')
if [ "$AUTH_INT_STATUS" != "SUCCESS" ]; then
    err "auth-integration did not return SUCCESS. Response: $AUTH_INT_RESP"
    exit 1
fi
ok "Integration authorized"

log "Looking up $TEST_REPO in available repositories..."
TARGET_REPO_JSON=$(curl -sS -G --max-time 30 \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    --data-urlencode "teamId=$TEAM_ID" \
    "http://$SERVER_IP:3001/code-management/repositories/org" \
    | jq -c --arg fn "$TEST_REPO" '.data[]? | select(.full_name==$fn)')
if [ -z "$TARGET_REPO_JSON" ] || [ "$TARGET_REPO_JSON" = "null" ]; then
    err "Repo $TEST_REPO not found in the integration's available list."
    err "Make sure GITHUB_TEST_TOKEN has access to it (PAT scopes: repo, admin:repo_hook)."
    exit 1
fi
ok "Found: $(echo "$TARGET_REPO_JSON" | jq -r .full_name) (id $(echo "$TARGET_REPO_JSON" | jq -r .id))"

log "Registering repo in Kodus..."
ADD_REPO_RESP=$(curl -sS -X POST --max-time 30 \
    -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --argjson repo "$TARGET_REPO_JSON" --arg teamId "$TEAM_ID" \
        '{teamId:$teamId, type:"replace", repositories:[$repo]}')" \
    "http://$SERVER_IP:3001/code-management/repositories")
echo "$ADD_REPO_RESP" | jq -e '.data.status==true' >/dev/null \
    || { err "Repo registration failed: $ADD_REPO_RESP"; exit 1; }
ok "Repo registered"

log "Finishing onboarding..."
curl -sS -X POST --max-time 30 \
    -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg teamId "$TEAM_ID" \
        --arg rid "$(echo "$TARGET_REPO_JSON" | jq -r .id)" \
        --arg rname "$(echo "$TARGET_REPO_JSON" | jq -r .name)" \
        '{teamId:$teamId, reviewPR:false, repositoryId:$rid, repositoryName:$rname}')" \
    "http://$SERVER_IP:3001/code-management/finish-onboarding" >/dev/null
ok "Onboarding finished — repo is now linked to org $ORG_ID"

# ---------- trigger review ----------
# Reuse mode: post `@kody review` comment on the existing PR (no clone, no push).
# Create mode: clone repo, create a brand-new PR which kody auto-reviews on open.
if [ -n "${TEST_PR_NUMBER:-}" ]; then
    REUSE_PR=1
    PR_NUMBER="$TEST_PR_NUMBER"
    log "Triggering review on existing PR #$PR_NUMBER via @kody review comment..."
    TRIGGER_RESP=$(GH_TOKEN="$GITHUB_TEST_TOKEN" gh api \
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
    log "Opening new PR on $TEST_REPO..."
    GH_TOKEN="$GITHUB_TEST_TOKEN" gh repo clone "$TEST_REPO" "$TEST_REPO_CLONE" -- --depth=1
    cd "$TEST_REPO_CLONE"
    DEFAULT_BRANCH=$(git symbolic-ref --short HEAD)
    PR_BRANCH="kodus-e2e/$RUN_ID"
    git checkout -b "$PR_BRANCH"
    cat > kodus-e2e-touch.md <<EOF
# Kodus E2E

Run $RUN_ID — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
    git -c user.email=e2e@kodus.test -c user.name="Kodus E2E" add kodus-e2e-touch.md
    git -c user.email=e2e@kodus.test -c user.name="Kodus E2E" \
        commit -m "chore: kodus e2e smoke" >/dev/null
    GH_TOKEN="$GITHUB_TEST_TOKEN" git push -u origin "$PR_BRANCH" >/dev/null 2>&1
    PR_URL=$(GH_TOKEN="$GITHUB_TEST_TOKEN" gh pr create \
        --repo "$TEST_REPO" --base "$DEFAULT_BRANCH" --head "$PR_BRANCH" \
        --title "Kodus E2E: $RUN_ID" \
        --body "Automated PR opened by scripts/test-e2e-vm.sh — safe to close.")
    PR_NUMBER=$(echo "$PR_URL" | sed -E 's|.*/pull/([0-9]+).*|\1|')
    ok "PR #$PR_NUMBER: $PR_URL"
    cd "$REPO_ROOT"
fi

# ---------- poll for review ----------
log "Polling for Kodus review (timeout ${TEST_TIMEOUT_REVIEW}s, only counting activity after $SINCE_ISO)..."
START=$(date +%s)
# NB: in self-hosted with a PAT, the Kody bot posts using the same user
# identity as the PAT owner — i.e. the PR author. So we CAN'T filter by
# `user.login != author`. Instead, only exclude:
#   * the exact trigger comment we just posted (by id), and
#   * any other "@kody …" command comment (body starts with @kody).
# Anything else new since SINCE_ISO is a Kody response.
while true; do
    RC=$(GH_TOKEN="$GITHUB_TEST_TOKEN" gh api \
        "repos/${TEST_REPO}/pulls/${PR_NUMBER}/comments?since=${SINCE_ISO}" 2>/dev/null \
        | jq --argjson trigger "${TRIGGER_COMMENT_ID:-0}" \
            '[.[] | select(.id != $trigger) | select((.body // "") | ascii_downcase | startswith("@kody") | not)] | length')
    IC=$(GH_TOKEN="$GITHUB_TEST_TOKEN" gh api \
        "repos/${TEST_REPO}/issues/${PR_NUMBER}/comments?since=${SINCE_ISO}" 2>/dev/null \
        | jq --argjson trigger "${TRIGGER_COMMENT_ID:-0}" \
            '[.[] | select(.id != $trigger) | select((.body // "") | ascii_downcase | startswith("@kody") | not)] | length')
    RV=$(GH_TOKEN="$GITHUB_TEST_TOKEN" gh api \
        "repos/${TEST_REPO}/pulls/${PR_NUMBER}/reviews" 2>/dev/null \
        | jq --arg since "$SINCE_ISO" \
            '[.[] | select((.submitted_at // .created_at // "") > $since) | select((.body // "") | ascii_downcase | startswith("@kody") | not)] | length')
    if [ "${RC:-0}" -gt 0 ] || [ "${IC:-0}" -gt 0 ] || [ "${RV:-0}" -gt 0 ]; then
        ok "Review detected (review_comments=$RC issue_comments=$IC reviews=$RV)"
        ok "End-to-end test PASSED"
        exit 0
    fi
    if [ $(( $(date +%s) - START )) -ge "$TEST_TIMEOUT_REVIEW" ]; then
        err "Timeout waiting for review on PR #$PR_NUMBER"
        err "  Logs on VM: ssh -i $LOCAL_SSH_KEY root@$SERVER_IP 'cd /opt/kodus-installer && docker compose logs api worker webhooks --tail 200'"
        exit 1
    fi
    sleep 10
done
