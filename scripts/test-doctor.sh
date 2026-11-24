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
trap '[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/install/scripts"
cp "$ROOT/scripts/doctor.sh" "$ROOT/scripts/doctor-lib.sh" "$WORK/install/scripts/"
# The env schema check has its own tests; here it must not depend on the host.
cat > "$WORK/install/scripts/validate-env.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${VALIDATE_ENV_REPORT:-}" ] && printf '%b' "${STUB_VALIDATE_ENV_REPORT:-}" >> "$VALIDATE_ENV_REPORT"
exit "${STUB_VALIDATE_ENV_RC:-0}"
EOF
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
#   STUB_DOWN="svc ..."       no container at all for these services
#   STUB_STATE_<svc>=...      docker inspect answer for one service (- becomes _)
[ "${STUB_API_DOWN:-}" = "1" ] && STUB_DOWN="${STUB_DOWN:-} api"
[ "${STUB_RABBIT_DOWN:-}" = "1" ] && STUB_DOWN="${STUB_DOWN:-} rabbitmq"
case "$1" in
  info) exit 0 ;;
  network) exit 0 ;;
  inspect)
    # docker inspect -f <format> <id>
    fmt=$3; svc=${4#id-}
    var="STUB_STATE_$(printf '%s' "$svc" | tr -- '-' '_')"
    case "$fmt" in
      '{{.Name}}') echo "/${STUB_API_CNAME:-kodus_api}" ;;
      *Config.Env*) var="STUB_ENV_$(printf '%s' "$svc" | tr -- '-' '_')"; printf '%b' "${!var:-}" ;;
      *ExitCode*) echo "${!var:-running|0|healthy}" ;;
      *Health*) echo "healthy" ;;
      *) echo "running" ;;
    esac
    exit 0 ;;
  events)
    [ -n "${STUB_OOM_EVENTS:-}" ] && printf '%s\n' $STUB_OOM_EVENTS
    [ -n "${STUB_LEAKS:-}" ] && cat "$STUB_LEAKS"
    exit 0 ;;
  compose) shift ;;
  *) exit 0 ;;
esac
case "$1" in
  version) exit 0 ;;
  config)
    [ "${2:-}" = "--services" ] && printf '%s\n' api worker webhooks rabbitmq db_kodus_postgres db_kodus_mongodb kodus-web
    exit 0 ;;
  logs) [ -n "${STUB_LEAKS:-}" ] && cat "$STUB_LEAKS"; exit 0 ;;
  ps)
    for svc in "$@"; do :; done   # the service is the last argument
    case " ${STUB_DOWN:-} " in *" $svc "*) exit 0 ;; esac
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
      kodus-web)
        # node -e <probe>: url, host, 1 if localhost was mapped, HTTP status or ERR:<code>
        printf '%b\n' "${STUB_WEB_PROBE:-http://kodus_api:3001/health/simple\tkodus_api\t1\t200}" ;;
      rabbitmq)
        case "$*" in
          *check_alarms*)
            [ -n "${STUB_RABBIT_ALARM:-}" ] && { printf '%b\n' "$STUB_RABBIT_ALARM"; exit 69; }
            exit 0 ;;
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
# Host-side datastore clients: an external datastore must never be probed from here.
for tool in pg_isready mongosh nc; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/host-probes"\nexit 1\n' "$tool" "$WORK" > "$WORK/bin/$tool"
done
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
    for needle in ${EXTRA_NEEDLES[@]+"${EXTRA_NEEDLES[@]}"}; do
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

# The review checks never ran, so reviews cannot be called OK: COULD NOT VERIFY, exit 2.
EXTRA_NEEDLES=("? The review checks are not available in this Kodus version.")
check "image without the doctor client: COULD NOT VERIFY, exit 2" 2 "Reviews: COULD NOT VERIFY" STUB_APP_RC=42

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
EXTRA_NEEDLES=("✘ .env has missing or invalid variables: Missing or empty required variable: API_JWT_SECRET; API_PORT=abc is not a valid port (1-65535).")
check "env schema failure names the variables" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" STUB_VALIDATE_ENV_RC=1 'STUB_VALIDATE_ENV_REPORT=fail\tMissing or empty required variable: API_JWT_SECRET\t\nfail\tAPI_PORT=abc is not a valid port (1-65535)\t\n'
# Warnings exit 0, so they only reach the report through the report file.
EXTRA_NEEDLES=("? Kodus does not know 1 variable(s) set in .env: TYPO_VAR." "Fix: Check them for typos")
check "env schema warnings reach the report as ?" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" 'STUB_VALIDATE_ENV_REPORT=unknown\tKodus does not know 1 variable(s) set in .env: TYPO_VAR.\tCheck them for typos against .env.example.\n'

