-- Vendored from kodustech/kodus-ai@be25fd785 (kody-runtime/base) scripts/runtime/runtime-reader-grants.sql.
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
      'runtime_sandbox_audit'
    ] LOOP
      IF to_regclass(format('runtime.%I', t)) IS NOT NULL THEN
        EXECUTE format('GRANT SELECT ON runtime.%I TO kodus_runtime_reader', t);
      END IF;
    END LOOP;
    IF to_regclass('runtime.runtime_stops') IS NOT NULL THEN
      EXECUTE 'GRANT SELECT (scope, organization_id, cleared_at) ON runtime.runtime_stops TO kodus_runtime_reader';
    END IF;
  END IF;
END $$;
