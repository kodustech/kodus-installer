#!/usr/bin/env bash
# scripts/test-install.sh — runs install.sh against a stubbed `docker` and
# asserts which services it starts, so the service list is tested without a
# running stack.
#
# Usage: ./scripts/test-install.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kodus-install-test.XXXXXX")
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT
failed=0

mkdir -p "$WORK/bin" "$WORK/install/scripts"
cp "$ROOT"/scripts/*.sh "$WORK/install/scripts/"
cp "$ROOT/.env.example" "$ROOT/docker-compose.yml" "$WORK/install/"
cp -R "$ROOT/docker" "$WORK/install/" 2>/dev/null || true

# Records every `docker compose up` and answers the readiness checks.
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = compose ]; then
    shift
    case "$1" in
        version) echo "Docker Compose version v2.40.0" ;;
        up) shift; echo "$*" >> "$STUB_UP_LOG" ;;
        ps) echo "stub-container-id" ;;
        logs) echo "Ready in 1s" ;;
        exec) exit 0 ;;
    esac
    exit 0
fi
case "$1" in
    inspect) echo healthy ;;
    info) echo "6.8.0" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/docker"

# The .env an operator has after the quick start: template, minted secrets,
# one webhook URL.
(
    cd "$WORK/install" && cp .env.example .env &&
        ./scripts/generate-secrets.sh >/dev/null 2>&1
    {
        echo "WEB_HOSTNAME_API=api.example.com"
        echo "NEXTAUTH_URL=https://app.example.com"
        echo "API_GITHUB_CODE_MANAGEMENT_WEBHOOK=https://api.example.com/github/webhook"
    } >> .env
)
cp "$WORK/install/.env" "$WORK/base.env"

# case_ <name> <extra .env lines> <service that must be started> <yes|no>
case_() {
    local name=$1 extra=$2 service=$3 want=$4 code=0 got=no
    cp "$WORK/base.env" "$WORK/install/.env"
    [ -n "$extra" ] && printf '%s\n' "$extra" >> "$WORK/install/.env"
    : > "$WORK/up.log"
    (cd "$WORK/install" && PATH="$WORK/bin:$PATH" STUB_UP_LOG="$WORK/up.log" \
        ./scripts/install.sh >"$WORK/out" 2>&1) || code=$?
    grep -qw -- "$service" "$WORK/up.log" && got=yes
    if [ "$code" != 0 ] || [ "$got" != "$want" ]; then
        failed=1
        echo "FAIL $name (exit $code, $service started: $got, want $want)"
        echo "--- up"; cat "$WORK/up.log"
        echo "--- output"; tail -20 "$WORK/out"
    else
        echo "ok   $name"
    fi
}

case_ 'pgbouncer profile on: the pooler is started' \
    $'COMPOSE_PROFILES=pgbouncer\nAPI_PG_DB_HOST=db_kodus_pgbouncer\nAPI_PG_DB_DIRECT_HOST=db_kodus_postgres' \
    db_kodus_pgbouncer yes
case_ 'pgbouncer among other profiles: the pooler is started' \
    $'COMPOSE_PROFILES=analytics,pgbouncer' db_kodus_pgbouncer yes
case_ 'no profile: the pooler is not started' '' db_kodus_pgbouncer no
case_ 'no profile: the bundled Postgres is started' '' db_kodus_postgres yes

exit "$failed"
