#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted scripts run in sh -c and in the OpenBao container
# Runs the Runtime's data side for real, isolated from anything else on this
# Docker (its own project, networks, container names and volume; no published
# port), in a throwaway copy of this checkout with a synthetic .env:
#   - runtime-init creates the Runtime's and OpenBao's roles and databases on
#     the bundled Postgres, twice (idempotent); the read grants wait for the
#     tables and then give each reader exactly its columns;
#   - OpenBao starts from the generated files: Postgres storage, static
#     unseal, self-init (KV v2, policies, AppRoles), no root token;
#   - the API's AppRole writes a secret and cannot read it back; the
#     injector's reads it and cannot write;
#   - after a restart OpenBao unseals by itself and still holds the secret;
#   - backup.sh puts the unseal key apart; after the database volume is
#     destroyed, restore.sh brings the vault back and the secret reads again.
# Usage: scripts/runtime/test-openbao.sh   (needs Docker; pulls pgvector and OpenBao)
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
P=krtest$$
export COMPOSE_PROJECT_NAME=$P KODUS_RUNTIME_SKIP_CHOWN=1
cleanup() { # everything of the test's own compose project, by its label
    local f="label=com.docker.compose.project=$P"
    docker ps -aq --filter "$f" | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker volume ls -q --filter "$f" | xargs -r docker volume rm >/dev/null 2>&1 || true
    docker network ls -q --filter "$f" | xargs -r docker network rm >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
[ "${KEEP:-}" = 1 ] || trap cleanup EXIT
(cd "$SRC" && git ls-files -co --exclude-standard -z | grep -zv '^runtime/state/' | xargs -0 tar -cf - --) | tar -C "$TMP" -xf -
cd "$TMP"
cp .env.example .env
UID_GID="$(id -u):$(id -g)"
cat >isolate.yml <<EOF
services:
  db_kodus_postgres:
    container_name: $P-db
    ports: !reset []
  runtime-openbao:
    container_name: $P-openbao
    # The generated files are 0600 and owned by whoever ran generate.sh.
    user: "$UID_GID"
    ports: !reset []
  runtime-init:
    container_name: $P-init
networks:
  shared-network: { external: false, name: $P-shared }
  kodus-backend-services: { external: false, name: $P-backend }
  monitoring-network: { external: false, name: $P-monitoring }
volumes:
  pgdata: { name: $P-pgdata }
  runtime-evidence: { name: $P-evidence }
EOF
export KODUS_RUNTIME_COMPOSE_EXTRA="$TMP/isolate.yml"
d() { printf 'example.invalid/kodus-runtime-%s@sha256:%064d' "$1" 0; }
export KODUS_RUNTIME_HUB_IMAGE KODUS_RUNTIME_WORKER_IMAGE
KODUS_RUNTIME_HUB_IMAGE=$(d hub) KODUS_RUNTIME_WORKER_IMAGE=$(d worker)
./scripts/runtime/install.sh --check --cell-profile docker-gvisor --release unreleased --hub-host hub.example.internal >/dev/null
C=./scripts/runtime/compose.sh

pass=0 fail=0
t() {
    local name=$1
    shift
    if "$@" >"$TMP/out" 2>&1; then
        pass=$((pass + 1)); printf 'ok    %s\n' "$name"
    else
        fail=$((fail + 1)); printf 'FAIL  %s\n' "$name"; sed 's/^/      /' "$TMP/out" | tail -15
    fi
}
# shellcheck source=/dev/null
. ./runtime/state/init.env
PRODUCT_DB=$(grep '^API_PG_DB_DATABASE=' .env | cut -d= -f2)
sql() { # sql USER PASSWORD DB QUERY
    $C exec -T -e PGPASSWORD="$2" db_kodus_postgres psql -h 127.0.0.1 -U "$1" -d "$3" -v ON_ERROR_STOP=1 -Atc "$4"
}
admin() { sql "$(grep '^API_PG_DB_USERNAME=' .env | cut -d= -f2)" "$(grep '^API_PG_DB_PASSWORD=' .env | cut -d= -f2)" "$@"; }
refused() { ! "$@"; }

echo "== Postgres roles and databases"
t "the bundled Postgres starts" $C up -d --wait db_kodus_postgres
t "runtime-init roles" env RUNTIME_INIT_MODE=roles $C run --rm runtime-init
t "runtime-init roles again (idempotent)" env RUNTIME_INIT_MODE=roles $C run --rm runtime-init
t "grants wait for the tables (exit 3)" sh -c "RUNTIME_INIT_MODE=grants $C run --rm runtime-init; [ \$? = 3 ]"
# The tables the hub's first boot and the API's migration would create.
sql kodus_runtime "$RUNTIME_PG_PASSWORD" kodus_runtime "CREATE SCHEMA IF NOT EXISTS runtime; CREATE TABLE IF NOT EXISTS runtime.runtime_runs (id text); CREATE TABLE IF NOT EXISTS runtime.runtime_claims (id text, state text)" >/dev/null
admin "$PRODUCT_DB" "CREATE TABLE IF NOT EXISTS public.runtime_secrets (organization_id text, secret_id text, name text, hosts text[], created_by text)" >/dev/null
t "grants apply once the tables exist" env RUNTIME_INIT_MODE=grants $C run --rm runtime-init
t "reader: SELECT on the Run projection" sql kodus_runtime_reader "$RUNTIME_READER_PG_PASSWORD" kodus_runtime "SELECT count(*) FROM runtime.runtime_runs"
t "reader: no write" refused sql kodus_runtime_reader "$RUNTIME_READER_PG_PASSWORD" kodus_runtime "INSERT INTO runtime.runtime_runs VALUES ('x')"
t "secrets reader: id, name and hosts" sql kodus_runtime_secrets_reader "$RUNTIME_SECRETS_READER_PG_PASSWORD" "$PRODUCT_DB" "SELECT organization_id, secret_id, name, hosts FROM runtime_secrets"
t "secrets reader: no other column" refused sql kodus_runtime_secrets_reader "$RUNTIME_SECRETS_READER_PG_PASSWORD" "$PRODUCT_DB" "SELECT created_by FROM runtime_secrets"
t "Runtime owner: no product table" refused sql kodus_runtime "$RUNTIME_PG_PASSWORD" "$PRODUCT_DB" "SELECT name FROM runtime_secrets"
t "openbao role: no Runtime database" refused sql openbao "$RUNTIME_OPENBAO_PG_PASSWORD" kodus_runtime "SELECT 1"
t "live-claims mode counts claims" sh -c "[ \"\$(RUNTIME_INIT_MODE=live-claims $C run --rm -T runtime-init | tr -d '[:space:]')\" = 0 ]"

echo "== OpenBao"
t "OpenBao starts unsealed and self-initialized" $C up -d --wait runtime-openbao
STATE_DIR="$TMP/runtime/state"
OB_IMAGE=$(grep '^KODUS_RUNTIME_OPENBAO_IMAGE=' runtime/state/compose.env | cut -d= -f2)
bao() { # bao ROLE SCRIPT: a one-off OpenBao CLI on the test network as ROLE (api|injector)
    docker run --rm --network "$P-backend" --user "$UID_GID" -e BAO_ADDR=https://runtime-openbao:8200 -e BAO_CACERT=/ca.pem \
        -v "$STATE_DIR/openbao/ca.pem:/ca.pem:ro" -v "$STATE_DIR/openbao/server/$1-role-id:/role-id:ro" \
        -v "$STATE_DIR/openbao/server/$1-secret-id:/secret-id:ro" --entrypoint sh "$OB_IMAGE" -c \
        'export BAO_TOKEN=$(bao write -field=token auth/approle/login role_id=@/role-id secret_id=@/secret-id) && '"$2"
}
# The injector's read: GET /v1/<mount>/data/... and the record's value.
read_value() { bao injector "bao read -format=json -field=data $P_SECRET" 2>/dev/null | sed -n 's/.*"value": *"\([^"]*\)".*/\1/p'; }
VALUE=synthetic-$(openssl rand -hex 8)
REC='{"data":{"value":"'"$VALUE"'","hosts":["registry.example.com"],"organizationId":"org-test","secretId":"npm_token"}}'
P_SECRET=runtime-kv/data/orgs/org-test/secrets/npm_token
t "API AppRole writes a secret" bao api "echo '$REC' | bao write $P_SECRET -"
t "API AppRole cannot read it back" refused bao api "bao read $P_SECRET"
t "injector AppRole reads the value" sh -c '[ "$1" = "$2" ]' _ "$(read_value)" "$VALUE"
t "injector AppRole cannot write" refused bao injector "echo '$REC' | bao write $P_SECRET -"
docker logs "$P-openbao" 2>&1 | grep -i 'root token' | sed 's/^/      log: /' || true
t "no root token printed by OpenBao" sh -c "! docker logs $P-openbao 2>&1 | grep -Eqi 'initial root token|root token: '"
t "OpenBao restarts and unseals by itself" sh -c "$C restart runtime-openbao >/dev/null && $C up -d --wait runtime-openbao"
t "the secret survives the restart (Postgres storage)" sh -c '[ "$1" = "$2" ]' _ "$(read_value)" "$VALUE"

echo "== backup, disaster, restore"
mkdir -p "$TMP/backup" "$TMP/keys"
t "backup.sh refuses the key next to the dumps" refused ./scripts/runtime/backup.sh --out "$TMP/backup" --unseal-key-out "$TMP/backup/unseal.key"
t "backup.sh" ./scripts/runtime/backup.sh --out "$TMP/backup" --unseal-key-out "$TMP/keys/unseal.key"
t "the state archive holds no unseal key" sh -c "! tar -tzf $TMP/backup/runtime-state.tar.gz | grep -q unseal.key"
t "the unseal key is 32 bytes, apart" sh -c "[ \$(wc -c <$TMP/keys/unseal.key | tr -d ' ') = 32 ]"
$C down -v >/dev/null 2>&1
rm -rf runtime/state
# Restored on another path, as on a new machine (and so no bind mount of the
# old directory is reused).
export KODUS_RUNTIME_STATE="$TMP/restored-state" STATE_DIR="$TMP/restored-state"
t "restore.sh into an empty Postgres" ./scripts/runtime/restore.sh --from "$TMP/backup" --unseal-key "$TMP/keys/unseal.key"
up_or_logs() { $C up -d --wait runtime-openbao || { docker logs --tail 25 "$P-openbao" 2>&1; return 1; }; }
t "OpenBao starts on the restored vault" up_or_logs
t "the secret reads again after restore" sh -c '[ "$1" = "$2" ]' _ "$(read_value)" "$VALUE"
t "the Runtime database came back" sql kodus_runtime_reader "$RUNTIME_READER_PG_PASSWORD" kodus_runtime "SELECT count(*) FROM runtime.runtime_runs"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