# validate-env.sh itself, on a fixture schema and .env, with the docker stub
# answering the drift check.
VE="$WORK/ve"
mkdir -p "$VE/scripts"
cp "$ROOT/scripts/validate-env.sh" "$VE/scripts/"
cp "$ROOT/docker-compose.yml" "$VE/"
printf 'KODUS_REQUIRED_VARS=(API_PORT)\nKODUS_AUTOGEN_SECRETS=("API_JWT_SECRET=base64-32")\n' > "$VE/scripts/schema-vars.sh"
cat > "$VE/.env.example" <<'EOF'
## ----  SERVER  ----
# (type: port)
API_PORT=3001
API_RABBITMQ_URI=amqp://kodus:kodus@rabbitmq:5672/kodus-ai
RUN_MIGRATIONS=true
API_WEBHOOKS_PORT=3332
OBSERVABILITY_MONGO_ENABLED=
API_JWT_SECRET=
# (secret, type: url, opt-in: uncomment to enable)
# MONGODB_URI=
EOF
cat > "$VE/.env" <<'EOF'
API_PORT=3001
API_RABBITMQ_URI=amqp://kodus:N3wPassw0rd@rabbitmq:5672/kodus-ai
RUN_MIGRATIONS=true
KODUS_LICENSE_KEY=lic-abc
ANALYTICS_PG_DB_HOST=
ANALYTICS_INGESTION_CRON=*/30 * * * *
MONGODB_URI=mongodb+srv://u:p@cluster0.example.net/kodus
TYPO_VAR=1
API_WEBHOOKS_PORT=3333
OBSERVABILITY_MONGO_ENABLED=
API_JWT_SECRET=Se#cretValue1  # a comment starts at " #"
EOF
rm -f "$VE/report"
# webhooks: API_WEBHOOKS_PORT is passed through by compose (${API_WEBHOOKS_PORT:-3332})
# and the container still has the old port: drift. OBSERVABILITY_MONGO_ENABLED
# is empty in .env, so compose's default applies: not drift. RUN_MIGRATIONS is
# a compose literal: not drift. API_JWT_SECRET holds a # that is not a comment.
ve_out=$(env PATH="$WORK/bin:$PATH" VALIDATE_ENV_REPORT="$VE/report" \
    'STUB_ENV_worker=RUN_MIGRATIONS=false\nAPI_PORT=3001\nAPI_RABBITMQ_URI=amqp://kodus:OldPassw0rd@rabbitmq:5672/kodus-ai\nAPI_JWT_SECRET=Se#cretValue1\n' \
    'STUB_ENV_webhooks=API_WEBHOOKS_PORT=3332\nOBSERVABILITY_MONGO_ENABLED=false\nRUN_MIGRATIONS=false\n' \
    bash "$VE/scripts/validate-env.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
ve_ok=true
for needle in "TYPO_VAR is set but not in the self-hosted schema" "worker API_RABBITMQ_URI drift" "webhooks API_WEBHOOKS_PORT drift: .env=3333 container=3332"; do
    printf '%s' "$ve_out" | grep -qF -- "$needle" || { ve_ok=false; echo "    missing: $needle"; }
done
for needle in N3wPassw0rd OldPassw0rd "RUN_MIGRATIONS drift" "OBSERVABILITY_MONGO_ENABLED drift" "API_JWT_SECRET drift" "KODUS_LICENSE_KEY is set" "ANALYTICS_PG_DB_HOST is set" "ANALYTICS_INGESTION_CRON is set" "MONGODB_URI is set"; do
    printf '%s' "$ve_out" | grep -qF -- "$needle" && { ve_ok=false; echo "    unexpected: $needle"; }
done
grep -qF "$(printf 'unknown\tKodus does not know 1 variable(s) set in .env: TYPO_VAR.')" "$VE/report" 2>/dev/null || { ve_ok=false; echo "    report lacks the unknown-variable line"; }
grep -qF "$(printf 'unknown\tThe worker service runs with values that differ from .env: API_RABBITMQ_URI.')" "$VE/report" 2>/dev/null || { ve_ok=false; echo "    report lacks the drift line"; }
if $ve_ok; then
    pass=$((pass + 1)); echo "ok   validate-env: known app vars, masked URIs, compose literals are not drift, pass-throughs are, report file"
else
    fail=$((fail + 1)); echo "FAIL validate-env"; printf '%s\n' "$ve_out" | sed 's/^/    | /' | tail -30
fi

# A tunnel or reverse proxy in front of the webhooks service is a valid setup,
# and WEB_HOSTNAME_API (how the web reaches the api) is not where webhooks go:
# a webhook host other than WEB_HOSTNAME_API is not reported at all.
cp "$WORK/install/.env" "$WORK/env.orig"
cat >> "$WORK/install/.env" <<'EOF'
API_GITHUB_CODE_MANAGEMENT_WEBHOOK=https://hooks.tunnel.example/github/webhook
API_GITLAB_CODE_MANAGEMENT_WEBHOOK=https://hooks.tunnel.example/gitlab/webhook
EOF
ABSENT_NEEDLES=("✘ API_GITHUB_CODE_MANAGEMENT_WEBHOOK" "WEB_HOSTNAME_API" "? Git webhook URLs point to")
check "webhook behind a tunnel: nothing reported, verdict OK" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"

# WEB_HOSTNAME_API=localhost is the documented default (the web maps it to the
# api container): no line about it.
sed -i.bak 's/^WEB_HOSTNAME_API=.*/WEB_HOSTNAME_API=localhost/' "$WORK/install/.env" && rm -f "$WORK/install/.env.bak"
ABSENT_NEEDLES=("localhost;" "WEB_HOSTNAME_API is localhost" "? Git webhook URLs point to")
EXTRA_NEEDLES=("✔ The web reaches the api at http://kodus_api:3001/health/simple (HTTP 200).")
check "WEB_HOSTNAME_API=localhost: no warning, web reaches the api" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" DOCTOR_TEST_VERBOSE=1
# The web maps localhost to GLOBAL_API_CONTAINER_NAME (default kodus_api); a
# .env without it names the api container kodus-api, and the web finds nothing.
EXTRA_NEEDLES=("✘ The web cannot reach the api at http://kodus_api:3001/health/simple (ENOTFOUND)." "Impact: Nobody can sign in" "the api container is named 'kodus-api'" "GLOBAL_API_CONTAINER_NAME=kodus_api")
check "web cannot reach the api (container name mismatch): ✘" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" STUB_API_CNAME=kodus-api 'STUB_WEB_PROBE=http://kodus_api:3001/health/simple\tkodus_api\t1\tERR:ENOTFOUND'
cp "$WORK/env.orig" "$WORK/install/.env"
EXTRA_NEEDLES=("✘ The web cannot reach the api at http://api.example.com:3001/health/simple (ECONNREFUSED)." "Set WEB_HOSTNAME_API=localhost and WEB_PORT_API=3001")
check "web cannot reach the api: ✘" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" 'STUB_WEB_PROBE=http://api.example.com:3001/health/simple\tapi.example.com\t0\tERR:ECONNREFUSED'
EXTRA_NEEDLES=("? The web's call to the api at http://api.example.com:3001/health/simple timed out.")
check "web-to-api timeout: ?, not ✘" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" 'STUB_WEB_PROBE=http://api.example.com:3001/health/simple\tapi.example.com\t0\tERR:TimeoutError'
EXTRA_NEEDLES=("? Could not check whether the web reaches the api.")
check "web-to-api probe gives no answer: ?" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" 'STUB_WEB_PROBE=OCI runtime exec failed'

# A stopped bundled broker stops every review: one ✘ for it, and nothing else
# repeats it or calls the bundled broker external (#2021).
EXTRA_NEEDLES=("✘ The rabbitmq service is not running.")
ABSENT_NEEDLES=("Skipping RabbitMQ check" "(external RabbitMQ)")
check "bundled RabbitMQ stopped: one ✘, no repeated or mislabelled lines" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" STUB_RABBIT_DOWN=1

EXTRA_NEEDLES=("✘ The worker service is not running." "Impact: No review runs")
check "worker stopped: NOT RUNNING, exit 1" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" STUB_DOWN=worker

# The stubbed curl always answers 200, so the skip is asserted by its own
# NOTE and by the probe's success line being absent (--verbose shows both).
EXTRA_NEEDLES=("✘ The webhooks service is stopped (exited with code 1)." "logs --tail 200 webhooks" "Skipping webhooks HTTP check (service not running).")
ABSENT_NEEDLES=("webhooks is not responding" "webhooks is responding")
check "webhooks exited: one ✘, its HTTP probe not repeated" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" "STUB_STATE_webhooks=exited|1|" DOCTOR_TEST_VERBOSE=1

EXTRA_NEEDLES=("? The review checks did not run:")
check "api checks fail to answer: COULD NOT VERIFY, exit 2" 2 "Reviews: COULD NOT VERIFY" STUB_APP_RC=3

# A version header alone, or stray output with no status, is not an answer.
EXTRA_NEEDLES=("? The review checks returned nothing.")
check "api sends only #version: COULD NOT VERIFY, exit 2" 2 "Reviews: COULD NOT VERIFY" 'STUB_APP_TSV=#version\t2.4.0\n'
check "api sends only stray output: COULD NOT VERIFY, exit 2" 2 "Reviews: COULD NOT VERIFY" 'STUB_APP_TSV=#version\t2.4.0\n(node:1) Warning: something\n'

# The api's own UNVERIFIED verdict holds even when every line it sent is ✔.
check "api says UNVERIFIED: COULD NOT VERIFY, exit 2" 2 "Reviews: COULD NOT VERIFY" 'STUB_APP_TSV=#verdict\tUNVERIFIED\n#version\t2.4.0\nok\tllm.completion\tacme\tThe review model answered a test request.\t\t\n'
# Unknown verdict values from a newer api change nothing.
check "api sends an unknown verdict: still OK" 0 "Reviews: OK" 'STUB_APP_TSV=#verdict\tSOMETHING_NEW\n#version\t2.4.0\nok\tllm.completion\tacme\tThe review model answered a test request.\t\t\n'
# A ✘ is a definite answer: it wins over UNVERIFIED.
EXTRA_NEEDLES=("✘ The worker service is not running.")
check "✘ beats COULD NOT VERIFY" 1 "Reviews: NOT RUNNING" STUB_APP_RC=42 STUB_DOWN=worker

# Unset means enabled for the app (anything but "false").
sed -i.bak '/^API_RABBITMQ_ENABLED=/d' "$WORK/install/.env" && rm -f "$WORK/install/.env.bak"
ABSENT_NEEDLES=("API_RABBITMQ_ENABLED")
check "API_RABBITMQ_ENABLED unset: no line, OK" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
echo "API_RABBITMQ_ENABLED=false" >> "$WORK/install/.env"
EXTRA_NEEDLES=("✘ API_RABBITMQ_ENABLED=false turns the message queue off.")
check "API_RABBITMQ_ENABLED=false: ✘" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"

# 7,200,000 ms (2 h) is what the docs ask for and what the fix line says.
EXTRA_NEEDLES=("! The message queue stops any job that runs longer than 110 minutes." "consumer_timeout = 7200000")
check "consumer_timeout below 2 h: DEGRADED" 0 "Reviews: RUNNING, DEGRADED" STUB_APP_TSV="$APP_OK" "STUB_CONSUMER_TIMEOUT={ok,6600000}"

# External datastores: no probe from the host (it cannot resolve
# host.docker.internal, private DNS or mongodb+srv, and ignores the URI the app
# uses); one info line each says the api checks them.
cat >> "$WORK/install/.env" <<'EOF'
USE_LOCAL_DB=false
USE_LOCAL_RABBITMQ=false
API_PG_DB_HOST=host.docker.internal
MONGODB_URI=mongodb+srv://kodus:p%40ss@cluster0.example.mongodb.net/kodus
API_RABBITMQ_URI=amqps://kodus:secret@broker.internal:5671/kodus-ai
EOF
rm -f "$WORK/host-probes"
EXTRA_NEEDLES=("i Postgres is external (USE_LOCAL_DB=false)" "i MongoDB is external (MONGODB_URI)" "i RabbitMQ is external (USE_LOCAL_RABBITMQ=false)" "from inside the api")
ABSENT_NEEDLES=("External Postgres" "External MongoDB" "External RabbitMQ" "p%40ss" "secret@")
check "external datastores: no host probe, info lines" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
if [ -s "$WORK/host-probes" ]; then
    fail=$((fail + 1)); echo "FAIL external datastores were probed from the host: $(cat "$WORK/host-probes")"
else
    pass=$((pass + 1)); echo "ok   external datastores: nothing probed from the host"
fi
cp "$WORK/env.orig" "$WORK/install/.env"
# MONGODB_URI wins over the bundled container even with USE_LOCAL_DB=true.
echo "API_MG_DB_URI=mongodb://kodus:pw@mongo.internal:27017/kodus" >> "$WORK/install/.env"
EXTRA_NEEDLES=("i MongoDB is external (API_MG_DB_URI)")
ABSENT_NEEDLES=("Postgres is external")
check "API_MG_DB_URI set: Mongo checked from the api" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"

# Bundled or external broker, by a plain rule on the URI's host. The URI itself
# is never judged here (the api's broker check connects with the real client).
echo "API_RABBITMQ_URI=amqps://kodus:secret@broker.internal:5671/kodus-ai" >> "$WORK/install/.env"
EXTRA_NEEDLES=("i RabbitMQ is external (API_RABBITMQ_URI host broker.internal)")
check "external broker host: external" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"
echo "API_RABBITMQ_URI=amqp://kodus:kodus@RabbitMQ:5672/kodus-ai" >> "$WORK/install/.env"
EXTRA_NEEDLES=("✔ The message queue lets jobs run up to 120 minutes.")
ABSENT_NEEDLES=("RabbitMQ is external")
check "bundled broker host: bundled checks run" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" DOCTOR_TEST_VERBOSE=1
cp "$WORK/env.orig" "$WORK/install/.env"
# A host that cannot be read counts as the bundled broker: it is still checked.
echo "API_RABBITMQ_URI=amqp://:5672/kodus-ai" >> "$WORK/install/.env"
EXTRA_NEEDLES=("✔ The message queue lets jobs run up to 120 minutes." "✔ The message queue has no resource alarm")
ABSENT_NEEDLES=("RabbitMQ is external")
check "odd broker URI with the bundled broker running: bundled checks run, no ✘" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" DOCTOR_TEST_VERBOSE=1
cp "$WORK/env.orig" "$WORK/install/.env"
# A URI the client would reject (unencoded / in a generated password) is the
# api's to report (✘ broker.connect, in the client's words): no ✘ from here.
echo "API_RABBITMQ_URI=amqp://kodus:pa/ss@rabbitmq:5672/kodus-ai" >> "$WORK/install/.env"
ABSENT_NEEDLES=("cannot be parsed" "API_RABBITMQ_URI has")
check "broker URI shape: the installer prints no ✘ for it" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"

# The scheme is case-insensitive, and so is the host the doctor reads.
echo "API_GITHUB_CODE_MANAGEMENT_WEBHOOK=HTTPS://" >> "$WORK/install/.env"
EXTRA_NEEDLES=("✘ API_GITHUB_CODE_MANAGEMENT_WEBHOOK (GitHub) must include a valid host.")
check "HTTPS:// with no host: ✘ no valid host" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"
echo "API_GITHUB_CODE_MANAGEMENT_WEBHOOK=HTTPS://Hooks.Example.com/hooks" >> "$WORK/install/.env"
EXTRA_NEEDLES=("(example: https://hooks.example.com/github/webhook)")
ABSENT_NEEDLES=("https://HTTPS/" "must include a valid host")
check "HTTPS:// with a wrong path: the example names the real host" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"

# http works for a Git server on the same network, and the app does not require https.
echo "API_GITLAB_CODE_MANAGEMENT_WEBHOOK=http://api.example.com/gitlab/webhook" >> "$WORK/install/.env"
EXTRA_NEEDLES=("? The GitLab webhook URL uses http:// (API_GITLAB_CODE_MANAGEMENT_WEBHOOK).")
ABSENT_NEEDLES=("✘ API_GITLAB_CODE_MANAGEMENT_WEBHOOK")
check "http webhook: ?, not ✘" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK"
cp "$WORK/env.orig" "$WORK/install/.env"

# A resource alarm blocks every publisher while check_running still passes (#1694).
EXTRA_NEEDLES=("✘ The message queue is blocking new jobs (RabbitMQ disk alarm)." "1.2 times the machine's RAM" "disk_free_limit.relative = 1.2")
ABSENT_NEEDLES=("vm_memory_high_watermark")
check "RabbitMQ disk alarm: ✘" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" "STUB_RABBIT_ALARM=Free disk space alarm on node rabbit@rabbitmq"
EXTRA_NEEDLES=("✘ The message queue is blocking new jobs (RabbitMQ disk and memory alarm)." "vm_memory_high_watermark.relative = 0.4")
check "RabbitMQ disk and memory alarms: ✘ with both fixes" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" "STUB_RABBIT_ALARM=Free disk space alarm on node rabbit@rabbitmq\nMemory alarm on node rabbit@rabbitmq"
EXTRA_NEEDLES=("? Could not check the message queue for resource alarms.")
check "alarm check errors out: ?, not ✘" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" "STUB_RABBIT_ALARM=Error: unable to perform an operation on node"

# Crash loop: running right now, but restarted again and again in the last minutes.
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000000000Z)
EXTRA_NEEDLES=("✘ The worker service keeps restarting (6 restarts" "Impact: Reviews stop each time it restarts." "docker compose logs --tail 200 worker")
check "restart loop: ✘ even while running" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" "STUB_STATE_worker=running|0||6|false|$NOW|/kodus-worker-prod"
EXTRA_NEEDLES=("✘ The api service keeps restarting (7 restarts")
ABSENT_NEEDLES=("The review checks did not run")
check "api caught between restarts: ✘, review checks not attempted" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" "STUB_STATE_api=restarting|1||7|false|$NOW|/kodus_api"
# Old restarts on a service that has been up for a while are not a loop.
ABSENT_NEEDLES=("keeps restarting")
check "old restarts, long uptime: no loop" 0 "Reviews: OK" STUB_APP_TSV="$APP_OK" "STUB_STATE_worker=running|0||9|false|2020-01-01T00:00:00Z|/kodus-worker-prod"

