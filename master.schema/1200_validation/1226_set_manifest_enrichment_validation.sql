/*
===============================================================================
 File:           1200_validation/1226_set_manifest_enrichment_validation.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Validate SET manifest enrichment schema and execute-only access.
 Depends On:     0400_definitions/0410_set_manifest_components.sql
                 5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql
                 5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql
                 1100_security/1111_role_ownership_separation.sql
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1226_set_manifest_enrichment_validation.sql', ARRAY['0400_definitions/0410_set_manifest_components.sql', '5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql', '5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql', '1100_security/1111_role_ownership_separation.sql']::text[]);

SELECT app.assert_true(
    to_regclass('definition.set_manifest_components') IS NOT NULL,
    'definition.set_manifest_components is missing'
);

SELECT app.assert_true(
    to_regprocedure('import.upsert_set_manifest_component(text,text,text,text,text,text,integer,jsonb)') IS NOT NULL,
    'import.upsert_set_manifest_component(...) is missing'
);

SELECT app.assert_true(
    to_regprocedure('import.mark_set_manifest_component_missing(text,text,text,text)') IS NOT NULL,
    'import.mark_set_manifest_component_missing(...) is missing'
);

SELECT app.assert_true(
    to_regprocedure('import.reconcile_rebrickable_sticker_sheets(uuid)') IS NOT NULL,
    'import.reconcile_rebrickable_sticker_sheets(uuid) is missing'
);

SELECT app.assert_true(
    has_function_privilege(
        'brktrkr_import',
        'import.reconcile_rebrickable_sticker_sheets(uuid)',
        'EXECUTE'
    ),
    'brktrkr_import cannot execute automatic Rebrickable sticker-sheet reconciliation'
);

SELECT app.assert_true(
    to_regprocedure('reporting.get_set_manifest_enrichment(text)') IS NOT NULL,
    'reporting.get_set_manifest_enrichment(text) is missing'
);

SELECT app.assert_true(
    NOT has_table_privilege('brktrkr_import','definition.set_manifest_components','INSERT')
    AND NOT has_table_privilege('brktrkr_import','definition.set_manifest_components','UPDATE')
    AND NOT has_table_privilege('brktrkr_import','definition.set_manifest_components','DELETE'),
    'brktrkr_import must not have direct DML on definition.set_manifest_components'
);

SELECT app.assert_true(
    has_function_privilege(
        'brktrkr_import',
        'import.upsert_set_manifest_component(text,text,text,text,text,text,integer,jsonb)',
        'EXECUTE'
    ),
    'brktrkr_import cannot execute approved manifest enrichment upsert'
);

SELECT app.assert_true(
    has_function_privilege(
        'brktrkr_import',
        'import.mark_set_manifest_component_missing(text,text,text,text)',
        'EXECUTE'
    ),
    'brktrkr_import cannot execute approved manifest missing-state routine'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        CROSS JOIN LATERAL aclexplode(
            COALESCE(p.proacl, acldefault('f', p.proowner))
        ) a
        WHERE n.nspname = 'import'
          AND p.oid = 'import.upsert_set_manifest_component(text,text,text,text,text,text,integer,jsonb)'::regprocedure
          AND a.grantee = 0
          AND a.privilege_type = 'EXECUTE'
    ),
    'PUBLIC must not execute manifest enrichment upsert'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        CROSS JOIN LATERAL aclexplode(
            COALESCE(p.proacl, acldefault('f', p.proowner))
        ) a
        WHERE n.nspname = 'import'
          AND p.oid = 'import.mark_set_manifest_component_missing(text,text,text,text)'::regprocedure
          AND a.grantee = 0
          AND a.privilege_type = 'EXECUTE'
    ),
    'PUBLIC must not execute manifest missing-state routine'
);

\echo '[PASS] 1226_set_manifest_enrichment_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1226_set_manifest_enrichment_validation.sql');
