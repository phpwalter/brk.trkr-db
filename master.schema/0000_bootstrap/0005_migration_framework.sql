/*
===============================================================================
 File:           0000_bootstrap/0005_migration_framework.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Establish immutable forward-only production migration metadata
                 without replacing the fresh-database bootstrap workflow.
 Depends On:     0000_bootstrap/0004_validation_helpers.sql
                 app schema
 Creates:        app.schema_migration_baseline
                 app.schema_migrations
 Key Rules:      Fresh databases are installed by bootstrap.sql.
                 Existing production databases advance only through numbered,
                 forward-only migration files.
                 Applied migration IDs and SHA-256 checksums are immutable.
                 Runtime roles never receive direct access to migration metadata.
 Validation:     1200_validation/1219_migration_framework_validation.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0000_bootstrap/0005_migration_framework.sql', ARRAY['0000_bootstrap/0004_validation_helpers.sql', 'app schema']::text[]);

CREATE TABLE app.schema_migration_baseline (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    baseline_id text NOT NULL,
    installed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    installed_by name NOT NULL DEFAULT session_user,
    CONSTRAINT schema_migration_baseline_id_nonempty
        CHECK (btrim(baseline_id) <> '')
);

COMMENT ON TABLE app.schema_migration_baseline IS
    'Singleton identifying the master-schema baseline from which forward-only production migrations begin.';

INSERT INTO app.schema_migration_baseline(singleton, baseline_id)
VALUES (true, 'master-schema-v10.0');

CREATE TABLE app.schema_migrations (
    migration_id bigint PRIMARY KEY,
    migration_name text NOT NULL UNIQUE,
    checksum_sha256 text NOT NULL,
    transaction_mode text NOT NULL,
    release_label text,
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    applied_by name NOT NULL DEFAULT session_user,
    execution_ms bigint,
    tool_version text NOT NULL DEFAULT 'bricktrackr-migrator/1',

    CONSTRAINT schema_migrations_id_positive
        CHECK (migration_id > 0),
    CONSTRAINT schema_migrations_name_nonempty
        CHECK (btrim(migration_name) <> ''),
    CONSTRAINT schema_migrations_checksum_sha256_format
        CHECK (checksum_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT schema_migrations_transaction_mode
        CHECK (transaction_mode IN ('transactional', 'nontransactional')),
    CONSTRAINT schema_migrations_execution_ms_nonnegative
        CHECK (execution_ms IS NULL OR execution_ms >= 0)
);

COMMENT ON TABLE app.schema_migrations IS
    'Authoritative immutable history of applied forward-only production migrations.';

COMMENT ON COLUMN app.schema_migrations.checksum_sha256 IS
    'SHA-256 of the exact migration file bytes at application time; a later checksum mismatch is a hard deployment failure.';

COMMENT ON COLUMN app.schema_migrations.transaction_mode IS
    'transactional or nontransactional; the migration runner owns transaction boundaries.';

CREATE OR REPLACE FUNCTION app.prevent_schema_migration_history_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    RAISE EXCEPTION
        'Applied schema migration history is immutable; % is not permitted',
        TG_OP
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER trg_schema_migrations_immutable
BEFORE UPDATE OR DELETE ON app.schema_migrations
FOR EACH ROW
EXECUTE FUNCTION app.prevent_schema_migration_history_mutation();

CREATE TRIGGER trg_schema_migration_baseline_immutable
BEFORE UPDATE OR DELETE ON app.schema_migration_baseline
FOR EACH ROW
EXECUTE FUNCTION app.prevent_schema_migration_history_mutation();

SELECT app.assert_true(
    (SELECT count(*) = 1 FROM app.schema_migration_baseline),
    'Migration baseline must contain exactly one row'
);

SELECT app.assert_true(
    (SELECT baseline_id = 'master-schema-v10.0'
       FROM app.schema_migration_baseline
      WHERE singleton),
    'Unexpected migration baseline identifier'
);

\echo '[PASS] 0005_migration_framework.sql'
SELECT pg_temp.bt_mark_completed('0000_bootstrap/0005_migration_framework.sql');