EXTRA_NEEDLES=("! The worker service was killed for running out of memory." "Give the machine more memory")
check "OOMKilled: ! naming memory" 0 "Reviews: RUNNING, DEGRADED" STUB_APP_TSV="$APP_OK" "STUB_STATE_worker=running|0||1|true|2020-01-01T00:00:00Z|/kodus-worker-prod"
EXTRA_NEEDLES=("✘ The worker service was killed for running out of memory (exited with code 137)." "Give the machine more memory")
ABSENT_NEEDLES=("The worker service is stopped")
check "OOMKilled and still down: one ✘ naming memory" 1 "Reviews: NOT RUNNING" STUB_APP_TSV="$APP_OK" "STUB_STATE_worker=exited|137||0|true|2020-01-01T00:00:00Z|/kodus-worker-prod"
EXTRA_NEEDLES=("! The worker service was killed for running out of memory.")
check "recent OOM event after a restart: !" 0 "Reviews: RUNNING, DEGRADED" STUB_APP_TSV="$APP_OK" "STUB_STATE_worker=running|0||1|false|2020-01-01T00:00:00Z|/kodus-worker-prod" STUB_OOM_EVENTS=kodus-worker-prod

# Run from another directory: .env and the compose project are still found.
out=$(cd "$WORK" && env PATH="$WORK/bin:$PATH" STUB_APP_TSV="$APP_OK" ./install/scripts/doctor.sh 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
if [ "$(printf '%s\n' "$out" | head -1)" = "Reviews: OK" ] && ! printf '%s' "$out" | grep -q '.env file not found'; then
    pass=$((pass + 1)); echo "ok   run from another directory: OK"
else
    fail=$((fail + 1)); echo "FAIL run from another directory"; printf '%s\n' "$out" | sed 's/^/    | /' | head -20
fi

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

# ---------------------------------------------------------------------------
# doctor-k8s.sh against a stubbed kubectl/helm (namespace kodus, release kodus).
# ---------------------------------------------------------------------------
mkdir -p "$WORK/kbin"
cp "$ROOT/scripts/doctor-k8s.sh" "$ROOT/scripts/collect-diagnostics.sh" "$ROOT/scripts/collect-diagnostics-compose.sh" \
    "$ROOT/scripts/redact-lib.sh" "$WORK/install/scripts/"
printf '#!/usr/bin/env bash\necho '"'"'{"info":{"status":"deployed"}}'"'"'\n' > "$WORK/kbin/helm"
cat > "$WORK/kbin/kubectl" <<'EOF'
#!/usr/bin/env bash
#   K_RMQ=bundled|operator|none   which RabbitMQ pod exists
#   K_ALARM=<check_alarms output> K_OOM=<pod\tcontainer=last/current;...>
#   K_PROBE_<svc>=<status|ERR:code> K_JOB=<name> K_API_READY=<n>
#   K_CM_<KEY>=<configmap value>  K_EXEC_FORBIDDEN=1  K_APP_TSV=<api doctor tsv>
[ "$1" = "-n" ] && shift 2
case "$1" in
  version)
    case " $* " in *" --client "*) echo '{"clientVersion":{"gitVersion":"v1.31.0"}}' ;; *) echo '{"serverVersion":{"gitVersion":"v1.31.0"}}' ;; esac
    exit 0 ;;
  config) [ "$2" = current-context ] && echo kind-kodus || echo kodus; exit 0 ;;
  get)
    what=$2; shift 2
    case "$what" in
      job) if [ "$1" = -l ]; then echo "${K_JOB:-}"; else echo 1; fi ;;
      deploy|deployment)
        if [ "$1" = -l ]; then printf '%s\n' kodus-api kodus-worker kodus-webhooks kodus-web kodus-mcp-manager; exit 0; fi
        case "$*" in
          *containers*) case "$1" in kodus-api) echo 3001 ;; kodus-webhooks) echo 3332 ;; kodus-web) echo 3000 ;; kodus-mcp-manager) echo 3101 ;; esac ;;
          *readyReplicas*) if [ "$1" = kodus-api ]; then echo "${K_API_READY-2}"; else echo 2; fi ;;
          *spec.replicas*) echo 2 ;;
        esac ;;
      statefulset)
        if [ "$1" = -l ]; then printf '%s\n' kodus-postgres kodus-mongodb kodus-rabbitmq; exit 0; fi
        case "$*" in *image*) echo mongo:8.2.11 ;; *) echo 1 ;; esac ;;
      pods)
        case "$*" in
          *deletionTimestamp*) ;;
          *containerStatuses*) printf '%b' "${K_OOM:-}" ;;
          *--no-headers*) printf '%s\n' "kodus-api-1 1/1 Running 0 1h" "kodus-worker-1 1/1 Running 0 1h" ;;
          *metadata.name*) printf '%s\n' kodus-api-1 kodus-worker-1 ;;
        esac ;;
      pod)
        case "$1:${K_RMQ:-bundled}" in
          kodus-rabbitmq-0:bundled|kodus-rabbitmq-server-0:operator) exit 0 ;;
          *) exit 1 ;;
        esac ;;
      configmap)
        case "$*" in
          *go-template*) echo "kodus.io/chart=kodus-0.3.7" ;;
          *jsonpath*)
            key=$(printf '%s' "$*" | sed -n 's/.*{\.data\.\([A-Z_]*\)}.*/\1/p'); var="K_CM_$key"
            case "$key" in
              WEB_HOSTNAME_API) echo "${!var-kodus-api}" ;;
              NEXTAUTH_URL) echo "${!var-https://app.example.com}" ;;
              API_GITHUB_CODE_MANAGEMENT_WEBHOOK) echo "${!var-https://hooks.example.com/github/webhook}" ;;
              *) echo "${!var-}" ;;
            esac ;;
        esac ;;
      secret)
        case "$*" in
          *API_CRYPTO_KEY*) printf '%s' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef | base64 ;;
          *API_JWT_SECRET*) printf 'c2VjcmV0' ;;
        esac ;;
      pvc) echo "data-kodus-postgres-0 Bound pvc-1 10Gi RWO standard 1h" ;;
      *) [ -n "${K_LEAKS:-}" ] && cat "$K_LEAKS" ;;   # get all,... / get events
    esac
    exit 0 ;;
  logs|describe) [ -n "${K_LEAKS:-}" ] && cat "$K_LEAKS"; exit 0 ;;
  exec)
    target=$2
    if [ -n "${K_EXEC_FORBIDDEN:-}" ]; then
      echo 'Error from server (Forbidden): pods "x" is forbidden: User "u" cannot create resource "pods/exec"'; exit 1
    fi
    case "$*" in
      *check_alarms*) [ -n "${K_ALARM:-}" ] && { printf '%b\n' "$K_ALARM"; exit 69; } ;;
      *consumer_timeout*) echo '{ok,7200000}' ;;
      *doctor-client*) printf '%b' "${K_APP_TSV:-}" ;;
      *"node -e"*) svc=${target#deploy/kodus-}; var="K_PROBE_$(printf '%s' "$svc" | tr -- '-' '_')"; echo "${!var:-200}" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$WORK/kbin/"*

krun() {
    local flags=()
    case " $* " in *" K_DEV=1 "*) flags+=(--profile dev) ;; esac
    case " $* " in *" DOCTOR_TEST_VERBOSE=1 "*) flags+=(--verbose) ;; esac
    (cd "$WORK/install" && env PATH="$WORK/kbin:$PATH" "$@" ./scripts/doctor-k8s.sh -n kodus -r kodus ${flags[@]+"${flags[@]}"}) 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    return "${PIPESTATUS[0]}"
}
kcheck() { # same contract as check(), against doctor-k8s.sh
    local name=$1 expect_rc=$2 expect_first=$3; shift 3
    local out rc first ok=true
    out=$(krun "$@"); rc=$?
    first=$(printf '%s\n' "$out" | head -1)
    [ "$rc" = "$expect_rc" ] || ok=false
    [ "$first" = "$expect_first" ] || ok=false
    for needle in ${EXTRA_NEEDLES[@]+"${EXTRA_NEEDLES[@]}"}; do
        printf '%s' "$out" | grep -qF -- "$needle" || { ok=false; echo "    missing: $needle"; }
    done
    for needle in ${ABSENT_NEEDLES[@]+"${ABSENT_NEEDLES[@]}"}; do
        printf '%s' "$out" | grep -qF -- "$needle" && { ok=false; echo "    unexpected: $needle"; }
    done
    if $SHOW; then echo "=== k8s: $name"; printf '%s\n' "$out" | sed 's/^/    | /'; fi
    if $ok; then
        pass=$((pass + 1)); echo "ok   k8s: $name"
    else
        fail=$((fail + 1)); echo "FAIL k8s: $name (rc=$rc, first line: $first)"
        printf '%s\n' "$out" | sed 's/^/    | /' | head -40
    fi
    EXTRA_NEEDLES=(); ABSENT_NEEDLES=()
}

