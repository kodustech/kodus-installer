#!/usr/bin/env bash
# scripts/test-doctor.sh — runs doctor.sh against a stubbed `docker`/`curl` so
# the report (verdict first, problems worst first, exit code) is tested without
# a running stack. Each scenario breaks one thing and asserts what changes.
#
# Usage: ./scripts/test-doctor.sh [--show]   (--show prints each scenario's report)
set -uo pipefail
SHOW=false
[ "${1:-}" = "--show" ] && SHOW=true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kodus-doctor-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/install/scripts"
cp "$ROOT/scripts/doctor.sh" "$ROOT/scripts/doctor-lib.sh" "$WORK/install/scripts/"
# The env schema check has its own tests; here it must not depend on the host.
printf '#!/usr/bin/env bash\nexit "${STUB_VALIDATE_ENV_RC:-0}"\n' > "$WORK/install/scripts/validate-env.sh"
chmod +x "$WORK/install/scripts/"*.sh

cat > "$WORK/install/.env" <<'EOF'
API_RABBITMQ_ENABLED=true
API_RABBITMQ_URI=amqp://kodus:kodus@rabbitmq:5672/kodus-ai
WEB_HOSTNAME_API=api.example.com
NEXTAUTH_URL=https://app.example.com
API_GITHUB_CODE_MANAGEMENT_WEBHOOK=https://api.example.com/github/webhook
EOF

cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo 200
EOF

cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
# Minimal docker / docker compose stand-in for doctor.sh.
case "$1" in
  info) exit 0 ;;
  network) exit 0 ;;
  inspect)
    case "$3" in
      *Health*) echo "healthy" ;;
      *) echo "running" ;;
    esac
    exit 0 ;;
  compose) shift ;;
  *) exit 0 ;;
esac
case "$1" in
  version) exit 0 ;;
  config)
    [ "${2:-}" = "--services" ] && printf '%s\n' api worker webhooks rabbitmq db_kodus_postgres db_kodus_mongodb kodus-web
    exit 0 ;;
  ps)
    svc="${3:-}"
    [ "$svc" = "api" ] && [ "${STUB_API_DOWN:-}" = "1" ] && exit 0
    echo "id-$svc"; exit 0 ;;
  exec)
    svc="$3"; shift 3
    case "$svc" in
      db_kodus_postgres)
        [ "${STUB_PG_DOWN:-}" = "1" ] && exit 1
        case "$*" in
          *pg_isready*) exit 0 ;;
          *COUNT*) echo 5 ;;
          *) echo 1 ;;
        esac ;;
      db_kodus_mongodb) exit 0 ;;
      rabbitmq)
        case "$*" in
          *consumer_timeout*)
            ct='{ok,7200000}'
            echo "${STUB_CONSUMER_TIMEOUT:-$ct}" ;;
          *) exit 0 ;;
        esac ;;
      api)
        [ -n "${STUB_APP_RC:-}" ] && [ "$STUB_APP_RC" != "0" ] && { echo "client error"; exit "$STUB_APP_RC"; }
        printf '%b' "${STUB_APP_TSV:-}" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/"*

APP_OK='#verdict\tOK\n#version\t2.4.0\nok\tllm.completion\tacme\tThe review model answered a test request.\t\t\n'
APP_FAIL='#verdict\tNOT_RUNNING\n#version\t2.4.0\nfail\tgit.webhook\tacme/core\tNo Kodus webhook on api.\tKodus is never told about new pull requests there.\tReselect the repository in Settings > Git.\nok\tllm.completion\tacme\tThe review model answered a test request.\t\t\n'

pass=0; fail=0
run() {
    (cd "$WORK/install" && env PATH="$WORK/bin:$PATH" "$@" ./scripts/doctor.sh) 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    return "${PIPESTATUS[0]}"
}
check() {
    local name=$1 expect_rc=$2 expect_first=$3; shift 3
    local out rc
    out=$(run "$@"); rc=$?
    local first
    first=$(printf '%s\n' "$out" | head -1)
    local ok=true
    [ "$rc" = "$expect_rc" ] || ok=false
    [ "$first" = "$expect_first" ] || ok=false
    for needle in "${EXTRA_NEEDLES[@]}"; do
        printf '%s' "$out" | grep -qF -- "$needle" || { ok=false; echo "    missing: $needle"; }
    done
    if $SHOW; then
        echo "=== $name"; printf '%s\n' "$out" | sed 's/^/    | /'
    fi
    if $ok; then
        pass=$((pass + 1)); echo "ok   $name"
    else
        fail=$((fail + 1)); echo "FAIL $name (rc=$rc, first line: $first)"
        printf '%s\n' "$out" | sed 's/^/    | /' | head -40
    fi
    EXTRA_NEEDLES=()
}
EXTRA_NEEDLES=()

EXTRA_NEEDLES=("(Kodus 2.4.0)" "check(s) passed")
check "healthy install: verdict OK, exit 0" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
if run STUB_APP_TSV="$APP_OK" | grep -v '^✘ reviews do not run' | grep -qE '^(✘|!|\?) '; then
    fail=$((fail + 1)); echo "FAIL healthy install has a ✘, ! or ? line"
else
    pass=$((pass + 1)); echo "ok   healthy install has no ✘, ! or ? line"
fi

EXTRA_NEEDLES=("✘ No Kodus webhook on api. [acme/core]" "Impact: Kodus is never told" "Fix: Reselect")
check "app problem: NOT RUNNING first, exit 1" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_FAIL"

EXTRA_NEEDLES=("! The message queue stops any job that runs longer than 30 minutes.")
check "consumer_timeout 30 min: DEGRADED" 0 "Reviews: RUNNING, DEGRADED" STUB_APP_TSV="$APP_OK" "STUB_CONSUMER_TIMEOUT={ok,1800000}"

EXTRA_NEEDLES=("? The review checks are not available in this Kodus version.")
check "image without the doctor client: ? line, exit 0" 0 "Reviews: OK" STUB_APP_RC=42

EXTRA_NEEDLES=("✘ The api service is not running.")
check "api container down: NOT RUNNING, exit 1" 1 "Reviews: NOT RUNNING" STUB_API_DOWN=1

EXTRA_NEEDLES=("✘ Postgres is not accepting connections.")
check "legacy infra check still fails the run" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" STUB_PG_DOWN=1

EXTRA_NEEDLES=("✘ .env has missing or invalid variables.")
check "env schema failure is reported" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" STUB_VALIDATE_ENV_RC=1

# Problems before the passing summary, worst first.
out=$(run STUB_APP_TSV="$APP_FAIL" "STUB_CONSUMER_TIMEOUT={ok,1800000}")
l_fail=$(printf '%s\n' "$out" | grep -n '^✘' | head -1 | cut -d: -f1)
l_warn=$(printf '%s\n' "$out" | grep -n '^!' | head -1 | cut -d: -f1)
l_pass=$(printf '%s\n' "$out" | grep -n 'check(s) passed' | cut -d: -f1)
if [ -n "$l_fail" ] && [ "$l_fail" -lt "$l_warn" ] && [ "$l_warn" -lt "$l_pass" ]; then
    pass=$((pass + 1)); echo "ok   ordering: ✘ before ! before the passing summary"
else
    fail=$((fail + 1)); echo "FAIL ordering (✘ at $l_fail, ! at $l_warn, summary at $l_pass)"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
