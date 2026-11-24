#!/usr/bin/env bash
# scripts/collect-diagnostics-compose.sh
# Collects a redacted support bundle for a Docker Compose install, the
# counterpart of collect-diagnostics.sh (Helm). Read-only: it inspects the host,
# the containers and the logs, and changes nothing.
#
# Usage: ./scripts/collect-diagnostics-compose.sh [-o output-dir]
#   Writes kodus-diagnostics-compose-<stamp>.tar.gz to output-dir
#   (default: $TMPDIR or /tmp) and prints its path.
#
# What it never collects: .env values (key names only), `docker inspect` or
# `docker compose config` output (both carry every env value). Every file goes
# through scripts/redact-lib.sh, which also replaces any secret value of .env
# found anywhere in the bundle.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/redact-lib.sh
. "$SCRIPT_DIR/redact-lib.sh"

OUT_DIR="${TMPDIR:-/tmp}"
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUT_DIR="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 [-o output-dir]"; exit 0 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$PWD/$OUT_DIR" ;; esac
# Fail now, not after a minute of collecting: tar cannot create the directory.
mkdir -p "$OUT_DIR" 2>/dev/null || { echo "Cannot create the output directory $OUT_DIR"; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "docker compose not found"; exit 1
fi
# The compose project and .env live in the installer root.
cd "$ROOT_DIR" || exit 1

# The bundle is for support, not for other users of this machine.
umask 077
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo bundle)
OUT="kodus-diagnostics-compose-${STAMP}"
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/kodus-diagnostics.XXXXXX") || exit 1
trap 'rm -rf "$WORKDIR"' EXIT
DIR="$WORKDIR/$OUT"
mkdir -p "$DIR/logs"

