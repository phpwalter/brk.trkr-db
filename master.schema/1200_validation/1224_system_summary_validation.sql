
/*
===============================================================================
 File:           1200_validation/1224_system_summary_validation.sql
 Purpose:        Validate cached system summary correctness and security.
 Depends On:     1000_reporting/1010_reporting_system_summary.sql
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1224_system_summary_validation.sql', ARRAY['1000_reporting/1010_reporting_system_summary.sql']::text[]);

SELECT app.assert_table_exists('reporting', 'system_summary');

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM reporting.system_summary
    WHERE summary_id <> 1
$$,
'reporting.system_summary contains a non-singleton row'
);

SELECT app.assert_no_rows(
$$
    WITH actual AS (
        SELECT
            count(*)::bigint total_catalog_items,
            count(*) FILTER (WHERE status='ACTIVE')::bigint active_catalog_items,
            count(*) FILTER (WHERE status='RETIRED')::bigint retired_catalog_items,
            count(*) FILTER (WHERE status='SOURCE_MISSING')::bigint source_missing_catalog_items,
            count(*) FILTER (WHERE status='UNRESOLVED_CUSTOM')::bigint unresolved_custom_catalog_items,
            count(*) FILTER (WHERE status='ARCHIVED')::bigint archived_catalog_items,
            count(*) FILTER (WHERE item_kind='SET')::bigint total_sets,
            count(*) FILTER (WHERE item_kind='PART')::bigint total_parts,
            count(*) FILTER (WHERE item_kind='MINIFIGURE')::bigint total_minifigures,
            count(*) FILTER (WHERE item_kind='INSTRUCTIONS')::bigint total_instructions,
            count(*) FILTER (WHERE item_kind='MOC')::bigint total_mocs
        FROM catalog.items
    )
    SELECT 1
    FROM reporting.system_summary s
    CROSS JOIN actual a
    WHERE s.summary_id=1
      AND (
          s.total_catalog_items <> a.total_catalog_items
          OR s.active_catalog_items <> a.active_catalog_items
          OR s.retired_catalog_items <> a.retired_catalog_items
          OR s.source_missing_catalog_items <> a.source_missing_catalog_items
          OR s.unresolved_custom_catalog_items <> a.unresolved_custom_catalog_items
          OR s.archived_catalog_items <> a.archived_catalog_items
          OR s.total_sets <> a.total_sets
          OR s.total_parts <> a.total_parts
          OR s.total_minifigures <> a.total_minifigures
          OR s.total_instructions <> a.total_instructions
          OR s.total_mocs <> a.total_mocs
      )
$$,
'reporting.system_summary has drifted from canonical catalog state'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM (VALUES ('lego_api'),('lego_app'),('lego_importer')) r(role_name)
    WHERE to_regrole(r.role_name) IS NOT NULL
      AND has_table_privilege(r.role_name, 'reporting.system_summary', 'INSERT,UPDATE,DELETE')
$$,
'a runtime role has direct DML on reporting.system_summary'
);

SELECT app.assert_true(
    to_regprocedure('reporting.get_system_summary()') IS NOT NULL,
    'reporting.get_system_summary() is missing'
);

SELECT pg_temp.bt_mark_completed('1200_validation/1224_system_summary_validation.sql');
\echo '[VALIDATE PASS] 1224_system_summary_validation.sql'
