-- Vendored from kodustech/kodus-ai@ea8b3c846 (kody-runtime/selfhosted-gaps) scripts/runtime/runtime-reader-grants.sql.
-- Re-sync with scripts/runtime/sync-from-kodus-ai.sh; do not edit by hand.
-- What the product API's read-only role (kodus_runtime_reader, RUNTIME_DATABASE_READ_URL)
-- may read in the Runtime database (ADR-025): SELECT on these tables and views only, and
-- only scope/org/cleared_at of runtime_stops (fail-closed external admission). No write
-- grant of any kind. Idempotent; run against the Runtime database after the Runtime's first
-- boot of each release (the Runtime creates the tables). Applied by dev-runtime-users.sh and,
-- in the integration suite, by runtime-reader-grants.integration.spec.ts.
DO $$
DECLARE t text;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'runtime') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA runtime TO kodus_runtime_reader';
    FOREACH t IN ARRAY ARRAY[
      'runtime_cells', 'runtime_egress_events', 'runtime_egress_approvals', 'runtime_run_events',
      'runtime_claims', 'runtime_machine_usage',
      -- The Run projection, the environment setups and the lessons (runtime-schema.ts v21).
      'runtime_runs', 'runtime_environment_setups', 'runtime_lessons',
      -- The sandbox operations, counted by the usage report (v22; never output or file content).
      'runtime_sandbox_audit',
      -- The cells' live sessions (connected, free slots, isolation, driver): the Health screen's cells.
      'runtime_cell_sessions'
    ] LOOP
      IF to_regclass(format('runtime.%I', t)) IS NOT NULL THEN
        EXECUTE format('GRANT SELECT ON runtime.%I TO kodus_runtime_reader', t);
      END IF;
    END LOOP;
    -- The org owner's list of registration tokens (docs/runtime/self-hosted.md): hashes and times only;
    -- the token itself is never stored. Columns of migration 26 included.
    IF to_regclass('runtime.runtime_cell_tokens') IS NOT NULL THEN
      EXECUTE 'GRANT SELECT (token_hash, organization_id, topology, issued_by, created_at, expires_at, used_at, revoked_at) ON runtime.runtime_cell_tokens TO kodus_runtime_reader';
    END IF;
    IF to_regclass('runtime.runtime_stops') IS NOT NULL THEN
      EXECUTE 'GRANT SELECT (scope, organization_id, cleared_at) ON runtime.runtime_stops TO kodus_runtime_reader';
    END IF;
  END IF;
END $$;
