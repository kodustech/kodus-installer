#!/usr/bin/env bash
# Runs inside the runtime-init one-shot (docker-compose.runtime.yml), as the
# product's Postgres admin (API_PG_DB_* from .env). Idempotent.
#   RUNTIME_INIT_MODE=roles   the Runtime roles and database, OpenBao's role
#                             and database; the evidence volume's owner
#   RUNTIME_INIT_MODE=grants  the read grants, once the tables exist: the
#                             Runtime's are made by the hub's first boot, the
#                             product's runtime_secrets by the API's migrations.
#                             Exit 3 when either table is not there yet.
#   RUNTIME_INIT_MODE=live-claims  prints the claims pending, bound or held
#   RUNTIME_INIT_MODE=connected-cells  prints the cells connected to the hub
#                             whose heartbeat reports a free slot (a cell
#                             just connected refuses claims until then)
#   RUNTIME_INIT_MODE=dump         pg_dump -Fc of RUNTIME_INIT_DB to stdout
#   RUNTIME_INIT_MODE=restore      pg_restore of stdin into RUNTIME_INIT_DB
#   RUNTIME_INIT_MODE=uninstall    drops the Runtime and OpenBao databases and roles
# Never prints a password.
set -euo pipefail

: "${API_PG_DB_HOST:?API_PG_DB_HOST is not set in .env}"
: "${API_PG_DB_USERNAME:?API_PG_DB_USERNAME is not set in .env}"
: "${API_PG_DB_PASSWORD:?API_PG_DB_PASSWORD is not set in .env}"
: "${API_PG_DB_DATABASE:?API_PG_DB_DATABASE is not set in .env}"
export PGHOST="$API_PG_DB_HOST" PGPORT="${API_PG_DB_PORT:-5432}" PGUSER="$API_PG_DB_USERNAME" PGPASSWORD="$API_PG_DB_PASSWORD"
export PGSSLMODE="${RUNTIME_INIT_PGSSLMODE:-prefer}"
SQL=/runtime/sql

psql_q() { psql -v ON_ERROR_STOP=1 -q -X "$@"; }

for i in $(seq 1 60); do
    pg_isready -q -d postgres && break
    [ "$i" = 60 ] && { echo "runtime-init: Postgres at $PGHOST:$PGPORT does not answer" >&2; exit 1; }
    sleep 2
done

runtime_db() {
    case "${RUNTIME_INIT_DB:-}" in
        kodus_runtime | kodus_openbao) printf '%s' "$RUNTIME_INIT_DB" ;;
        *) echo "runtime-init: RUNTIME_INIT_DB must be kodus_runtime or kodus_openbao" >&2; exit 2 ;;
    esac
}

case "${RUNTIME_INIT_MODE:-roles}" in
    roles)
        : "${RUNTIME_PG_PASSWORD:?}" "${RUNTIME_READER_PG_PASSWORD:?}" "${RUNTIME_SECRETS_READER_PG_PASSWORD:?}" "${RUNTIME_OPENBAO_PG_PASSWORD:?}"
        psql_q -d postgres -v pw_runtime="$RUNTIME_PG_PASSWORD" -v pw_reader="$RUNTIME_READER_PG_PASSWORD" \
            -v pw_secrets="$RUNTIME_SECRETS_READER_PG_PASSWORD" -v product_db="$API_PG_DB_DATABASE" -f "$SQL/runtime-roles.sql"
        psql_q -d postgres -v pw="$RUNTIME_OPENBAO_PG_PASSWORD" -f "$SQL/openbao-database.sql"
        if [ -d /data/runtime-evidence ]; then
            chown 1000:1000 /data/runtime-evidence
        fi
        echo "runtime-init: roles kodus_runtime, kodus_runtime_reader, kodus_runtime_secrets_reader, openbao; databases kodus_runtime, kodus_openbao"
        ;;
    grants)
        runtime_tables=$(psql_q -d kodus_runtime -Atc "SELECT to_regclass('runtime.runtime_runs') IS NOT NULL")
        secrets_table=$(psql_q -d "$API_PG_DB_DATABASE" -Atc "SELECT to_regclass('public.runtime_secrets') IS NOT NULL")
        psql_q -d kodus_runtime -f "$SQL/runtime-reader-grants.sql"
        psql_q -d "$API_PG_DB_DATABASE" -f "$SQL/runtime-secrets-reader-grants.sql"
        if [ "$runtime_tables" != t ] || [ "$secrets_table" != t ]; then
            echo "runtime-init: grants pending (Runtime tables: $runtime_tables, runtime_secrets: $secrets_table)" >&2
            exit 3
        fi
        echo "runtime-init: read grants applied"
        ;;
    live-claims)
        psql_q -d kodus_runtime -Atc "SELECT count(*) FROM runtime.runtime_claims WHERE state IN ('pending','bound','held')"
        ;;
    connected-cells)
        psql_q -d kodus_runtime -Atc "SELECT count(*) FROM runtime.runtime_cells c WHERE c.status = 'connected'
            AND EXISTS (SELECT 1 FROM runtime.runtime_cell_sessions s WHERE s.cell_id = c.cell_id AND s.free_slots > 0)"
        ;;
    dump)
        pg_dump -Fc -d "$(runtime_db)"
        ;;
    restore)
        db=$(runtime_db)
        pg_restore --clean --if-exists --exit-on-error -d "$db"
        echo "runtime-init: $db restored" >&2
        ;;
    uninstall)
        psql_q -d "$API_PG_DB_DATABASE" -c "DO \$\$ BEGIN
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kodus_runtime_secrets_reader') THEN
              IF to_regclass('public.runtime_secrets') IS NOT NULL THEN
                EXECUTE 'REVOKE ALL ON public.runtime_secrets FROM kodus_runtime_secrets_reader';
              END IF;
              EXECUTE 'REVOKE USAGE ON SCHEMA public FROM kodus_runtime_secrets_reader';
            END IF;
          END \$\$"
        psql_q -d postgres -v product_db="$API_PG_DB_DATABASE" -f "$SQL/runtime-uninstall.sql"
        echo "runtime-init: Runtime and OpenBao databases and roles removed"
        ;;
    *)
        echo "runtime-init: unknown RUNTIME_INIT_MODE" >&2
        exit 2
        ;;
esac
