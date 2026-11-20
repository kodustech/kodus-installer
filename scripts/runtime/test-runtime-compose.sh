#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted scripts run in sh -c
# Tests the Runtime's compose layer without starting anything, in a throwaway
# copy of this checkout with a synthetic .env (from .env.example) and
# synthetic image digests. Never touches this checkout's .env or runtime/state.
#   1. `docker compose config -q` passes for the product alone, the analytics
#      profile, and the Runtime with each cell profile (and with analytics);
#   2. the merged config gives the API and the worker the Runtime env after
#      .env, the hub its mTLS files, the worker its client certificate only;
#   3. no generated secret appears in a tracked file;
#   4. install.sh refuses an unpublished image, a floating release and an
#      unknown profile, each with its reason.
# Usage: scripts/runtime/test-runtime-compose.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
(cd "$SRC" && git ls-files -co --exclude-standard -z | grep -zv '^runtime/state/' | xargs -0 tar -cf - --) | tar -C "$TMP" -xf -
cd "$TMP"
cp .env.example .env
sed -i.bak -e 's/^IMAGE_TAG=.*//' .env && rm -f .env.bak
export KODUS_RUNTIME_SKIP_CHOWN=1

pass=0 fail=0
t() { # t NAME CMD...: one assertion
    local name=$1
    shift
    if "$@" >"$TMP/out" 2>&1; then
        pass=$((pass + 1))
        printf 'ok    %s\n' "$name"
    else
        fail=$((fail + 1))
        printf 'FAIL  %s\n' "$name"
        sed 's/^/      /' "$TMP/out" | tail -15
    fi
}
fails_with() { # fails_with TEXT CMD...: the command fails and says TEXT
    local text=$1 out
    shift
    if out=$("$@" 2>&1); then
        echo "succeeded, expected a failure naming: $text"
        return 1
    fi
    printf '%s\n' "$out" | grep -qF -- "$text" || { printf 'failed without "%s":\n%s\n' "$text" "$out"; return 1; }
}

d() { printf 'example.invalid/kodus-runtime-%s@sha256:%064d' "$1" 0; }
export KODUS_RUNTIME_HUB_IMAGE KODUS_RUNTIME_WORKER_IMAGE
KODUS_RUNTIME_HUB_IMAGE=$(d hub)
KODUS_RUNTIME_WORKER_IMAGE=$(d worker)

base=(docker compose --env-file .env -f docker-compose.yml)
t "product alone: config -q" "${base[@]}" config -q
t "product, analytics profile: config -q" "${base[@]}" --profile analytics config -q

for p in docker-gvisor docker-firecracker kubernetes; do
    t "install.sh --check --cell-profile $p" ./scripts/runtime/install.sh --check --cell-profile "$p" --release unreleased \
        --hub-host runtime.example.internal --openbao-host 10.20.30.40 --evidence-url https://runtime-evidence.example.internal
    t "runtime ($p): config -q" ./scripts/runtime/compose.sh config -q
    t "runtime ($p) + analytics: config -q" ./scripts/runtime/compose.sh --profile analytics config -q
    t "runtime ($p): compose.env names the profile" grep -qx "KODUS_RUNTIME_CELL_PROFILE=$p" runtime/state/compose.env
done

./scripts/runtime/compose.sh config --format json >"$TMP/config.json"
j() { jq -e "$1" "$TMP/config.json" >/dev/null; }
t "api: keeps .env and adds the Runtime env" j '.services.api.environment.API_PG_DB_HOST == "db_kodus_postgres" and .services.api.environment.RUNTIME_ENABLED == "true"'
t "api: Runtime env present" j '.services.api.environment.RUNTIME_SANDBOX_URL == "http://runtime-worker:3430" and .services.api.environment.RUNTIME_OPENBAO_ADDR == "https://runtime-openbao:8200"'
t "api: OpenBao AppRole files mounted read-only" j '[.services.api.volumes[] | select(.target | startswith("/runtime/openbao/")) | .read_only] | length == 3 and all'
t "worker: Runtime env present, no OpenBao" j '.services.worker.environment.RUNTIME_ENABLED == "true" and (.services.worker.environment | has("RUNTIME_OPENBAO_ADDR") | not)'
t "SANDBOX_PROVIDER left to .env by default" j '.services.api.environment.SANDBOX_PROVIDER == "local"'
t "hub: production mTLS settings" j '.services["runtime-hub"].environment | .RUNTIME_TLS_WORKER_CA and .RUNTIME_WORKER_ALLOWED_CNS == "runtime-worker" and (has("RUNTIME_DEV_ALLOW_INSECURE_CELLS") | not)'
t "worker: a fixed DBOS executor id and a release version (the production image refuses to start without them)" j '.services["runtime-worker"].environment | (.RUNTIME_EXECUTOR_ID | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") and . != "local") and (.RUNTIME_RELEASE_VERSION | length > 0)'
t "worker: no CA key mounted" j '[.services["runtime-worker"].volumes[] | select(.target == "/runtime/pki/ca.key")] | length == 0'
t "hub, worker, openbao: images by digest" j '[.services["runtime-hub","runtime-worker","runtime-openbao"].image | test("@sha256:[0-9a-f]{64}$")] | all'
t "openbao: IPC_LOCK, bound to loopback by default" j '(.services["runtime-openbao"].cap_add | index("IPC_LOCK")) and .services["runtime-openbao"].ports[0].host_ip == "127.0.0.1"'