ABSENT_NEEDLES=("migration job")
kcheck "healthy release: OK, no migration-job line once the Job is cleaned up" 0 "Reviews: OK" K_APP_TSV="$APP_OK"
if krun K_APP_TSV="$APP_OK" | grep -v '^✘ reviews do not run' | grep -qE '^(✘|!|\?) '; then
    fail=$((fail + 1)); echo "FAIL k8s: healthy release has a ✘, ! or ? line"
else
    pass=$((pass + 1)); echo "ok   k8s: healthy release has no ✘, ! or ? line"
fi
EXTRA_NEEDLES=("? no migration job found and the api is not ready")
kcheck "no migration job and api not ready: ?" 1 "Reviews: NOT RUNNING" K_APP_TSV="$APP_OK" K_API_READY=0
EXTRA_NEEDLES=("✘ The message queue is blocking new jobs (RabbitMQ disk alarm)." "kodus-rabbitmq-server-0")
kcheck "alarm on the operator's RabbitMQ pod: ✘" 1 "Reviews: NOT RUNNING" K_APP_TSV="$APP_OK" K_RMQ=operator "K_ALARM=Free disk space alarm on node rabbit@kodus-rabbitmq-server-0"
EXTRA_NEEDLES=("! Pod kodus-worker-1 (container worker) was killed for running out of memory.")
kcheck "OOMKilled container: !" 0 "Reviews: RUNNING, DEGRADED" K_APP_TSV="$APP_OK" 'K_OOM=kodus-worker-1\tworker=OOMKilled/;\nkodus-api-1\tapi=/;\n'
EXTRA_NEEDLES=("✘ webhooks /health/ready → not answering (ECONNREFUSED)" "Impact: Kodus is not told about new pull requests")
kcheck "webhooks not listening (exec probe): ✘" 1 "Reviews: NOT RUNNING" K_APP_TSV="$APP_OK" K_PROBE_webhooks=ERR:ECONNREFUSED
EXTRA_NEEDLES=("? api /health did not answer within 8s")
kcheck "slow api probe: ?, not ✘" 0 "Reviews: OK" K_APP_TSV="$APP_OK" K_PROBE_api=ERR:TimeoutError
EXTRA_NEEDLES=("? couldn't check RabbitMQ alarms (exec not permitted for this user)" "? couldn't probe api /health from inside its pod")
kcheck "exec forbidden: no ✘, COULD NOT VERIFY, exit 2" 2 "Reviews: COULD NOT VERIFY" K_EXEC_FORBIDDEN=1
EXTRA_NEEDLES=("? GitLab webhook uses http://" "✘ GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK points at localhost" "✔ Forgejo webhook: https://hooks.example.com/forgejo/webhook")
ABSENT_NEEDLES=("✘ API_GITLAB")
kcheck "webhooks: http is ?, localhost is ✘ in prod, every provider checked" 1 "Reviews: NOT RUNNING" K_APP_TSV="$APP_OK" DOCTOR_TEST_VERBOSE=1 \
    K_CM_API_GITLAB_CODE_MANAGEMENT_WEBHOOK=http://gitlab-hooks.internal/gitlab/webhook \
    K_CM_GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK=https://localhost/bitbucket/webhook \
    K_CM_API_FORGEJO_CODE_MANAGEMENT_WEBHOOK=https://hooks.example.com/forgejo/webhook
