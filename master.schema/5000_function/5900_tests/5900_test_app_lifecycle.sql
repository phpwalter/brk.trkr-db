/*
===============================================================================
 File:           5000_function/5900_tests/5900_test_app_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for the canonical app-schema request-context
                 lifecycle, UUIDv7 generation, and migration-history immutability.
 Depends On:     5000_function/5700_system/5709_system_request_context.sql
                 0000_bootstrap/0005_migration_framework.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5900_test_app_lifecycle.sql', ARRAY['5000_function/5700_system/5709_system_request_context.sql', '0000_bootstrap/0005_migration_framework.sql']::text[]);

\echo '[TEST] 5900_test_app_lifecycle.sql'

BEGIN;

/*
 * Establish a real authenticated application actor for USER actor-class
 * coverage. identity.users is itself audited, so disable only its audit
 * trigger for the fixture insert. This entire test runs inside a
 * transaction and rolls back.
 */
ALTER TABLE identity.users DISABLE TRIGGER trg_audit_users;

INSERT INTO identity.users (
    user_id,
    username,
    display_name,
    account_status,
    activated_at
)
VALUES (
    '00000000-0000-4000-8000-000000005900'::uuid,
    'bt_test_app_5900',
    'BrickTrackr App Lifecycle Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

DO $$
DECLARE
    v_user_id uuid := '00000000-0000-4000-8000-000000005900'::uuid;
    v_req_a uuid := '00000000-0000-4000-8000-000000005901'::uuid;
    v_req_b uuid := '00000000-0000-4000-8000-000000005902'::uuid;
    v_req_c uuid := '00000000-0000-4000-8000-000000005903'::uuid;
    v_req_d uuid := '00000000-0000-4000-8000-000000005904'::uuid;
    v_source_run_id uuid := '00000000-0000-4000-8000-000000005905'::uuid;
    v_failed boolean;
    v_uuid uuid;
    v_uuid_text text;
    v_baseline_id text;
BEGIN
    /* -----------------------------------------------------------------
     * app.uuid_v7()
     * ----------------------------------------------------------------- */
    FOR i IN 1..25 LOOP
        v_uuid := app.uuid_v7();
        v_uuid_text := v_uuid::text;

        PERFORM app.assert_true(v_uuid IS NOT NULL, 'uuid_v7() returned NULL');
        PERFORM app.assert_true(
            substr(v_uuid_text, 15, 1) = '7',
            format('uuid_v7() value %s is not version 7', v_uuid_text)
        );
        PERFORM app.assert_true(
            substr(v_uuid_text, 20, 1) IN ('8', '9', 'a', 'b'),
            format('uuid_v7() value %s has an invalid RFC variant nibble', v_uuid_text)
        );
    END LOOP;

    /* -----------------------------------------------------------------
     * app.set_request_context() - USER actor class
     * ----------------------------------------------------------------- */
    PERFORM app.set_request_context(v_user_id, v_req_a, '5900-user-context', 'USER');

    PERFORM app.assert_true(
        identity.current_user_id_optional() = v_user_id,
        'USER context did not establish current_user_id'
    );
    PERFORM app.assert_true(
        app.current_request_id() = v_req_a,
        'USER context did not establish request_id'
    );
    PERFORM app.assert_true(
        app.current_trace_id() = '5900-user-context',
        'USER context did not establish trace_id'
    );
    PERFORM app.assert_true(
        app.current_actor_class() = 'USER',
        'USER context did not establish actor_class'
    );

    /* USER actor class requires a non-NULL p_user_id. */
    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(NULL, v_req_b, '5900-user-null', 'USER');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22004' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted a NULL p_user_id for USER');

    /* USER actor class requires an existing identity.users row. */
    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(gen_random_uuid(), v_req_b, '5900-user-missing', 'USER');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23503' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted a nonexistent p_user_id for USER');

    /* -----------------------------------------------------------------
     * app.set_request_context() - ADMIN actor class
     * ----------------------------------------------------------------- */
    PERFORM app.set_request_context(NULL, v_req_b, '5900-admin-context', 'ADMIN');

    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'ADMIN context unexpectedly carried an application user id'
    );
    PERFORM app.assert_true(
        app.current_request_id() = v_req_b,
        'ADMIN context did not establish request_id'
    );
    PERFORM app.assert_true(
        app.current_actor_class() = 'ADMIN',
        'ADMIN context did not establish actor_class'
    );

    /* ADMIN actor class must never carry an application user id. */
    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(v_user_id, v_req_b, '5900-admin-user', 'ADMIN');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted a non-NULL p_user_id for ADMIN');

    /* -----------------------------------------------------------------
     * app.set_request_context() - IMPORTER actor class
     * ----------------------------------------------------------------- */
    PERFORM app.set_request_context(NULL, v_req_c, '5900-importer-context', 'IMPORTER');

    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'IMPORTER context unexpectedly carried an application user id'
    );
    PERFORM app.assert_true(
        app.current_actor_class() = 'IMPORTER',
        'IMPORTER context did not establish actor_class'
    );

    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(v_user_id, v_req_c, '5900-importer-user', 'IMPORTER');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted a non-NULL p_user_id for IMPORTER');

    /* -----------------------------------------------------------------
     * app.set_request_context() - SYSTEM actor class
     * ----------------------------------------------------------------- */
    PERFORM app.set_request_context(NULL, v_req_d, '5900-system-context', 'SYSTEM');

    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'SYSTEM context unexpectedly carried an application user id'
    );
    PERFORM app.assert_true(
        app.current_actor_class() = 'SYSTEM',
        'SYSTEM context did not establish actor_class'
    );

    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(v_user_id, v_req_d, '5900-system-user', 'SYSTEM');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted a non-NULL p_user_id for SYSTEM');

    /* Actor class matching is case-insensitive. */
    PERFORM app.set_request_context(NULL, v_req_d, '5900-system-lower', 'system');
    PERFORM app.assert_true(
        app.current_actor_class() = 'SYSTEM',
        'set_request_context() did not normalize a lowercase actor_class'
    );

    /* Unknown actor_class strings are rejected. */
    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(NULL, v_req_d, '5900-bogus', 'BOGUS');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted an invalid actor_class');

    /* p_request_id is mandatory. */
    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(NULL, NULL, '5900-no-request-id', 'SYSTEM');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22004' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted a NULL p_request_id');

    /* Whitespace-only p_trace_id is rejected. */
    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(NULL, v_req_d, '   ', 'SYSTEM');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted a whitespace-only p_trace_id');

    /* Overlong p_trace_id is rejected. */
    v_failed := false;
    BEGIN
        PERFORM app.set_request_context(NULL, v_req_d, repeat('x', 129), 'SYSTEM');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_request_context() accepted an overlong p_trace_id');

    /* -----------------------------------------------------------------
     * app.clear_request_context()
     * ----------------------------------------------------------------- */
    PERFORM app.clear_request_context();

    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'clear_request_context() left current_user_id populated'
    );
    PERFORM app.assert_true(
        app.current_request_id() IS NULL,
        'clear_request_context() left request_id populated'
    );
    PERFORM app.assert_true(
        app.current_trace_id() IS NULL,
        'clear_request_context() left trace_id populated'
    );
    PERFORM app.assert_true(
        app.current_actor_class() IS NULL,
        'clear_request_context() left actor_class populated'
    );

    /* Clearing an already-clear context is idempotent. */
    PERFORM app.clear_request_context();
    PERFORM app.assert_true(
        app.current_actor_class() IS NULL,
        'clear_request_context() is not idempotent'
    );

    /* -----------------------------------------------------------------
     * app.set_import_context()
     * ----------------------------------------------------------------- */
    v_failed := false;
    BEGIN
        PERFORM app.set_import_context(NULL);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22004' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'set_import_context() accepted a NULL source_run_id');

    PERFORM app.set_import_context(v_source_run_id);

    PERFORM app.assert_true(
        app.current_actor_class() = 'IMPORTER',
        'set_import_context() did not establish IMPORTER actor_class'
    );
    PERFORM app.assert_true(
        NULLIF(current_setting('app.source_run_id', true), '')::uuid = v_source_run_id,
        'set_import_context() did not establish source_run_id'
    );

    PERFORM app.clear_request_context();
    PERFORM pg_catalog.set_config('app.source_run_id', '', true);

    /* -----------------------------------------------------------------
     * app.prevent_schema_migration_history_mutation()
     * ----------------------------------------------------------------- */
    SELECT baseline_id
      INTO v_baseline_id
      FROM app.schema_migration_baseline
     WHERE singleton;

    PERFORM app.assert_true(
        v_baseline_id IS NOT NULL,
        'app.schema_migration_baseline has no baseline row to test against'
    );

    v_failed := false;
    BEGIN
        UPDATE app.schema_migration_baseline
           SET baseline_id = 'tampered-baseline'
         WHERE singleton;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'app.schema_migration_baseline allowed an UPDATE');

    v_failed := false;
    BEGIN
        DELETE FROM app.schema_migration_baseline WHERE singleton;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'app.schema_migration_baseline allowed a DELETE');

    /* The row must be unchanged after both rejected mutation attempts. */
    PERFORM app.assert_true(
        (SELECT baseline_id FROM app.schema_migration_baseline WHERE singleton) = v_baseline_id,
        'Rejected mutation attempts altered app.schema_migration_baseline'
    );
END;
$$;

/* Runtime roles lacking any request-context authority must be rejected. */
DO $$
DECLARE
    v_failed boolean;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'brktrkr_reporting') THEN
        SET LOCAL ROLE brktrkr_reporting;

        v_failed := false;
        BEGIN
            PERFORM app.set_request_context(
                NULL,
                '00000000-0000-4000-8000-000000005906'::uuid,
                'reporting-admin',
                'ADMIN'
            );
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLSTATE = '42501' THEN
                    v_failed := true;
                ELSE
                    RESET ROLE;
                    RAISE;
                END IF;
        END;
        RESET ROLE;
        PERFORM app.assert_true(v_failed, 'brktrkr_reporting was able to establish ADMIN request context');

        SET LOCAL ROLE brktrkr_reporting;
        v_failed := false;
        BEGIN
            PERFORM app.set_import_context('00000000-0000-4000-8000-000000005907'::uuid);
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLSTATE = '42501' THEN
                    v_failed := true;
                ELSE
                    RESET ROLE;
                    RAISE;
                END IF;
        END;
        RESET ROLE;
        PERFORM app.assert_true(v_failed, 'brktrkr_reporting was able to establish IMPORTER import context');
    END IF;
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5900_test_app_lifecycle.sql');
