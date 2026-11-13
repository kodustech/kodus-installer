-- The Kody Runtime's least-privilege Postgres identities on the server Kodus
-- already runs (ADR-025, ADR-046). Idempotent. Run as the product's admin
-- role against the maintenance database `postgres`, with:
--   psql -v ON_ERROR_STOP=1 -v pw_runtime=... -v pw_reader=... -v pw_secrets=... -v product_db=... -f runtime-roles.sql
--
--   kodus_runtime                 owner of the database kodus_runtime only; the
--                                 hub and the runtime-worker (RUNTIME_DATABASE_URL)
--   kodus_runtime_reader          read-only on the Runtime tables the product API
--                                 and worker read (RUNTIME_DATABASE_READ_URL);
--                                 its SELECT grants are runtime-reader-grants.sql,
--                                 applied after the hub's first boot
--   kodus_runtime_secrets_reader  the hub's read of the org secrets' id, name and
--                                 hosts on the product database
--                                 (RUNTIME_PRODUCT_SECRETS_READ_URL); its column
--                                 grant is runtime-secrets-reader-grants.sql,
--                                 applied after the product migration
--
-- Derived from kodustech/kodus-ai scripts/runtime/dev-runtime-users.sh. Unlike
-- the dev script it does not revoke CONNECT from PUBLIC on the product database:
-- a customer's other roles (BI, backups) may rely on it.

SELECT format('CREATE ROLE kodus_runtime LOGIN PASSWORD %L', :'pw_runtime')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kodus_runtime') \gexec
SELECT format('ALTER ROLE kodus_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'pw_runtime') \gexec

SELECT 'CREATE DATABASE kodus_runtime OWNER kodus_runtime'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'kodus_runtime') \gexec
ALTER DATABASE kodus_runtime OWNER TO kodus_runtime;
REVOKE CONNECT ON DATABASE kodus_runtime FROM PUBLIC;
GRANT CONNECT ON DATABASE kodus_runtime TO kodus_runtime;

SELECT format('CREATE ROLE kodus_runtime_reader LOGIN PASSWORD %L', :'pw_reader')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kodus_runtime_reader') \gexec
SELECT format('ALTER ROLE kodus_runtime_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'pw_reader') \gexec
GRANT CONNECT ON DATABASE kodus_runtime TO kodus_runtime_reader;

SELECT format('CREATE ROLE kodus_runtime_secrets_reader LOGIN PASSWORD %L', :'pw_secrets')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kodus_runtime_secrets_reader') \gexec
SELECT format('ALTER ROLE kodus_runtime_secrets_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'pw_secrets') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO kodus_runtime_secrets_reader', :'product_db') \gexec