# The loopback rule is plain on purpose (localhost, ::1, 0.0.0.0, 127.x.y.z;
# case, one trailing dot, brackets, user info and port ignored). Other
# spellings are left to the api's webhook probe.
loop_bad=""
for u in https://localhost/x https://LOCALHOST/x http://127.0.0.1:3332/x https://127.0.0.1./x \
         "https://[::1]:3332/x" HTTPS://user:pw@LocalHost./x https://0.0.0.0/x \
         https://hooks.localhost/x "https://127.0.0.1?heartbeat=60" "https://127.255.0.1#x"; do
    (. "$ROOT/scripts/doctor-lib.sh"; rm -f "$DOCTOR_RESULTS" "$DOCTOR_DETAIL"; doctor_is_loopback_host "$(doctor_url_host "$u")") || loop_bad+=" $u(missed)"
done
for u in https://hooks.example.com/x https://localhost.example.com/x https://127.example.com/x "https://[2001:db8::1]/x" \
         https://10.0.0.1/x https://128.0.0.1/x https://127.0.0.256/x "https://hooks.example.com?u=localhost" "https://#localhost"; do
    (. "$ROOT/scripts/doctor-lib.sh"; rm -f "$DOCTOR_RESULTS" "$DOCTOR_DETAIL"; doctor_is_loopback_host "$(doctor_url_host "$u")") && loop_bad+=" $u(false)"
