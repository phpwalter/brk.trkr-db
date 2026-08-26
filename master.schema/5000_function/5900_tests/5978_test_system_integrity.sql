/*
===============================================================================
 File:           5000_function/5900_tests/5978_test_system_integrity.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Stored-procedure contract tests for 5000_function/5700_system/5708_system_integrity_hardening.sql.
 Depends On:     5000_function/5700_system/5708_system_integrity_hardening.sql
 Creates:        Test assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5978_test_system_integrity.sql', ARRAY['5000_function/5700_system/5708_system_integrity_hardening.sql']::text[]);

\echo '[TEST] 5978_test_system_integrity'

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
            ('definition.validate_inventory_version_source_identity()', 'f'),
            ('definition.validate_inventory_finalization()', 'f'),
            ('collection.validate_instance_definition()', 'f'),
            ('collection.validate_instance_adjustment()', 'f'),
            ('collection.validate_acquisition_item()', 'f'),
            ('collection.validate_entry_tag()', 'f'),
            ('collection.validate_transfer()', 'f'),
            ('collection.prevent_transfer_mutation()', 'f'),
            ('wanted.validate_wishlist_entry_version()', 'f'),
            ('wanted.validate_reservation_capacity()', 'f'),
            ('wanted.validate_build_goal()', 'f'),
            ('wanted.validate_build_allocation()', 'f'),
            ('moc.validate_revision_integrity()', 'f'),
            ('import.validate_normalized_record_job()', 'f'),
            ('import.validate_application_actor()', 'f')
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

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5978_test_system_integrity.sql');