./scripts/runtime/generate.sh --sandbox-provider runtime >/dev/null
./scripts/runtime/compose.sh config --format json >"$TMP/config2.json"
t "--sandbox-provider runtime overrides .env" jq -e '.services.api.environment.SANDBOX_PROVIDER == "runtime" and .services.worker.environment.SANDBOX_PROVIDER == "runtime"' "$TMP/config2.json"

# Compose loads docker-compose.override.yml only without -f: an operator's pin of
# the API image (a product build that carries the Runtime) must still hold.
printf 'services:\n  api:\n    image: example.invalid/kodus-api-pin:test\n' >docker-compose.override.yml
./scripts/runtime/compose.sh config --format json >"$TMP/config3.json"
t "docker-compose.override.yml pins the API image in the Runtime layering" jq -e '.services.api.image == "example.invalid/kodus-api-pin:test" and .services.api.environment.RUNTIME_ENABLED == "true"' "$TMP/config3.json"
rm -f docker-compose.override.yml
./scripts/runtime/compose.sh config --format json | jq -e '.services.api.image != "example.invalid/kodus-api-pin:test"' >/dev/null || { echo "FAIL override leaked"; exit 1; }

no_secret_tracked() {
    local v
    while IFS='=' read -r _ v; do
        [ -n "$v" ] || continue
        if (cd "$SRC" && git ls-files -co --exclude-standard | grep -v '^runtime/state/' | xargs grep -lF -- "$v" 2>/dev/null); then
            echo "a generated value is in a tracked file"
            return 1
        fi
    done <runtime/state/secrets.env
}
t "no generated secret in a tracked file" no_secret_tracked
t "state files are 0600" sh -c '! find runtime/state -type f ! -perm 600 | grep -q .'
t "unseal key is 32 bytes" sh -c '[ "$(wc -c <runtime/state/openbao/server/unseal.key | tr -d " ")" = 32 ]'
before=$(openssl dgst -sha256 -r runtime/state/openbao/server/unseal.key runtime/state/secrets.env runtime/state/pki/ca.key)
./scripts/runtime/generate.sh >/dev/null
after=$(openssl dgst -sha256 -r runtime/state/openbao/server/unseal.key runtime/state/secrets.env runtime/state/pki/ca.key)
t "re-running generate keeps the unseal key, secrets and CA" test "$before" = "$after"
t "hub certificate names the hub host" sh -c 'openssl x509 -in runtime/state/pki/hub.pem -noout -ext subjectAltName | grep -q "DNS:runtime.example.internal"'
t "hub certificate chains to the Runtime CA" openssl verify -CAfile runtime/state/pki/ca.pem runtime/state/pki/hub.pem
t "OpenBao certificate names the cell-facing address" sh -c 'openssl x509 -in runtime/state/openbao/tls.pem -noout -ext subjectAltName | grep -q "IP Address:10.20.30.40"'
t "worker certificate is from the worker CA, not the cells' CA" sh -c 'openssl verify -CAfile runtime/state/pki/worker-ca.pem runtime/state/pki/worker.pem && ! openssl verify -CAfile runtime/state/pki/ca.pem runtime/state/pki/worker.pem'
t "cell-host bundle holds no CA key" sh -c '! grep -rl "PRIVATE KEY" runtime/state/cell-host'

unset KODUS_RUNTIME_HUB_IMAGE
t "install.sh refuses an unpublished hub image" fails_with "the 'hub' image of release 'unreleased' is not published" \
    ./scripts/runtime/install.sh --check --cell-profile docker-gvisor --release unreleased
KODUS_RUNTIME_HUB_IMAGE=$(d hub)
t "install.sh refuses a floating release" fails_with "pin the product release" \
    env -u KODUS_RUNTIME_RELEASE ./scripts/runtime/install.sh --check --cell-profile docker-gvisor --release latest
t "install.sh refuses an unknown profile" fails_with "unknown cell profile 'docker-kata'" \
    ./scripts/runtime/install.sh --check --cell-profile docker-kata --release unreleased
t "install.sh refuses a release with no row" fails_with "is not in compatibility.tsv" \
    ./scripts/runtime/install.sh --check --cell-profile docker-gvisor --release 2.2.10

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
