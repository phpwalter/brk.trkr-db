/*
===============================================================================
 File:           1200_validation/1221_operational_integrity_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Mechanically enforce operational integrity and critical-index
                 assumptions so future schema changes cannot silently weaken
                 referential enforcement, lifecycle timestamps, uniqueness, or
                 high-volume access paths.
 Depends On:     1200_validation/1220_financial_readiness_validation.sql
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1221_operational_integrity_validation.sql', ARRAY['1200_validation/1220_financial_readiness_validation.sql']::text[]);

\echo '[VALIDATE] 1221_operational_integrity_validation.sql'

/* --------------------------------------------------------------------------
 * Constraint and index health
 * -------------------------------------------------------------------------- */

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_constraint c
          JOIN pg_class r ON r.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = r.relnamespace
         WHERE n.nspname IN (
             'app','identity','reference','catalog','definition','collection',
             'wanted','moc','import','audit','marketplace','finance','operations'
         )
           AND c.contype IN ('c','f')
           AND NOT c.convalidated
    ),
    'Application CHECK/FOREIGN KEY constraints must never remain NOT VALID'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_constraint c
          JOIN pg_class r ON r.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = r.relnamespace
          JOIN pg_trigger t ON t.tgconstraint = c.oid
         WHERE n.nspname IN (
             'identity','reference','catalog','definition','collection',
             'wanted','moc','import','audit','marketplace','finance','operations'
         )
           AND c.contype = 'f'
           AND t.tgenabled = 'D'
    ),
    'Foreign-key enforcement trigger is disabled'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_index i
          JOIN pg_class idx ON idx.oid = i.indexrelid
          JOIN pg_class tbl ON tbl.oid = i.indrelid
          JOIN pg_namespace n ON n.oid = tbl.relnamespace
         WHERE n.nspname IN (
             'app','identity','reference','catalog','definition','collection',
             'wanted','moc','import','audit','marketplace','finance','operations'
         )
           AND (NOT i.indisvalid OR NOT i.indisready)
    ),
    'Application schema contains an invalid or not-ready index'
);

/* Every persistent business table must retain a primary key. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_class r
          JOIN pg_namespace n ON n.oid = r.relnamespace
         WHERE n.nspname IN (
             'identity','reference','catalog','definition','collection',
             'wanted','moc','import','audit','marketplace','finance','operations'
         )
           AND r.relkind IN ('r','p')
           AND NOT EXISTS (
               SELECT 1
                 FROM pg_constraint c
                WHERE c.conrelid = r.oid
                  AND c.contype = 'p'
           )
    ),
    'Every persistent business table must have a primary key'
);

/* Lifecycle/event timestamps are always timezone-aware. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_attribute a
          JOIN pg_class r ON r.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = r.relnamespace
         WHERE n.nspname IN (
             'identity','reference','catalog','definition','collection',
             'wanted','moc','import','audit','marketplace','finance','operations'
         )
           AND r.relkind IN ('r','p')
           AND a.attnum > 0
           AND NOT a.attisdropped
           AND right(a.attname, 3) = '_at'
           AND a.atttypid <> 'timestamptz'::regtype
    ),
    'Columns ending in _at must use timestamptz'
);

/* --------------------------------------------------------------------------
 * Critical uniqueness contract
 * -------------------------------------------------------------------------- */
DO $$
DECLARE
    v_schema text;
    v_table text;
    v_constraint text;
BEGIN
    FOR v_schema, v_table, v_constraint IN
        SELECT *
          FROM (VALUES
              ('identity','users','uq_users_username'),
              ('identity','users','uq_users_email'),
              ('identity','user_sessions','uq_user_sessions_hash'),
              ('identity','one_time_tokens','uq_one_time_tokens_hash')
          ) AS x(schema_name, table_name, constraint_name)
    LOOP
        PERFORM app.assert_true(
            EXISTS (
                SELECT 1
                  FROM pg_constraint c
                  JOIN pg_class r ON r.oid = c.conrelid
                  JOIN pg_namespace n ON n.oid = r.relnamespace
                 WHERE n.nspname = v_schema
                   AND r.relname = v_table
                   AND c.conname = v_constraint
                   AND c.contype = 'u'
            ),
            format('Required uniqueness contract missing: %I.%I constraint %I',
                   v_schema, v_table, v_constraint)
        );
    END LOOP;
END;
$$;

/* --------------------------------------------------------------------------
 * Critical query-path index contract.
 *
 * This is deliberately curated rather than requiring an index for every FK.
 * Each row represents a user-visible or operationally important access path.
 * Any replacement must update this reviewed contract intentionally.
 * -------------------------------------------------------------------------- */
