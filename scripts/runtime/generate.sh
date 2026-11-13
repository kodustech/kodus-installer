#!/usr/bin/env bash
# Generates everything the Kody Runtime control plane needs that is secret or
# host-specific, into the state directory (runtime/state by default,
# KODUS_RUNTIME_STATE to move it). Never prints a value, never writes into a
# tracked file. Safe to re-run: what must survive (passwords, the sealing key,
# the CAs, OpenBao's unseal key and AppRole ids) is generated once; the env
# files and the pgpass are derived again from it and from .env on every run,
# and leaf certificates are re-issued when missing, expiring within 30 days,
# when their names changed, or with --rotate-certs.
#
#   settings.env        non-secret: hub host, binds, public evidence URL, Git API
#   secrets.env         every generated password and key (source of the rest)
#   hub.env, runtime-worker.env, product-api.env, product-worker.env, init.env
#   pki/                Runtime CA (hub certificate, enrolled cells), worker CA,
#                       the hub's and the worker's certificates
#   openbao/            OpenBao's CA; server/: TLS, unseal.key, AppRole ids,
#                       pgpass; policies/ (the injector's narrowed with --injector-org)
#   cell-host/          what a cell host needs from here (hub CA, OpenBao CA,
#                       the injector's AppRole, addresses): copy it to the host
#
# Usage: scripts/runtime/generate.sh --hub-host <name or IP cells reach> [options]
#   --openbao-host <name or IP>   where cell hosts reach OpenBao (default: hub host)
#   --evidence-url <url>          public URL of the evidence server
#                                 (default http://<hub-host>:3420)
#   --git-api <url>               the Git API cells download from (default https://api.github.com)
#   --hub-bind / --openbao-bind / --evidence-bind <address>
#   --injector-org <organizationId>  narrow the injector's policy to one org
#                                 (only before OpenBao's first start)
#   --sandbox-provider runtime|unset  set SANDBOX_PROVIDER=runtime for the API
#                                 and worker (the review's sandbox on a cell);
#                                 unset leaves .env's choice (default)
#   --rotate-certs                re-issue every leaf certificate
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'; }

ENV_FILE="${KODUS_ENV_FILE:-$RT_ROOT/.env}"
ROTATE=0
SET_HUB_HOST='' SET_OPENBAO_HOST='' SET_EVIDENCE_URL='' SET_GIT_API='' SET_INJECTOR_ORG=''
SET_HUB_BIND='' SET_OPENBAO_BIND='' SET_EVIDENCE_BIND='' SET_SANDBOX=''
while [ $# -gt 0 ]; do
    case "$1" in
        --hub-host) SET_HUB_HOST=${2:?}; shift 2 ;;
        --openbao-host) SET_OPENBAO_HOST=${2:?}; shift 2 ;;
        --evidence-url) SET_EVIDENCE_URL=${2:?}; shift 2 ;;
        --git-api) SET_GIT_API=${2:?}; shift 2 ;;
        --injector-org) SET_INJECTOR_ORG=${2:?}; shift 2 ;;
        --hub-bind) SET_HUB_BIND=${2:?}; shift 2 ;;
        --openbao-bind) SET_OPENBAO_BIND=${2:?}; shift 2 ;;
        --evidence-bind) SET_EVIDENCE_BIND=${2:?}; shift 2 ;;
        --sandbox-provider) SET_SANDBOX=${2:?}; shift 2 ;;
        --rotate-certs) ROTATE=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) rt_die "unknown option $1 (see --help)" ;;
    esac
done

rt_require_cmds openssl awk sed grep
[ -f "$ENV_FILE" ] || rt_die "$ENV_FILE not found: the product install comes first (docs/compose.md)"

if [ "$(id -u)" = 0 ]; then
    OWNER=root
elif [ "$(id -u)" = 1000 ] || [ "${KODUS_RUNTIME_SKIP_CHOWN:-}" = 1 ]; then
    OWNER=self
else
    rt_die "run as root (sudo) or as uid 1000: the Runtime and product containers read these files as uid 1000"
