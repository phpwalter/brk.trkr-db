/*
===============================================================================
 File:           1200_validation/1219_migration_framework_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Mechanically enforce the forward-only migration contract.
 Depends On:     0000_bootstrap/0005_migration_framework.sql
                 1100_security/1107_grants.sql
 Creates:        Validation assertions only
 Key Rules:      Migration history is append-only and checksum-bearing.
                 Runtime roles cannot read or mutate migration metadata.
                 Only trusted deployment sessions may record migrations.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1219_migration_framework_validation.sql', ARRAY['0000_bootstrap/0005_migration_framework.sql', '1100_security/1107_grants.sql']::text[]);

\echo '[VALIDATE] 1219_migration_framework_validation.sql'

SELECT app.assert_table_exists('app', 'schema_migration_baseline');
SELECT app.assert_table_exists('app', 'schema_migrations');

SELECT app.assert_true(
    (SELECT count(*) = 1 FROM app.schema_migration_baseline),
    'Migration baseline must contain exactly one row'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM app.schema_migration_baseline
         WHERE singleton
           AND baseline_id = 'master-schema-v10.0'
    ),
    'Migration baseline must be master-schema-v10.0'
);

SELECT app.assert_constraint_exists(
    'app',
    'schema_migrations',
    'schema_migrations_checksum_sha256_format'
);

SELECT app.assert_constraint_exists(
    'app',
    'schema_migrations',
    'schema_migrations_transaction_mode'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_trigger
         WHERE tgrelid = 'app.schema_migrations'::regclass
           AND tgname = 'trg_schema_migrations_immutable'
           AND NOT tgisinternal
    ),
    'app.schema_migrations must have an immutability trigger'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_trigger
         WHERE tgrelid = 'app.schema_migration_baseline'::regclass
           AND tgname = 'trg_schema_migration_baseline_immutable'
           AND NOT tgisinternal
    ),
    'app.schema_migration_baseline must have an immutability trigger'
);

DO $$
DECLARE
    v_role text;
    v_rel text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['brktrkr_api']
    LOOP
        FOREACH v_rel IN ARRAY ARRAY[
            'app.schema_migration_baseline',
            'app.schema_migrations'
        ]
        LOOP
            IF has_table_privilege(v_role, v_rel, 'SELECT')
               OR has_table_privilege(v_role, v_rel, 'INSERT')
               OR has_table_privilege(v_role, v_rel, 'UPDATE')
               OR has_table_privilege(v_role, v_rel, 'DELETE')
               OR has_table_privilege(v_role, v_rel, 'TRUNCATE')
               OR has_table_privilege(v_role, v_rel, 'REFERENCES')
               OR has_table_privilege(v_role, v_rel, 'TRIGGER') THEN
                RAISE EXCEPTION
                    'Runtime role % must have no privileges on migration metadata relation %',
                    v_role, v_rel;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM information_schema.table_privileges
         WHERE table_schema = 'app'
           AND table_name IN ('schema_migration_baseline', 'schema_migrations')
           AND grantee = 'PUBLIC'
    ),
    'PUBLIC must have no migration metadata table privileges'
);

/* Prove history UPDATE/DELETE fail even for the deployment owner.
 * The outer PL/pgSQL block deliberately rolls back the probe insert. */
DO $$
DECLARE
    v_id bigint := 9223372036854770000;
BEGIN
    BEGIN
        INSERT INTO app.schema_migrations(
            migration_id,
            migration_name,
            checksum_sha256,
            transaction_mode,
            release_label
        )
        VALUES (
            v_id,
            '__validation_probe__',
            repeat('0', 64),
            'transactional',
            '__validation__'
        );

        BEGIN
            UPDATE app.schema_migrations
               SET migration_name = '__must_fail__'
             WHERE migration_id = v_id;
            RAISE EXCEPTION 'Migration history UPDATE unexpectedly succeeded';
        EXCEPTION
            WHEN SQLSTATE '55000' THEN
                NULL;
        END;

        BEGIN
            DELETE FROM app.schema_migrations
             WHERE migration_id = v_id;
            RAISE EXCEPTION 'Migration history DELETE unexpectedly succeeded';
        EXCEPTION
            WHEN SQLSTATE '55000' THEN
                NULL;
        END;

        RAISE EXCEPTION USING
            ERRCODE = 'BT001',
            MESSAGE = 'rollback migration immutability validation fixture';
    EXCEPTION
        WHEN SQLSTATE 'BT001' THEN
            NULL;
    END;
END;
$$;

\echo '[PASS] 1219_migration_framework_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1219_migration_framework_validation.sql');
