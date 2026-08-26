/*
===============================================================================
 File:           5000_function/5900_tests/5973_test_system_definition.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Stored-procedure contract tests for 5000_function/5700_system/5703_system_definition.sql.
 Depends On:     5000_function/5700_system/5703_system_definition.sql
 Creates:        Test assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5973_test_system_definition.sql', ARRAY['5000_function/5700_system/5703_system_definition.sql']::text[]);

\echo '[TEST] 5973_test_system_definition'

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
            ('definition.effective_inventory_version(uuid)', 'f'),
            ('definition.prevent_finalized_version_mutation()', 'f'),
            ('definition.prevent_finalized_graph_mutation()', 'f'),
            ('definition.validate_authority()', 'f')
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

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5973_test_system_definition.sql');