fi

umask 077
mkdir -p "$RT_STATE"/pki "$RT_STATE"/openbao/server "$RT_STATE"/openbao/policies "$RT_STATE"/cell-host
chmod 700 "$RT_STATE" "$RT_STATE"/pki "$RT_STATE"/openbao "$RT_STATE"/openbao/server "$RT_STATE"/openbao/policies "$RT_STATE"/cell-host

# --- settings (non-secret, persisted) ---------------------------------------
SETTINGS="$RT_STATE/settings.env"
keep() { # keep NAME NEW DEFAULT: the flag, else the stored value, else the default
    local v=$2
    [ -n "$v" ] || v=$(rt_env_get "$SETTINGS" "$1")
    [ -n "$v" ] || v=$3
    printf '%s' "$v"
}
HUB_HOST=$(keep RUNTIME_HUB_HOST "$SET_HUB_HOST" '')
[ -n "$HUB_HOST" ] || rt_die "--hub-host is required on the first run: the name or IP address cell hosts use to reach the hub"
OPENBAO_HOST=$(keep RUNTIME_OPENBAO_HOST "$SET_OPENBAO_HOST" "$HUB_HOST")
EVIDENCE_URL=$(keep RUNTIME_EVIDENCE_PUBLIC_URL "$SET_EVIDENCE_URL" "http://$HUB_HOST:3420")
GIT_API=$(keep RUNTIME_GIT_API_BASE "$SET_GIT_API" "https://api.github.com")
INJECTOR_ORG=$(keep RUNTIME_INJECTOR_ORG "$SET_INJECTOR_ORG" '')
HUB_BIND=$(keep RUNTIME_HUB_BIND "$SET_HUB_BIND" 0.0.0.0)
OPENBAO_BIND=$(keep RUNTIME_OPENBAO_BIND "$SET_OPENBAO_BIND" 127.0.0.1)
EVIDENCE_BIND=$(keep RUNTIME_EVIDENCE_BIND "$SET_EVIDENCE_BIND" 0.0.0.0)
SANDBOX=$(keep RUNTIME_SANDBOX_PROVIDER "$SET_SANDBOX" unset)
case "$SANDBOX" in runtime | unset) ;; *) rt_die "--sandbox-provider must be runtime or unset" ;; esac
case "$EVIDENCE_URL" in http://* | https://*) ;; *) rt_die "--evidence-url must be an http(s) URL" ;; esac
case "$GIT_API" in https://*) ;; *) rt_die "--git-api must be an https URL" ;; esac
cat >"$SETTINGS" <<EOF
RUNTIME_HUB_HOST=$HUB_HOST
RUNTIME_OPENBAO_HOST=$OPENBAO_HOST
RUNTIME_EVIDENCE_PUBLIC_URL=$EVIDENCE_URL
RUNTIME_GIT_API_BASE=$GIT_API
RUNTIME_INJECTOR_ORG=$INJECTOR_ORG
RUNTIME_HUB_BIND=$HUB_BIND
RUNTIME_OPENBAO_BIND=$OPENBAO_BIND
RUNTIME_EVIDENCE_BIND=$EVIDENCE_BIND
RUNTIME_SANDBOX_PROVIDER=$SANDBOX
EOF

# --- generated once ---------------------------------------------------------
SECRETS="$RT_STATE/secrets.env"
touch "$SECRETS"
secret() { # secret NAME: generated once, kept across runs and upgrades
    local v
    v=$(rt_env_get "$SECRETS" "$1")
    if [ -z "$v" ]; then
        v=$(openssl rand -hex 32)
        printf '%s=%s\n' "$1" "$v" >>"$SECRETS"
    fi
    printf '%s' "$v"
}
PG_PW=$(secret RUNTIME_PG_PASSWORD)
READER_PW=$(secret RUNTIME_READER_PG_PASSWORD)
SECRETS_READER_PW=$(secret RUNTIME_SECRETS_READER_PG_PASSWORD)
OPENBAO_PG_PW=$(secret RUNTIME_OPENBAO_PG_PASSWORD)
MQ_PW=$(secret RUNTIME_MQ_PASSWORD)
SEAL_KEY=$(secret RUNTIME_SECRET_SEAL_KEY)
RUN_TOKEN_SECRET=$(secret RUNTIME_RUN_TOKEN_SECRET)
EVIDENCE_SECRET=$(secret RUNTIME_EVIDENCE_SIGNING_SECRET)

