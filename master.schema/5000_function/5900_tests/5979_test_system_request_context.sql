/*
===============================================================================
 File:           5000_function/5900_tests/5979_test_system_request_context.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Stored-procedure contract tests for 5000_function/5700_system/5709_system_request_context.sql.
 Depends On:     5000_function/5700_system/5709_system_request_context.sql
 Creates:        Test assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5979_test_system_request_context.sql', ARRAY['5000_function/5700_system/5709_system_request_context.sql']::text[]);

\echo '[TEST] 5979_test_system_request_context'

BEGIN;

DO $$
DECLARE
    v record;
    v_oid oid;
    v_kind "char";
BEGIN
    FOR v IN
        SELECT *
        FROM (VALUES
            ('app.current_request_id()', 'f'),
            ('app.current_trace_id()', 'f'),
            ('app.current_actor_class()', 'f'),
            ('app.set_authenticated_user(uuid)', 'f'),
            ('app.set_request_context(uuid,text,text)', 'f'),
            ('app.set_import_context(uuid)', 'f')
        ) AS x(signature, expected_kind)
    LOOP
        v_oid := to_regprocedure(v.signature);
        PERFORM app.assert_true(
            v_oid IS NOT NULL,
            format('Required routine %s is missing', v.signature)
        );

        SELECT p.prokind
          INTO v_kind
          FROM pg_proc p
         WHERE p.oid = v_oid;

        PERFORM app.assert_true(
            v_kind = v.expected_kind::"char",
            format(
                'Routine %s has prokind=%s; expected=%s',
                v.signature, v_kind, v.expected_kind
            )
        );
    END LOOP;
END;
$$;


/* Request context must round-trip inside the current transaction. */
DO $$
DECLARE
    v_request uuid := gen_random_uuid();
BEGIN
    PERFORM app.set_request_context(v_request, 'sp-test-trace', 'ADMIN');
    PERFORM app.assert_true(app.current_request_id() = v_request, 'request_id did not round-trip');
    PERFORM app.assert_true(app.current_trace_id() = 'sp-test-trace', 'trace_id did not round-trip');
    PERFORM app.assert_true(app.current_actor_class() = 'ADMIN', 'actor_class did not round-trip');
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5979_test_system_request_context.sql');
