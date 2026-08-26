/*
===============================================================================
 File:           5000_function/5900_tests/5902_test_rebrickable_catalog_reconcile.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Stored-procedure contract tests for 5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql.
 Depends On:     5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql
 Creates:        Test assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5902_test_rebrickable_catalog_reconcile.sql', ARRAY['5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql']::text[]);

\echo '[TEST] 5902_test_rebrickable_catalog_reconcile'

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
            ('import.phase3b_initialize(uuid,boolean)', 'f'),
            ('import.phase3b_run_checkpoint(uuid,text,text,integer)', 'f'),
            ('import.phase3b_progress(uuid)', 'f'),
            ('import.phase4b_initialize(uuid,boolean)', 'f'),
            ('import.phase4b_run_checkpoint(uuid,text,text,integer)', 'f'),
            ('import.phase4b_progress(uuid)', 'f'),
            ('import.phase5b_initialize(uuid,boolean)', 'f'),
            ('import.phase5b_run_checkpoint(uuid,text,text,integer)', 'f'),
            ('import.phase5b_progress(uuid)', 'f'),
            ('import.phase6b_reconcile(uuid)', 'f')
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

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5902_test_rebrickable_catalog_reconcile.sql');
