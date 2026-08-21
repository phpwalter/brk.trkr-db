/*
===============================================================================
 File:           1200_validation/1214_extended_architecture_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Validate integrated operational architecture inherited from the
                 stronger master.schema.0 concepts.
 Depends On:     catalog.part_molds
                 catalog.item_search
                 definition.manifest_subassemblies
                 definition.minifig_compositions
                 marketplace.listings
                 finance.transactions
                 operations.notifications
                 reporting.catalog_items
                 api.search_catalog()
                 admin.post_financial_transaction()
                 1100_security/1107_grants.sql
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1214_extended_architecture_validation.sql', ARRAY['catalog.part_molds', 'catalog.item_search', 'definition.manifest_subassemblies', 'definition.minifig_compositions', 'marketplace.listings', 'finance.transactions', 'operations.notifications', 'reporting.catalog_items', 'api.search_catalog()', 'admin.post_financial_transaction()', '1100_security/1107_grants.sql']::text[]);



\echo '[VALIDATE] 1214_extended_architecture_validation.sql'

SELECT app.assert_table_exists('catalog','part_molds');
SELECT app.assert_table_exists('catalog','part_mold_revisions');
SELECT app.assert_table_exists('catalog','decorated_variants');
SELECT app.assert_table_exists('catalog','item_barcodes');
SELECT app.assert_table_exists('catalog','item_images');
SELECT app.assert_table_exists('catalog','item_relationships');
SELECT app.assert_table_exists('catalog','instruction_assets');
SELECT app.assert_table_exists('catalog','item_search');

SELECT app.assert_table_exists('definition','manifest_subassemblies');
SELECT app.assert_table_exists('definition','manifest_requirement_placements');
SELECT app.assert_table_exists('definition','minifig_compositions');
SELECT app.assert_table_exists('definition','minifig_structural_components');
SELECT app.assert_table_exists('definition','minifig_accessories');

SELECT app.assert_table_exists('marketplace','market_price_observations');
SELECT app.assert_table_exists('marketplace','listings');
SELECT app.assert_table_exists('marketplace','listing_items');
SELECT app.assert_table_exists('marketplace','orders');
SELECT app.assert_table_exists('marketplace','order_items');

SELECT app.assert_table_exists('finance','accounts');
SELECT app.assert_table_exists('finance','transactions');
SELECT app.assert_table_exists('finance','ledger_entries');
SELECT app.assert_table_exists('operations','jobs');
SELECT app.assert_table_exists('operations','notifications');

SELECT app.assert_true(to_regclass('reporting.catalog_items') IS NOT NULL,
    'reporting.catalog_items view is missing');
SELECT app.assert_true(to_regclass('reporting.collection_summary') IS NOT NULL,
    'reporting.collection_summary view is missing');
SELECT app.assert_true(to_regclass('reporting.moc_summary') IS NOT NULL,
    'reporting.moc_summary view is missing');

SELECT app.assert_true(
    EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_trgm'),
    'pg_trgm extension is required for catalog search'
);
SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname='catalog'
          AND tablename='item_search'
          AND indexname='ix_item_search_document'
          AND indexdef ILIKE '%USING gin%'
    ),
    'catalog.item_search full-text GIN index is missing'
);
SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname='catalog'
          AND tablename='item_search'
          AND indexname='ix_item_search_trgm'
          AND indexdef ILIKE '%gin_trgm_ops%'
    ),
    'catalog.item_search trigram index is missing'
);

SELECT app.assert_true(
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname='lego_api'),
    'lego_api role is missing'
);
SELECT app.assert_true(
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname='lego_reporting'),
    'lego_reporting role is missing'
);

DO $$
DECLARE
    v_leak_count bigint;
BEGIN
    SELECT count(*)
      INTO v_leak_count
      FROM information_schema.role_table_grants
     WHERE grantee = 'lego_api'
       AND table_schema IN (
           'identity','reference','catalog','definition','collection','wanted',
           'moc','import','audit','marketplace','finance','operations'
       )
       AND privilege_type IN ('SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER');

    PERFORM app.assert_true(
        v_leak_count = 0,
        format('lego_api must be EXECUTE-only; found %s direct table grants', v_leak_count)
    );
END;
$$;

SELECT app.assert_true(
    has_schema_privilege('lego_reporting','reporting','USAGE'),
    'lego_reporting lacks reporting schema USAGE'
);

SELECT app.assert_true(
    NOT has_schema_privilege('lego_reporting','collection','USAGE'),
    'lego_reporting must not have collection schema USAGE'
);

SELECT app.assert_function_exists('api.search_catalog(text,integer)');
SELECT app.assert_function_exists('api.mark_notification_read(uuid)');
SELECT app.assert_function_exists('admin.post_financial_transaction(text,app.currency_code,text,jsonb,uuid)');
SELECT app.assert_function_exists('definition.validate_manifest_subassembly_acyclic(uuid,uuid)');
SELECT app.assert_function_exists('admin.clone_manifest_graph(uuid,uuid)');
SELECT app.assert_function_exists('admin.set_catalog_item_image(uuid,text,text,boolean,app.sha256_digest)');
SELECT app.assert_function_exists('admin.set_instruction_asset(uuid,text,text,smallint,app.sha256_digest,integer)');

SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='api'
          AND p.proname='transfer_collection_quantity'
          AND p.prokind='p'
    ),
    'api.transfer_collection_quantity procedure is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='audit' AND table_name='events' AND column_name='request_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='audit' AND table_name='events' AND column_name='trace_id'
    ),
    'Audit request/trace correlation columns are missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname='trg_finance_transaction_balance_on_ledger'
          AND NOT tgisinternal
    ),
    'Deferred financial balance trigger is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname='fk_marketplace_listing_item_entry_owner'
          AND conrelid='marketplace.listing_items'::regclass
    ),
    'Marketplace listing item/owner composite FK is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname='fk_minifig_component_decoration'
          AND conrelid='definition.minifig_structural_components'::regclass
    ),
    'Minifigure decorated/base variant composite FK is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname='trg_manifest_subassembly_acyclic'
          AND NOT tgisinternal
    ),
    'Manifest acyclicity trigger is missing'
);

\echo '[PASS] 1214_extended_architecture_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1214_extended_architecture_validation.sql');