done
if [ -z "$loop_bad" ]; then
    pass=$((pass + 1)); echo "ok   loopback hosts: localhost, *.localhost, 127.x (octets 0-255), ::1, 0.0.0.0 in any case; other hosts are not"
else
    fail=$((fail + 1)); echo "FAIL loopback hosts:$loop_bad"
fi
EXTRA_NEEDLES=("✘ GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK points at localhost" "✔ Forgejo webhook: https://[2001:db8::1]/forgejo/webhook")
kcheck "webhooks: [::1] is loopback, a real IPv6 host is not" 1 "Reviews: NOT RUNNING" K_APP_TSV="$APP_OK" DOCTOR_TEST_VERBOSE=1 \
    "K_CM_GLOBAL_BITBUCKET_CODE_MANAGEMENT_WEBHOOK=https://[::1]:3332/bitbucket/webhook" \
    "K_CM_API_FORGEJO_CODE_MANAGEMENT_WEBHOOK=https://[2001:db8::1]/forgejo/webhook"
EXTRA_NEEDLES=("✘ API_GITHUB_CODE_MANAGEMENT_WEBHOOK points at localhost" "✔ GitLab webhook: https://localhost.example.com/gitlab/webhook")
kcheck "webhooks: LOCALHOST is loopback, localhost.example.com is not" 1 "Reviews: NOT RUNNING" K_APP_TSV="$APP_OK" DOCTOR_TEST_VERBOSE=1 \
    K_CM_API_GITHUB_CODE_MANAGEMENT_WEBHOOK=HTTPS://LOCALHOST/github/webhook \
    K_CM_API_GITLAB_CODE_MANAGEMENT_WEBHOOK=https://localhost.example.com/gitlab/webhook