OB="$RT_STATE/openbao/server"
# The static seal key: losing it loses the vault. Kept apart from the database
# backup (scripts/runtime/backup.sh writes it to its own destination).
[ -s "$OB/unseal.key" ] || openssl rand -out "$OB/unseal.key" 32
for f in api-role-id api-secret-id injector-role-id injector-secret-id; do
    # No trailing newline: OpenBao's self-init reads the file as is. OpenBao
    # registers them at its first start only, so they never change after it.
    [ -s "$OB/$f" ] || openssl rand -hex 24 | tr -d '\n' >"$OB/$f"
done

# --- PKI --------------------------------------------------------------------
key() { openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out "$1"; }
ca() { # ca DIR NAME CN: a CA kept for ten years, generated once
    [ -s "$1/$2.pem" ] && [ -s "$1/$2.key" ] && return 0
    key "$1/$2.key"
    openssl req -x509 -new -key "$1/$2.key" -sha256 -days 3650 -subj "/O=kodus-runtime/CN=$3" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "$1/$2.pem" 2>/dev/null
}
# leaf DIR NAME SUBJECT EKU SAN CA_DIR CA_NAME: a 397-day certificate
leaf() {
    local dir=$1 name=$2 subj=$3 eku=$4 san=$5 cadir=$6 caname=$7 want
    want="$subj|$eku|$san"
    if [ "$ROTATE" = 0 ] && [ -s "$dir/$name.pem" ] && [ -s "$dir/$name.key" ] &&
        [ "$(cat "$dir/.$name.names" 2>/dev/null)" = "$want" ] &&
        openssl x509 -in "$dir/$name.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
        return 0
    fi
    key "$dir/$name.key"
    openssl req -new -key "$dir/$name.key" -subj "$subj" -out "$dir/$name.csr"
    {
        echo "basicConstraints=critical,CA:FALSE"
        echo "keyUsage=critical,digitalSignature"
        echo "extendedKeyUsage=$eku"
        [ -n "$san" ] && echo "subjectAltName=$san"
    } >"$dir/$name.ext"
    openssl x509 -req -in "$dir/$name.csr" -CA "$cadir/$caname.pem" -CAkey "$cadir/$caname.key" -CAcreateserial \
        -sha256 -days 397 -extfile "$dir/$name.ext" -out "$dir/$name.pem" 2>/dev/null
    rm -f "$dir/$name.csr" "$dir/$name.ext" "$cadir/$caname.srl"
    printf '%s' "$want" >"$dir/.$name.names"
}
san_of() { # san_of HOST: DNS: or IP: entry
    if printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+){3}$|:'; then printf 'IP:%s' "$1"; else printf 'DNS:%s' "$1"; fi
}

P="$RT_STATE/pki"
ca "$P" ca "Kody Runtime CA"
ca "$P" worker-ca "Kody Runtime worker CA"
leaf "$P" hub "/O=kodus-runtime/OU=hub/CN=runtime-hub" serverAuth \
    "DNS:runtime-hub,DNS:localhost,IP:127.0.0.1,$(san_of "$HUB_HOST")" "$P" ca
leaf "$P" worker "/O=kodus-runtime/OU=worker/CN=runtime-worker" clientAuth "" "$P" worker-ca

OBCA="$RT_STATE/openbao"
ca "$OBCA" openbao-ca "Kody Runtime OpenBao CA"
cp "$OBCA/openbao-ca.pem" "$OBCA/ca.pem"
leaf "$OBCA" tls "/O=kodus-runtime/OU=openbao/CN=runtime-openbao" serverAuth \
    "DNS:runtime-openbao,DNS:localhost,IP:127.0.0.1,$(san_of "$OPENBAO_HOST")" "$OBCA" openbao-ca
