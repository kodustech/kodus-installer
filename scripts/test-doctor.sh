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
    [ "$svc" = "rabbitmq" ] && [ "${STUB_RABBIT_DOWN:-}" = "1" ] && exit 0
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
        [ -n "${STUB_APP_RC:-}" ] && [ "$STUB_APP_RC" != "0" ] && { printf '%b\n' "${STUB_APP_FAIL_TEXT:-client error}"; exit "$STUB_APP_RC"; }
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
    local flags=()
    case " $* " in *" DOCTOR_TEST_VERBOSE=1 "*) flags=(--verbose) ;; esac
    (cd "$WORK/install" && env PATH="$WORK/bin:$PATH" "$@" ./scripts/doctor.sh ${flags[@]+"${flags[@]}"}) 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
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
    for needle in ${ABSENT_NEEDLES[@]+"${ABSENT_NEEDLES[@]}"}; do
        printf '%s' "$out" | grep -qF -- "$needle" && { ok=false; echo "    unexpected: $needle"; }
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
    ABSENT_NEEDLES=()
}
EXTRA_NEEDLES=()
ABSENT_NEEDLES=()

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

# A malformed app line keeps its ✘: a tab inside provider text must not hide a failure.
EXTRA_NEEDLES=("✘ One review check line could not be read." "== Review checks (api output) ==" "too many")
check "malformed app fail line still fails the run, raw line in --verbose" 1 "Reviews: NOT RUNNING" DOCTOR_TEST_VERBOSE=1 'STUB_APP_TSV=#version\t2.4.0\nfail\tllm.completion\t\tmodel\tsaid\tthis\ttoo many\n'
out=$(run DOCTOR_TEST_VERBOSE=1 'STUB_APP_TSV=#version\t2.4.0\nfail\tllm.completion\t\tmodel said \033]52;c;ZXZpbA==\a\033[2Jx\tImpact\tFix\n')
if printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')"; then
    fail=$((fail + 1)); echo "FAIL escape bytes from the api reached the --verbose output"
else
    pass=$((pass + 1)); echo "ok   api escape bytes are stripped from report and --verbose log"
fi
# UTF-8-encoded C1 controls (U+009B CSI, U+009D OSC) are dropped; real UTF-8 stays.
out=$(run DOCTOR_TEST_VERBOSE=1 'STUB_APP_TSV=#version\t2.4.0\nfail\tllm.completion\t\tcafé \xc2\x9b2J \xc2\x9d52;c;ZXZpbA==\x07end\tImpact\tFix\n')
if printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\302[\200-\237]')"; then
    fail=$((fail + 1)); echo "FAIL C1 controls reached the output"
elif printf '%s' "$out" | grep -q "café 2J 52;c;ZXZpbA==end"; then
    pass=$((pass + 1)); echo "ok   C1 controls are dropped, UTF-8 text is kept"
else
    fail=$((fail + 1)); echo "FAIL C1 test line missing from the report"
fi

# Failing client: its output becomes the '?' title; escapes must not survive there either.
out=$(run STUB_APP_RC=7 'STUB_APP_FAIL_TEXT=boom \033]52;c;ZXZpbA==\a\033[2Jend')
if printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')"; then
    fail=$((fail + 1)); echo "FAIL escape bytes from a failing api call reached the report"
elif printf '%s' "$out" | grep -q "The review checks did not run: .*boom"; then
    pass=$((pass + 1)); echo "ok   failing api call: its text is shown without escape bytes"
else
    fail=$((fail + 1)); echo "FAIL failing api call text missing from the report"
fi

EXTRA_NEEDLES=("✘ The api service is not running.")
check "api container down: NOT RUNNING, exit 1" 1 "Reviews: NOT RUNNING" STUB_API_DOWN=1

EXTRA_NEEDLES=("✘ Postgres is not accepting connections.")
check "legacy infra check still fails the run" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" STUB_PG_DOWN=1

EXTRA_NEEDLES=("✘ .env has missing or invalid variables.")
check "env schema failure is reported" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" STUB_VALIDATE_ENV_RC=1

# A tunnel or reverse proxy in front of the webhooks service is a valid setup:
# a webhook host other than WEB_HOSTNAME_API cannot be verified from here, it is
# not a failure, and it is one cause, so one line (#2021).
cp "$WORK/install/.env" "$WORK/env.orig"
cat >> "$WORK/install/.env" <<'EOF'
API_GITHUB_CODE_MANAGEMENT_WEBHOOK=https://hooks.tunnel.example/github/webhook
API_GITLAB_CODE_MANAGEMENT_WEBHOOK=https://hooks.tunnel.example/gitlab/webhook
EOF
EXTRA_NEEDLES=("? Git webhook URLs point to hooks.tunnel.example, not WEB_HOSTNAME_API (api.example.com): GitHub, GitLab." "Fix:")
ABSENT_NEEDLES=("✘ API_GITHUB_CODE_MANAGEMENT_WEBHOOK" "host must match WEB_HOSTNAME_API")
check "webhook behind a tunnel: one ? line, verdict stays OK" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"

# A stopped bundled broker is one cause: the api reports it, the service line
# says so, and nothing else repeats it or calls the bundled broker external (#2021).
EXTRA_NEEDLES=("Service rabbitmq is not running.")
ABSENT_NEEDLES=("Skipping RabbitMQ check" "(external RabbitMQ)")
check "bundled RabbitMQ stopped: no repeated or mislabelled lines" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" STUB_RABBIT_DOWN=1

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
