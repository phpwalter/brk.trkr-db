/*
===============================================================================
 File:           5000_function/5900_tests/5904_test_set_manifest_enrichment.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Contract-test SET manifest enrichment routines without
                 mutating canonical production data.
 Depends On:     5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql
                 5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql
                 1200_validation/1226_set_manifest_enrichment_validation.sql
 Creates:        Transactional contract assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5904_test_set_manifest_enrichment.sql', ARRAY['5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql', '5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql', '1200_validation/1226_set_manifest_enrichment_validation.sql']::text[]);

BEGIN;

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'import'
          AND p.proname = 'upsert_set_manifest_component'
          AND p.prosecdef
    ),
    'import.upsert_set_manifest_component must be SECURITY DEFINER'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'import'
          AND p.proname = 'mark_set_manifest_component_missing'
          AND p.prosecdef
    ),
    'import.mark_set_manifest_component_missing must be SECURITY DEFINER'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'import'
          AND p.proname = 'reconcile_rebrickable_sticker_sheets'
          AND p.prosecdef
    ),
    'import.reconcile_rebrickable_sticker_sheets must be SECURITY DEFINER'
);

SELECT app.assert_true(
    has_function_privilege(
        'lego_importer',
        'import.reconcile_rebrickable_sticker_sheets(uuid)',
        'EXECUTE'
    ),
    'lego_importer must execute automatic sticker reconciliation'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'reporting'
          AND p.proname = 'get_set_manifest_enrichment'
          AND p.prosecdef
    ),
    'reporting.get_set_manifest_enrichment must be SECURITY DEFINER'
);

SELECT app.assert_true(
    NOT has_table_privilege('lego_importer','definition.set_manifest_components','INSERT')
    AND NOT has_table_privilege('lego_importer','definition.set_manifest_components','UPDATE')
    AND NOT has_table_privilege('lego_importer','definition.set_manifest_components','DELETE'),
    'lego_importer must remain execute-only for manifest enrichment'
);

ROLLBACK;

\echo '[PASS] 5904_test_set_manifest_enrichment.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5904_test_set_manifest_enrichment.sql');
