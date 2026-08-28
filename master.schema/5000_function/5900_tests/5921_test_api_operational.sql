/*
===============================================================================
 File:           5000_function/5900_tests/5921_test_api_operational.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.2.0
 PostgreSQL:     16+
 Purpose:        Stored-procedure contract tests for 5000_function/5200_api/5210_api_operational.sql.
 Depends On:     5000_function/5200_api/5210_api_operational.sql
 Creates:        Test assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5921_test_api_operational.sql', ARRAY['5000_function/5200_api/5210_api_operational.sql']::text[]);

\echo '[TEST] 5921_test_api_operational'

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
            ('api.search_catalog(text,integer)', 'f'),
            ('api.search_catalog_public(text,text,integer)', 'f'),
            ('api.get_catalog_item_by_item_num(text)', 'f'),
            ('api.get_set_by_item_num(text)', 'f'),
            ('api.get_set_manifest_by_item_num(text)', 'f'),
            ('api.get_set_manifest_versions_by_item_num(text)', 'f'),
            ('api.get_set_manifest_version_by_item_num(text,integer)', 'f'),
            ('api.get_set_instruction_assets_by_item_num(text)', 'f'),
            ('api.get_set_market_by_item_num(text,text)', 'f'),
            ('api.get_part_by_part_num(text)', 'f'),
            ('api.get_part_where_used(text,integer,text)', 'f'),
            ('api.get_part_sources(text)', 'f'),
            ('api.get_part_market(text,text)', 'f'),
            ('api.get_part_inventory_links(text)', 'f'),
            ('api.mark_notification_read(uuid)', 'f'),
            ('admin.set_catalog_item_image(uuid,text,text,boolean,app.sha256_digest)', 'f'),
            ('admin.remove_catalog_item_image(uuid)', 'f'),
            ('admin.set_instruction_asset(uuid,text,text,smallint,app.sha256_digest,integer)', 'f'),
            ('admin.remove_instruction_asset(uuid)', 'f'),
            ('api.transfer_collection_quantity(uuid,uuid,app.quantity,text)', 'p')
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

    PERFORM app.assert_true(
        to_regprocedure('api._manifest_version_json(uuid)') IS NOT NULL,
        'Internal manifest serializer is missing'
    );
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5921_test_api_operational.sql');