DO $$
DECLARE
    v record;
    v_actual_columns text[];
    v_index_oid oid;
    v_table_oid oid;
    v_valid boolean;
    v_ready boolean;
    v_unique boolean;
    v_has_predicate boolean;
BEGIN
    FOR v IN
        SELECT *
          FROM (VALUES
            ('identity','user_sessions','ix_user_sessions_active',ARRAY['user_id','expires_at']::text[],false,true,
             'active session lookup'),
            ('identity','family_memberships','ix_family_memberships_family',ARRAY['family_id','membership_status']::text[],false,false,
             'family membership authorization'),
            ('catalog','items','ix_catalog_items_kind_status',ARRAY['item_kind','status']::text[],false,false,
             'catalog browse/filter'),
            ('collection','entries','ix_collection_entries_owner',ARRAY['owner_id','status']::text[],false,false,
             'owner collection browse'),
            ('collection','instances','ix_collection_instances_entry',ARRAY['collection_entry_id']::text[],false,false,
             'entry instance expansion'),
            ('wanted','wishlist_entries','ix_wishlist_entries_wishlist',ARRAY['wishlist_id','status']::text[],false,false,
             'wishlist browse'),
            ('moc','revisions','ix_moc_revisions_moc',ARRAY['moc_id','revision_number']::text[],false,false,
             'latest MOC revision lookup'),
            ('import','jobs','ix_import_jobs_owner',ARRAY['owner_id','created_at']::text[],false,false,
             'owner import history'),
            ('audit','events','ix_audit_events_entity',ARRAY['entity_schema','entity_table','entity_id']::text[],false,false,
             'entity audit history'),
            ('operations','jobs','ix_operations_jobs_dispatch',ARRAY['priority','available_at','created_at']::text[],false,true,
             'queued job dispatch'),
            ('finance','ledger_entries','ix_finance_ledger_account',ARRAY['financial_account_id','created_at']::text[],false,false,
             'account ledger history'),
            ('marketplace','listings','ix_marketplace_listings_seller_status',ARRAY['seller_owner_id','status','created_at']::text[],false,false,
             'seller listing browse')
          ) AS c(
              schema_name, table_name, index_name, leading_columns,
              unique_required, predicate_required, purpose
          )
    LOOP
        SELECT idx.oid, tbl.oid, i.indisvalid, i.indisready, i.indisunique,
               (i.indpred IS NOT NULL)
          INTO v_index_oid, v_table_oid, v_valid, v_ready, v_unique, v_has_predicate
          FROM pg_class idx
          JOIN pg_namespace ni ON ni.oid = idx.relnamespace
          JOIN pg_index i ON i.indexrelid = idx.oid
          JOIN pg_class tbl ON tbl.oid = i.indrelid
          JOIN pg_namespace nt ON nt.oid = tbl.relnamespace
         WHERE ni.nspname = v.schema_name
           AND nt.nspname = v.schema_name
           AND tbl.relname = v.table_name
           AND idx.relname = v.index_name;

        PERFORM app.assert_true(
            v_index_oid IS NOT NULL,
            format('Critical index missing: %I.%I (%s)',
                   v.schema_name, v.index_name, v.purpose)
        );

        SELECT array_agg(a.attname ORDER BY k.ordinality)
          INTO v_actual_columns
          FROM pg_index i
          CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ordinality)
          JOIN pg_attribute a
            ON a.attrelid = i.indrelid
           AND a.attnum = k.attnum
         WHERE i.indexrelid = v_index_oid
           AND k.ordinality <= cardinality(v.leading_columns);

        PERFORM app.assert_true(
            v_actual_columns = v.leading_columns,
            format('Critical index %I.%I leading columns changed: expected %s, got %s',
                   v.schema_name, v.index_name,
                   v.leading_columns, v_actual_columns)
        );

        PERFORM app.assert_true(
            v_valid AND v_ready,
            format('Critical index %I.%I is not valid/ready',
                   v.schema_name, v.index_name)
        );

        PERFORM app.assert_true(
            (NOT v.unique_required) OR v_unique,
            format('Critical index %I.%I must remain UNIQUE',
                   v.schema_name, v.index_name)
        );

        PERFORM app.assert_true(
            (NOT v.predicate_required) OR v_has_predicate,
            format('Critical index %I.%I must remain partial/predicate-scoped',
                   v.schema_name, v.index_name)
        );
    END LOOP;
END;
$$;

\echo '[PASS] 1221_operational_integrity_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1221_operational_integrity_validation.sql');
