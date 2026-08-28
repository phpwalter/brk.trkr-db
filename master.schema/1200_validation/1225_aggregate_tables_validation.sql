/*
===============================================================================
 File:           1200_validation/1225_aggregate_tables_validation.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Validate Greenfield aggregate tables, zero-value catalog-kind
                 seeds, cached-state correctness, and runtime DML isolation.
 Depends On:     1000_reporting/1011_reporting_aggregate_tables.sql
                 1200_validation/1224_system_summary_validation.sql
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1225_aggregate_tables_validation.sql', ARRAY['1000_reporting/1011_reporting_aggregate_tables.sql', '1200_validation/1224_system_summary_validation.sql']::text[]);

\echo '[VALIDATE] 1225_aggregate_tables_validation.sql'

SELECT app.assert_table_exists('reporting', 'import_summary');
SELECT app.assert_table_exists('import', 'catalog_summary_delta');
SELECT app.assert_table_exists('reporting', 'catalog_kind_summary');
SELECT app.assert_table_exists('reporting', 'owner_summary');

/* Every catalog.item_kind must exist even when its count is zero. */
SELECT app.assert_true(
    (
        SELECT count(*)
        FROM reporting.catalog_kind_summary
    ) = (
        SELECT count(*)
        FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'catalog'
          AND t.typname = 'item_kind'
    ),
    'reporting.catalog_kind_summary does not contain every catalog.item_kind'
);

/* Cached kind totals must equal canonical catalog state. */
SELECT app.assert_no_rows(
$$
    WITH actual AS (
        SELECT
            k.item_kind,
            count(i.catalog_item_id)::bigint AS total_items,
            count(i.catalog_item_id) FILTER (WHERE i.status='ACTIVE')::bigint AS active_items,
            count(i.catalog_item_id) FILTER (WHERE i.status='RETIRED')::bigint AS retired_items,
            count(i.catalog_item_id) FILTER (WHERE i.status='SOURCE_MISSING')::bigint AS source_missing_items,
            count(i.catalog_item_id) FILTER (WHERE i.status='UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_items,
            count(i.catalog_item_id) FILTER (WHERE i.status='ARCHIVED')::bigint AS archived_items
        FROM reporting.catalog_kind_summary k
        LEFT JOIN catalog.items i
          ON i.item_kind = k.item_kind
        GROUP BY k.item_kind
    )
    SELECT 1
    FROM reporting.catalog_kind_summary s
    JOIN actual a USING (item_kind)
    WHERE s.total_items <> a.total_items
       OR s.active_items <> a.active_items
       OR s.retired_items <> a.retired_items
       OR s.source_missing_items <> a.source_missing_items
       OR s.unresolved_custom_items <> a.unresolved_custom_items
       OR s.archived_items <> a.archived_items
$$,
'reporting.catalog_kind_summary has drifted from catalog.items'
);

/* Every source run must have a reporting.import_summary row. */
SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.source_runs sr
    LEFT JOIN reporting.import_summary s
      USING (source_run_id)
    WHERE s.source_run_id IS NULL
$$,
'reporting.import_summary is missing an import.source_runs row'
);

/* Every owner must have an owner_summary row. */
SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM identity.owners o
    LEFT JOIN reporting.owner_summary s
      USING (owner_id)
    WHERE s.owner_id IS NULL
$$,
'reporting.owner_summary is missing an identity.owners row'
);

/* Runtime roles may never mutate aggregate storage directly. */
SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM (VALUES
        ('lego_api'),
        ('lego_app'),
        ('lego_admin'),
        ('lego_importer'),
        ('lego_reporting')
    ) r(role_name)
    CROSS JOIN (VALUES
        ('reporting.system_summary'),
        ('reporting.import_summary'),
        ('import.catalog_summary_delta'),
        ('reporting.catalog_kind_summary'),
        ('reporting.owner_summary')
    ) t(relation_name)
    WHERE to_regrole(r.role_name) IS NOT NULL
      AND has_table_privilege(
          r.role_name,
          t.relation_name,
          'INSERT,UPDATE,DELETE'
      )
$$,
'An operational role has direct aggregate-table DML'
);

SELECT app.assert_true(
    to_regprocedure('import.get_system_summary()') IS NOT NULL,
    'import.get_system_summary() is missing'
);

SELECT app.assert_true(
    has_function_privilege(
        'lego_importer',
        'import.get_system_summary()',
        'EXECUTE'
    ),
    'lego_importer cannot execute import.get_system_summary()'
);

SELECT app.assert_true(
    NOT has_schema_privilege('lego_importer', 'reporting', 'USAGE'),
    'lego_importer should not require direct USAGE on reporting schema'
);

SELECT app.assert_true(
    to_regprocedure('reporting.get_import_summary(integer)') IS NOT NULL,
    'reporting.get_import_summary(integer) is missing'
);

SELECT app.assert_true(
    to_regprocedure('reporting.get_catalog_kind_summary()') IS NOT NULL,
    'reporting.get_catalog_kind_summary() is missing'
);

SELECT app.assert_true(
    to_regprocedure('reporting.get_owner_summary(uuid)') IS NOT NULL,
    'reporting.get_owner_summary(uuid) is missing'
);

SELECT pg_temp.bt_mark_completed('1200_validation/1225_aggregate_tables_validation.sql');
\echo '[VALIDATE PASS] 1225_aggregate_tables_validation.sql'