EXTRA_NEEDLES=("? NEXTAUTH_URL is empty")
kcheck "empty NEXTAUTH_URL: a line" 0 "Reviews: OK" K_APP_TSV="$APP_OK" K_CM_NEXTAUTH_URL=
APP_UNVERIFIED='#verdict\tUNVERIFIED\n#version\t2.4.0\n'
kcheck "api says UNVERIFIED: COULD NOT VERIFY, exit 2" 2 "Reviews: COULD NOT VERIFY" K_APP_TSV="$APP_UNVERIFIED"
# --profile dev: the api's own answers stay out of the exit code (a fresh CI install).
kcheck "--profile dev: api UNVERIFIED does not fail the run" 0 "Reviews: COULD NOT VERIFY" K_APP_TSV="$APP_UNVERIFIED" K_DEV=1
kcheck "--profile dev: api not answering still exits 2" 2 "Reviews: COULD NOT VERIFY" K_DEV=1

# ---------------------------------------------------------------------------
# Support bundle redaction (scripts/redact-lib.sh). Each LEAKnn must go; the
# KEEP lines must come out unchanged.
# ---------------------------------------------------------------------------
cat > "$WORK/leaks.txt" <<'EOF'
mongo error: connect mongodb://kodus:LEAK01pass@db_kodus_mongodb:27017/kodus_db?authSource=admin
atlas mongodb+srv://kodus:LEAK02p@ss@cluster0.abcd.mongodb.net/kodus
amqp://kodus:LEAK03pw@rabbitmq:5672/kodus-ai and amqps://user:LEAK04pw@broker:5671/x
postgres://kodus:LEAK05pw@db:5432/kodus postgresql://u:LEAK06pw@db/x
clone https://oauth2:glpat-LEAK07aaaaaaaaaaaa@gitlab.example.com/group/repo.git
clone https://x:ghp_LEAK08aaaaaaaaaaaaaaaa@github.com/org/repo.git
Authorization: Bearer LEAK09abcdefghij.klmnop
header Basic TEVBSzEwOnBhc3N3b3Jk==
provider said: invalid key sk-LEAK11abcdefghijklmnop
anthropic sk-ant-api03-LEAK12abcdefghijklmnop
openai sk-proj-LEAK13abcdefghijklmnop
tokens ghp_LEAK14aaaaaaaa gho_LEAK15aaaaaaaa ghs_LEAK16aaaaaaaa github_pat_LEAK17aaaaaaaa_bbbb
gitlab glpat-LEAK18aaaaaaaaaaaa slack xoxb-LEAK19-aaaaaaaaa
google AIzaLEAK20aaaaaaaaaaaaaaaaaaaaaaa team kodus_LEAK21aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJMRUFLMjIifQ.LEAK22signatureAAAA
API_PG_DB_PASSWORD=LEAK23pw RABBITMQ_DEFAULT_PASS=LEAK24pw API_MG_DB_PASS="LEAK25 pw"
{"level":50,"password":"LEAK26 with spaces","apiKey":"LEAK27 x","msg":"ok"}
{"token": "LEAK28\"esc\" more", "x-api-key":"LEAK29"}
API_RABBITMQ_URI: amqp://kodus:LEAK30@rabbitmq:5672/kodus-ai
      API_CRYPTO_KEY:  LEAK31value
masked sk-svcac****LEAK32VeAA
query ?client_secret=LEAK33&x=1
API_PG_DB_PASSWORD=ab&LEAK34tail API_KEY=<LEAK35> DB_PASSWORD=x;LEAK36,y API_TOKEN=ab"LEAK37
EOF
cat > "$WORK/keep.txt" <<'EOF'
Schema kodus_workflow exists.
routingKey: "workflow.jobs.created.WEBHOOK_PROCESSING"
image sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
task-assessment-runner disk-usage-checker
{"private": true, "cacheKey": "abc"}
GLOBAL_API_CONTAINER_NAME=kodus_api WEB_HOSTNAME_API=localhost
https://api.example.com:3001/health
EOF
# shellcheck source=scripts/redact-lib.sh
. "$ROOT/scripts/redact-lib.sh"
left=$(kodus_redact < "$WORK/leaks.txt" | grep -o 'LEAK[0-9]*' | sort -u | tr '\n' ' ')
if [ -z "$left" ]; then
    pass=$((pass + 1)); echo "ok   redaction: URL credentials, Bearer/Basic, provider keys, JWTs, *_PASS(WORD) and JSON values"
else
    fail=$((fail + 1)); echo "FAIL redaction left: $left"; kodus_redact < "$WORK/leaks.txt" | grep 'LEAK' | sed 's/^/    | /'
fi
if kodus_redact < "$WORK/keep.txt" | diff "$WORK/keep.txt" - >/dev/null; then
    pass=$((pass + 1)); echo "ok   redaction keeps schema names, routing keys, digests and plain URLs"
else
    fail=$((fail + 1)); echo "FAIL redaction changed harmless text"; kodus_redact < "$WORK/keep.txt" | diff "$WORK/keep.txt" - | sed 's/^/    | /'