cp "$OBCA/tls.pem" "$OB/tls.pem"
cp "$OBCA/tls.key" "$OB/tls.key"

# --- policies ---------------------------------------------------------------
cp "$RT_DATA/openbao/policies/kodus-runtime-api.hcl" "$RT_STATE/openbao/policies/"
if [ -n "$INJECTOR_ORG" ]; then
    printf '%s' "$INJECTOR_ORG" | grep -Eq '^[A-Za-z0-9-]{1,64}$' || rt_die "--injector-org must be an organization id"
    sed "s|runtime-kv/data/orgs/+/secrets/+|runtime-kv/data/orgs/$INJECTOR_ORG/secrets/+|" \
        "$RT_DATA/openbao/policies/kodus-runtime-injector.hcl" >"$RT_STATE/openbao/policies/kodus-runtime-injector.hcl"
else
    cp "$RT_DATA/openbao/policies/kodus-runtime-injector.hcl" "$RT_STATE/openbao/policies/"
fi

# --- derived from .env and the secrets --------------------------------------
PG_HOST=$(rt_env_get "$ENV_FILE" API_PG_DB_HOST)
PG_PORT=$(rt_env_get "$ENV_FILE" API_PG_DB_PORT)
PRODUCT_DB=$(rt_env_get "$ENV_FILE" API_PG_DB_DATABASE)
MQ_URI=$(rt_env_get "$ENV_FILE" API_RABBITMQ_URI)
[ -n "$PG_HOST" ] || rt_die "API_PG_DB_HOST is not set in .env"
[ -n "$PRODUCT_DB" ] || rt_die "API_PG_DB_DATABASE is not set in .env"
[ -n "$MQ_URI" ] || rt_die "API_RABBITMQ_URI is not set in .env"
PG_PORT=${PG_PORT:-5432}
MQ_SCHEME=${MQ_URI%%://*}
MQ_HOST=$(rt_url_part "$MQ_URI" host)
MQ_PORT=$(rt_url_part "$MQ_URI" port)
MQ_VHOST=$(rt_url_part "$MQ_URI" path)
MQ_PORT=${MQ_PORT:-5672}
[ -n "$MQ_HOST" ] || rt_die "API_RABBITMQ_URI has no host"

PG="$PG_HOST:$PG_PORT"
RT_DB_URL="postgres://kodus_runtime:$PG_PW@$PG/kodus_runtime"
RT_MQ_URL="$MQ_SCHEME://kodus_runtime:$MQ_PW@$MQ_HOST:$MQ_PORT/$MQ_VHOST?heartbeat=60"

cat >"$RT_STATE/hub.env" <<EOF
RUNTIME_DATABASE_URL=$RT_DB_URL
RUNTIME_RABBITMQ_URL=$RT_MQ_URL
RUNTIME_PRODUCT_SECRETS_READ_URL=postgres://kodus_runtime_secrets_reader:$SECRETS_READER_PW@$PG/$PRODUCT_DB
EOF
cat >"$RT_STATE/runtime-worker.env" <<EOF
RUNTIME_DATABASE_URL=$RT_DB_URL
RUNTIME_RABBITMQ_URL=$RT_MQ_URL
RUNTIME_SECRET_SEAL_KEY=$SEAL_KEY
RUNTIME_EVIDENCE_SIGNING_SECRET=$EVIDENCE_SECRET
EOF
# Later env files win in compose: this overrides .env's SANDBOX_PROVIDER.
SANDBOX_PROVIDER_LINE='# SANDBOX_PROVIDER: as in .env (generate.sh --sandbox-provider runtime to move it to the cell)'
[ "$SANDBOX" = runtime ] && SANDBOX_PROVIDER_LINE="SANDBOX_PROVIDER=runtime"
cat >"$RT_STATE/product-api.env" <<EOF
RUNTIME_ENABLED=true
RUNTIME_DATABASE_READ_URL=postgres://kodus_runtime_reader:$READER_PW@$PG/kodus_runtime
RUNTIME_STREAM_STORE=postgres
RUNTIME_RUN_TOKEN_SECRET=$RUN_TOKEN_SECRET
RUNTIME_SECRET_SEAL_KEY=$SEAL_KEY
RUNTIME_ENV_SESSION_URL=http://runtime-worker:3430
RUNTIME_SANDBOX_URL=http://runtime-worker:3430
RUNTIME_EVIDENCE_STORE=file
RUNTIME_EVIDENCE_BASE_URL=$EVIDENCE_URL
RUNTIME_EVIDENCE_SIGNING_SECRET=$EVIDENCE_SECRET
RUNTIME_EVIDENCE_URL_TTL_SECONDS=300
RUNTIME_OPENBAO_ADDR=https://runtime-openbao:8200
RUNTIME_OPENBAO_MOUNT=runtime-kv
RUNTIME_OPENBAO_CA_FILE=/runtime/openbao/ca.pem
RUNTIME_OPENBAO_ROLE_ID_FILE=/runtime/openbao/api-role-id
RUNTIME_OPENBAO_SECRET_ID_FILE=/runtime/openbao/api-secret-id
$SANDBOX_PROVIDER_LINE
EOF
cat >"$RT_STATE/product-worker.env" <<EOF
RUNTIME_ENABLED=true
RUNTIME_DATABASE_READ_URL=postgres://kodus_runtime_reader:$READER_PW@$PG/kodus_runtime
RUNTIME_RUN_TOKEN_SECRET=$RUN_TOKEN_SECRET
RUNTIME_SECRET_SEAL_KEY=$SEAL_KEY
RUNTIME_SANDBOX_URL=http://runtime-worker:3430
$SANDBOX_PROVIDER_LINE
EOF
cat >"$RT_STATE/init.env" <<EOF
RUNTIME_PG_PASSWORD=$PG_PW
RUNTIME_READER_PG_PASSWORD=$READER_PW
RUNTIME_SECRETS_READER_PG_PASSWORD=$SECRETS_READER_PW
RUNTIME_OPENBAO_PG_PASSWORD=$OPENBAO_PG_PW
EOF
# OpenBao's Postgres client (pgx) reads the password from PGPASSFILE.
printf '%s:%s:kodus_openbao:openbao:%s\n' "$PG_HOST" "$PG_PORT" "$OPENBAO_PG_PW" >"$OB/pgpass"

# --- what a cell host needs -------------------------------------------------
CH="$RT_STATE/cell-host"
cp "$P/ca.pem" "$CH/hub-ca.pem"
cp "$OBCA/ca.pem" "$CH/openbao-ca.pem"
cp "$OB/injector-role-id" "$CH/injector-role-id"
cp "$OB/injector-secret-id" "$CH/injector-secret-id"
cat >"$CH/cell-host.conf" <<EOF
# Written by scripts/runtime/generate.sh; read by scripts/runtime/cell-host.sh --bundle.
HUB_URL=wss://$HUB_HOST:3410/cells
OPENBAO_ADDR=https://$OPENBAO_HOST:8200
GIT_API=$GIT_API
EOF
CELL_RELEASE=$(rt_env_get "$RT_STATE/compose.env" KODUS_RUNTIME_CELL_RELEASE)
[ -z "$CELL_RELEASE" ] || printf 'KODUS_RUNTIME_CELL_RELEASE=%s\n' "$CELL_RELEASE" >>"$CH/cell-host.conf"

find "$RT_STATE" -type f -exec chmod 600 {} +
find "$RT_STATE" -type d -exec chmod 700 {} +
if [ "$OWNER" = root ]; then
    chown -R 1000:1000 "$RT_STATE"
fi
rt_ok "Runtime material written to $RT_STATE (values not printed)."
rt_info "Back up $OB/unseal.key apart from the database backups: without it the vault cannot be read."
