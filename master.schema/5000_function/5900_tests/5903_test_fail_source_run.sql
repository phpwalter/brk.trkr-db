/*
===============================================================================
 File:           5000_function/5900_tests/5903_test_fail_source_run.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Stored-procedure contract tests for 5000_function/5000_importer/5012_importer_fail_source_run.sql.
 Depends On:     5000_function/5000_importer/5012_importer_fail_source_run.sql
 Creates:        Test assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5903_test_fail_source_run.sql', ARRAY['5000_function/5000_importer/5012_importer_fail_source_run.sql']::text[]);

\echo '[TEST] 5903_test_fail_source_run'

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
            ('import.fail_source_run(uuid,text)', 'f')
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


/* Unknown source run must fail rather than silently succeed. */
DO $$
DECLARE
    v_failed boolean := false;
BEGIN
    BEGIN
        PERFORM import.fail_source_run(gen_random_uuid(), 'stored procedure test');
    EXCEPTION WHEN OTHERS THEN
        v_failed := true;
    END;
    PERFORM app.assert_true(v_failed, 'fail_source_run accepted an unknown source_run_id');
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5903_test_fail_source_run.sql');
