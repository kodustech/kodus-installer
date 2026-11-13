-- Removes what runtime-roles.sql and openbao-database.sql created. Run as the
-- product's admin role against the maintenance database `postgres`, with
-- psql -v product_db=<product database>. Destroys the Runtime database and the
-- OpenBao vault (every org secret): scripts/runtime/uninstall.sh runs it only
-- with --purge-data, after a backup, and after it revoked the secrets reader's
-- grants inside the product database (table grants can only be revoked from a
-- session on that database).

SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname IN ('kodus_runtime', 'kodus_openbao') AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS kodus_runtime;
DROP DATABASE IF EXISTS kodus_openbao;

SELECT format('REVOKE ALL ON DATABASE %I FROM kodus_runtime_secrets_reader', :'product_db')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kodus_runtime_secrets_reader') \gexec
DROP ROLE IF EXISTS kodus_runtime_secrets_reader;
DROP ROLE IF EXISTS kodus_runtime_reader;
DROP ROLE IF EXISTS kodus_runtime;
DROP ROLE IF EXISTS openbao;