fi
printf 'S3cretValueFromEnv\n' > "$WORK/values.txt"
if [ "$(echo 'auth failed with S3cretValueFromEnv' | KODUS_REDACT_VALUES_FILE="$WORK/values.txt" kodus_redact)" = "auth failed with <redacted>" ]; then
    pass=$((pass + 1)); echo "ok   redaction: known values from .env are replaced wherever they appear"
else
    fail=$((fail + 1)); echo "FAIL redaction of known values"
fi

# The K8s bundle: every file in the archive goes through the redactor,
# describe-pods and the doctor output included.
# -o names a directory that does not exist yet: it is created up front.
(cd "$WORK/install" && env PATH="$WORK/kbin:$PATH" K_LEAKS="$WORK/leaks.txt" K_APP_TSV="$APP_OK" \
    ./scripts/collect-diagnostics.sh -n kodus -r kodus -o "$WORK/bundle/new") > "$WORK/bundle.log" 2>&1
tarball=$(ls "$WORK/bundle/new"/kodus-diagnostics-kodus-*.tar.gz 2>/dev/null | head -1)
if [ -n "$tarball" ] && mkdir -p "$WORK/bundle/x" && tar -xzf "$tarball" -C "$WORK/bundle/x" \
    && [ -s "$(ls "$WORK/bundle/x"/*/04-describe-pods.txt)" ] && ls "$WORK/bundle/x"/*/07-doctor.txt >/dev/null \
    && ! grep -rq 'LEAK[0-9]' "$WORK/bundle/x"; then
    pass=$((pass + 1)); echo "ok   k8s support bundle: no secret survives in any file"
else
    fail=$((fail + 1)); echo "FAIL k8s support bundle"; cat "$WORK/bundle.log" | sed 's/^/    | /' | tail -10
    grep -rn 'LEAK[0-9]' "$WORK/bundle/x" 2>/dev/null | head -10 | sed 's/^/    | /'
fi

# A bare -o (no value) is reported, not an unbound-variable abort.
bare_ok=true
for script in collect-diagnostics.sh collect-diagnostics-compose.sh; do
    bare_out=$(cd "$WORK/install" && env PATH="$WORK/kbin:$WORK/bin:$PATH" ./scripts/$script -o 2>&1); bare_rc=$?
    if [ "$bare_rc" -ne 1 ] || ! printf '%s' "$bare_out" | grep -q 'needs a' || printf '%s' "$bare_out" | grep -q 'unbound'; then
        bare_ok=false; echo "    $script -o: rc=$bare_rc: $bare_out"
    fi
done
if $bare_ok; then
    pass=$((pass + 1)); echo "ok   support bundles: a bare -o is reported, not a set -u abort"
else
    fail=$((fail + 1)); echo "FAIL support bundles: bare -o"
fi

# The Compose bundle: logs, events and the doctor go through the redactor, a
# secret value from .env is replaced wherever it appears, .env contributes key
# names only, and a container's env contributes RELEASE_VERSION only.
cp "$WORK/env.orig" "$WORK/install/.env"
echo 'API_JWT_SECRET=LEAK40envValueFromDotEnv' >> "$WORK/install/.env"
echo 'mongo said: authentication failed, password LEAK40envValueFromDotEnv' >> "$WORK/leaks.txt"
# Compose passes pa#... whole (a comment needs a space before #): so must the scrub.
echo 'API_PG_DB_PASSWORD=Pa#LEAK43word  # db password' >> "$WORK/install/.env"
echo 'provider rejected credentials Pa#LEAK43word for user kodus' >> "$WORK/leaks.txt"
rm -rf "$WORK/cbundle"; mkdir -p "$WORK/cbundle"
(cd "$WORK" && env PATH="$WORK/bin:$PATH" STUB_LEAKS="$WORK/leaks.txt" STUB_APP_TSV="$APP_OK" \
    'STUB_ENV_api=RELEASE_VERSION=2.4.0\nAPI_PG_DB_PASSWORD=LEAK41containerEnv\nWEB_HOSTNAME_API=localhost\n' \
    ./install/scripts/collect-diagnostics-compose.sh -o "$WORK/cbundle") > "$WORK/cbundle.log" 2>&1
tarball=$(ls "$WORK/cbundle"/kodus-diagnostics-compose-*.tar.gz 2>/dev/null | head -1)
cb_ok=true
if [ -z "$tarball" ] || ! mkdir -p "$WORK/cbundle/x" || ! tar -xzf "$tarball" -C "$WORK/cbundle/x"; then
    cb_ok=false; echo "    no archive"
else
    for f in 00-host.txt 01-docker.txt 02-installer.txt 03-images.txt 05-state.txt 06-events.txt 08-env-keys.txt 09-validate-env.txt 11-doctor.txt 12-api-doctor.json logs/api.log logs/rabbitmq.log; do
        ls "$WORK/cbundle/x"/*/"$f" >/dev/null 2>&1 || { cb_ok=false; echo "    missing file: $f"; }
    done
    grep -rq 'LEAK[0-9]' "$WORK/cbundle/x" && { cb_ok=false; grep -rn 'LEAK[0-9]' "$WORK/cbundle/x" | head -5 | sed 's/^/    | /'; }
    grep -q 'RELEASE_VERSION=2.4.0' "$WORK/cbundle/x"/*/03-images.txt || { cb_ok=false; echo "    RELEASE_VERSION missing"; }
    grep -q 'WEB_HOSTNAME_API' "$WORK/cbundle/x"/*/03-images.txt && { cb_ok=false; echo "    container env beyond RELEASE_VERSION"; }
    grep -qx 'API_JWT_SECRET' "$WORK/cbundle/x"/*/08-env-keys.txt || { cb_ok=false; echo "    .env key names missing"; }
    grep -q 'Support bundle: ' "$WORK/cbundle.log" || { cb_ok=false; echo "    no path printed"; }
fi
if $cb_ok; then
    pass=$((pass + 1)); echo "ok   compose support bundle: every file redacted, .env as key names, RELEASE_VERSION only"
else
    fail=$((fail + 1)); echo "FAIL compose support bundle"; tail -5 "$WORK/cbundle.log" | sed 's/^/    | /'
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