# Secret values of .env, so they are replaced wherever they show up (a password
# echoed in a database log, a key in a provider error). Same names the
# validator masks, plus the secrets the installer generates.
export KODUS_REDACT_VALUES_FILE="$WORKDIR/.values"
: > "$KODUS_REDACT_VALUES_FILE"
if [ -f .env ]; then
    autogen=""
    if [ -f "$SCRIPT_DIR/schema-vars.sh" ]; then
        # shellcheck source=scripts/schema-vars.sh
        . "$SCRIPT_DIR/schema-vars.sh"
        autogen=" $(printf '%s\n' ${KODUS_AUTOGEN_SECRETS[@]+"${KODUS_AUTOGEN_SECRETS[@]}"} | cut -d= -f1 | tr '\n' ' ') "
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"
        line=${line#export }
        case "$line" in [A-Za-z_]*=*) ;; *) continue ;; esac
        key=${line%%=*}; value=${line#*=}
        case "$value" in
            \"*) value=${value#\"}; value=${value%%\"*} ;;
            \'*) value=${value#\'}; value=${value%%\'*} ;;
            *) value=${value%%#*}; value="${value%"${value##*[![:space:]]}"}" ;;
        esac
        case "$key" in
            *PASSWORD|*PASSWD|*PASS|*PWD|*SECRET|*KEY|*TOKEN|*DSN|*URI|*CREDENTIAL|*CREDENTIALS|*PRIVATE) ;;
            *) case "$autogen" in *" $key "*) ;; *) continue ;; esac ;;
        esac
        [ ${#value} -ge 8 ] && printf '%s\n' "$value" >> "$KODUS_REDACT_VALUES_FILE"
    done < .env
fi

redact() { kodus_redact; }
# section <file> <title> <command...>: appends the command's redacted output.
section() {
    local file=$1 title=$2; shift 2
    { echo "== $title"; "$@" 2>&1; echo; } | redact >> "$DIR/$file"
}
env_value() { # a non-secret value of .env (IMAGE_TAG...), quotes stripped
    [ -f .env ] || return 0
    sed -n "s/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}$1=//p" .env | tail -1 | sed "s/^[\"']//; s/[\"'][[:space:]]*\$//; s/[[:space:]]*#.*\$//"
}

echo "Collecting into $DIR ..."

# --- Host --------------------------------------------------------------------
host_info() {
    date -u
    uname -srvm
    [ -f /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
    echo "CPUs: $(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
    if [ -r /proc/meminfo ]; then
        grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
    else
        echo "MemTotal: $(sysctl -n hw.memsize 2>/dev/null) bytes"
    fi
    local docker_root
    docker_root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
    echo; echo "Disk (/ and the docker root ${docker_root:-?}):"
    df -h / ${docker_root:+"$docker_root"} 2>/dev/null
}
section 00-host.txt "Host" host_info

# --- Docker --------------------------------------------------------------------
section 01-docker.txt "docker version" docker version
section 01-docker.txt "compose version" $DC version
section 01-docker.txt "docker info (selected fields)" docker info -f \
    'ServerVersion={{.ServerVersion}} Driver={{.Driver}} CgroupVersion={{.CgroupVersion}} OS={{.OperatingSystem}} Kernel={{.KernelVersion}} NCPU={{.NCPU}} MemTotal={{.MemTotal}} DockerRootDir={{.DockerRootDir}}'

# --- Installer -----------------------------------------------------------------
installer_info() {
    echo "installer: $ROOT_DIR"
    if git -C "$ROOT_DIR" rev-parse HEAD >/dev/null 2>&1; then
        echo "git: $(git -C "$ROOT_DIR" rev-parse HEAD) ($(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"
        echo "files changed from that commit: $(git -C "$ROOT_DIR" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')"
    else
        echo "git: not a git checkout"
    fi
    echo "IMAGE_TAG=$(env_value IMAGE_TAG)"
    echo "KODUS_REGISTRY=$(env_value KODUS_REGISTRY)"
    echo "KODUS_MONGO_IMAGE=$(env_value KODUS_MONGO_IMAGE)"
    echo "COMPOSE_PROFILES=${COMPOSE_PROFILES:-$(env_value COMPOSE_PROFILES)}"
}
section 02-installer.txt "Installer" installer_info

# --- Containers ------------------------------------------------------------------
services=$($DC config --services 2>/dev/null)
project=""
containers_info() {
    local svc cid image_id
    for svc in $services; do
        cid=$($DC ps -a -q "$svc" 2>/dev/null | head -1)
        if [ -z "$cid" ]; then echo "$svc: no container"; continue; fi
        # Explicit fields only: a raw inspect carries every env value.
        docker inspect -f "$svc: {{.Name}} image={{.Config.Image}}" "$cid" 2>/dev/null
        image_id=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)
        echo "    image id: $image_id"
        echo "    digests: $(docker image inspect -f '{{join .RepoDigests " "}}' "$image_id" 2>/dev/null)"
        echo "    $(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null | grep '^RELEASE_VERSION=' || echo 'RELEASE_VERSION not set')"
    done
}
container_state() {
    local svc cid
    for svc in $services; do
        cid=$($DC ps -a -q "$svc" 2>/dev/null | head -1)
        [ -n "$cid" ] || continue
        docker inspect -f "$svc: status={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} oomKilled={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} error={{.State.Error}}" "$cid" 2>/dev/null
    done
}
for svc in $services; do
    cid=$($DC ps -a -q "$svc" 2>/dev/null | head -1)
    [ -n "$cid" ] || continue
    project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null)
    [ -n "$project" ] && break
done
[ -n "$project" ] || project=${COMPOSE_PROJECT_NAME:-$(basename "$ROOT_DIR" | tr '[:upper:]' '[:lower:]')}
section 03-images.txt "Images and versions" containers_info
section 04-ps.txt "docker compose ps -a" $DC ps -a
section 05-state.txt "Container state" container_state
# Lifecycle events only: the health-check execs would fill the file. The
# daemon keeps just its last 256 events, so on a busy host "24h" is minutes.
section 06-events.txt "docker events of project $project (--since 24h; the daemon keeps only its last 256 events)" \
    docker events --since 24h --until "$(date +%s)" --filter "label=com.docker.compose.project=$project" \
        --filter event=create --filter event=start --filter event=restart --filter event=die \
        --filter event=oom --filter event=kill --filter event=stop --filter event=destroy --filter event=health_status

# --- Logs ------------------------------------------------------------------------
for svc in $services; do
    $DC logs --no-color --tail 500 "$svc" 2>&1 | redact > "$DIR/logs/$svc.log"
done
# Pino levels (warn=40, error=50, fatal=60) or plain labels, as in the Helm bundle.
grep -rHaE '"level":(4[0-9]|5[0-9]|6[0-9])|\b(ERROR|WARN|WARNING|FATAL|Error|error)\b|HttpError|Unhandled' "$DIR/logs" 2>/dev/null \
    | grep -viE '/health' | sed "s#^$DIR/logs/##" | tail -800 | redact > "$DIR/07-errors-warnings.txt"

# --- Configuration -----------------------------------------------------------------
env_keys() {
    [ -f .env ] || { echo ".env not found"; return; }
    echo "# .env key names (values intentionally omitted)"
    sed -n 's/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' .env | sort
}
section 08-env-keys.txt ".env" env_keys
run_validate_env() { "$SCRIPT_DIR/validate-env.sh" | kodus_strip_ansi; }
[ -x "$SCRIPT_DIR/validate-env.sh" ] && section 09-validate-env.txt "validate-env.sh" run_validate_env

# --- RabbitMQ (bundled broker only) --------------------------------------------------
if [ -n "$($DC ps -q rabbitmq 2>/dev/null)" ]; then
    section 10-rabbitmq.txt "status" $DC exec -T rabbitmq rabbitmq-diagnostics -q status
    section 10-rabbitmq.txt "check_alarms" $DC exec -T rabbitmq rabbitmq-diagnostics -q check_alarms
    section 10-rabbitmq.txt "list_feature_flags" $DC exec -T rabbitmq rabbitmqctl -q list_feature_flags
    for vhost in $($DC exec -T rabbitmq rabbitmqctl -q list_vhosts 2>/dev/null | tr -d '\r' | grep -v '^name$'); do
        section 10-rabbitmq.txt "list_queues -p $vhost name messages consumers" \
            $DC exec -T rabbitmq rabbitmqctl -q list_queues -p "$vhost" name messages consumers
    done
else
    echo "no bundled rabbitmq container running" > "$DIR/10-rabbitmq.txt"
fi

# --- Doctor ----------------------------------------------------------------------
echo "Running the doctor (the review checks can take a few minutes) ..."
[ -x "$SCRIPT_DIR/doctor.sh" ] && "$SCRIPT_DIR/doctor.sh" --verbose 2>&1 | kodus_strip_ansi | redact > "$DIR/11-doctor.txt"
if [ -n "$($DC ps -q api 2>/dev/null)" ]; then
    # Already redacted by the app (doctor-report.ts); the redactor runs anyway.
    $DC exec -T api node scripts/doctor/doctor-client.mjs --format json 2>&1 | redact > "$DIR/12-api-doctor.json"
else
    echo "api not running" > "$DIR/12-api-doctor.json"
fi

# Every file, once more: whatever a step above wrote unfiltered is caught here.
kodus_redact_tree "$DIR"

TARBALL="${OUT_DIR%/}/${OUT}.tar.gz"
if ! tar -czf "$TARBALL" -C "$WORKDIR" "$OUT"; then
    echo "Could not write $TARBALL"; exit 1
fi
echo ""
echo "Support bundle: $TARBALL"
echo "Secret values are redacted, but check what is inside before you share it: tar -xzf $TARBALL"
