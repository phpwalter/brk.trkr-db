/*
===============================================================================
 File:           5000_function/5900_tests/5913_test_reporting_lifecycle.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Behavioral tests for the reporting schema: incremental
                 system/aggregate summary maintenance plus direct-invocation
                 coverage of every reporting read/recompute routine.
 Depends On:     1000_reporting/1010_reporting_system_summary.sql
                 1000_reporting/1011_reporting_aggregate_tables.sql
                 5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5913_test_reporting_lifecycle.sql', ARRAY['1000_reporting/1010_reporting_system_summary.sql', '1000_reporting/1011_reporting_aggregate_tables.sql', '5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql']::text[]);

\echo '[TEST] 5913_test_reporting_lifecycle.sql'

BEGIN;

/*
 * Establish a real authenticated application actor for audit-trigger coverage.
 *
 * identity.users is itself audited, so disable only its audit trigger for the
 * fixture insert. This entire test runs inside a transaction and rolls back.
 */
ALTER TABLE identity.users DISABLE TRIGGER trg_audit_users;

INSERT INTO identity.users (
    user_id,
    username,
    display_name,
    account_status,
    activated_at
)
VALUES (
    '00000000-0000-4000-8000-000000005913'::uuid,
    'bt_test_reporting_5913',
    'BrickTrackr Reporting Lifecycle Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

-- SYSTEM actor class never carries an application user UUID (see
-- 5709_system_request_context.sql); the identity.users fixture row above
-- exists for audit-trigger coverage, not for context establishment.
SELECT app.set_request_context(
    NULL,
    '00000000-0000-4000-8000-000000005914'::uuid,
    '5913-reporting-lifecycle-test',
    'SYSTEM'
);


/* ============================================================================
 * ===== reporting.get_system_summary() =====
 *
 * Migrated from 5980_test_system_summary.sql. Proves catalog.items DML is
 * reflected incrementally through the trg_system_summary_catalog_* triggers.
 * ============================================================================
 */
DO $$
DECLARE
    v_before jsonb;
    v_after jsonb;
    v_id uuid := app.uuid_v7();
BEGIN
    SELECT reporting.get_system_summary() INTO v_before;

    INSERT INTO catalog.items(
        catalog_item_id, item_kind, canonical_name, status
    )
    VALUES (
        v_id, 'INSTRUCTIONS', 'Summary trigger test instructions', 'ACTIVE'
    );

    SELECT reporting.get_system_summary() INTO v_after;

    PERFORM app.assert_true(
        (v_after->>'total_catalog_items')::bigint =
        (v_before->>'total_catalog_items')::bigint + 1,
        'catalog insert did not increment total_catalog_items'
    );

    PERFORM app.assert_true(
        (v_after->>'total_instructions')::bigint =
        (v_before->>'total_instructions')::bigint + 1,
        'INSTRUCTIONS insert did not increment total_instructions'
    );

    PERFORM app.assert_true(
        (v_after->>'active_catalog_items')::bigint =
        (v_before->>'active_catalog_items')::bigint + 1,
        'ACTIVE insert did not increment active_catalog_items'
    );

    UPDATE catalog.items
       SET status = 'RETIRED'
     WHERE catalog_item_id = v_id;

    SELECT reporting.get_system_summary() INTO v_after;

    PERFORM app.assert_true(
        (v_after->>'active_catalog_items')::bigint =
        (v_before->>'active_catalog_items')::bigint,
        'ACTIVE -> RETIRED did not decrement active count'
    );

    PERFORM app.assert_true(
        (v_after->>'retired_catalog_items')::bigint =
        (v_before->>'retired_catalog_items')::bigint + 1,
        'ACTIVE -> RETIRED did not increment retired count'
    );
END;
$$;


/* ============================================================================
 * ===== reporting.catalog_kind_summary maintenance =====
 *
 * Migrated from 5981_test_aggregate_tables.sql. Proves the
 * trg_aggregate_catalog_* statement triggers keep catalog_kind_summary in
 * sync with catalog.items.
 * ============================================================================
 */
DO $$
DECLARE
    v_id uuid := app.uuid_v7();
    v_before bigint;
    v_after bigint;
BEGIN
    SELECT total_items
      INTO v_before
      FROM reporting.catalog_kind_summary
     WHERE item_kind = 'INSTRUCTIONS';

    INSERT INTO catalog.items(
        catalog_item_id,
        item_kind,
        canonical_name,
        status
    )
    VALUES (
        v_id,
        'INSTRUCTIONS',
        'Aggregate table test instructions',
        'ACTIVE'
    );

    SELECT total_items
      INTO v_after
      FROM reporting.catalog_kind_summary
     WHERE item_kind = 'INSTRUCTIONS';

    PERFORM app.assert_true(
        v_after = v_before + 1,
        'catalog_kind_summary did not increment INSTRUCTIONS total'
    );

    PERFORM app.assert_true(
        (
            SELECT active_items
            FROM reporting.catalog_kind_summary
            WHERE item_kind = 'INSTRUCTIONS'
        ) >= 1,
        'catalog_kind_summary did not increment ACTIVE INSTRUCTIONS'
    );

    UPDATE catalog.items
       SET status = 'RETIRED'
     WHERE catalog_item_id = v_id;

    PERFORM app.assert_true(
        (
            SELECT retired_items
            FROM reporting.catalog_kind_summary
            WHERE item_kind = 'INSTRUCTIONS'
        ) >= 1,
        'catalog_kind_summary did not track ACTIVE -> RETIRED'
    );
END;
$$;


/* ============================================================================
 * ===== reporting.get_catalog_kind_summary() =====
 *
 * Gap: previously never invoked directly by any test. Seed distinct kinds
 * and confirm the read surface matches the maintained table exactly.
 * ============================================================================
 */
DO $$
DECLARE
    v_part_id uuid := app.uuid_v7();
    v_moc_id uuid := app.uuid_v7();
    v_mismatch_count integer;
BEGIN
    INSERT INTO catalog.items(
        catalog_item_id, item_kind, canonical_name, status
    )
    VALUES
        (v_part_id, 'PART', 'Catalog kind summary test part', 'ACTIVE'),
        (v_moc_id, 'MOC', 'Catalog kind summary test MOC', 'RETIRED');

    SELECT count(*)
      INTO v_mismatch_count
      FROM reporting.get_catalog_kind_summary() g
      FULL JOIN reporting.catalog_kind_summary t
        USING (item_kind)
     WHERE g.item_kind IS DISTINCT FROM t.item_kind
        OR g.total_items IS DISTINCT FROM t.total_items
        OR g.active_items IS DISTINCT FROM t.active_items
        OR g.retired_items IS DISTINCT FROM t.retired_items
        OR g.source_missing_items IS DISTINCT FROM t.source_missing_items
        OR g.unresolved_custom_items IS DISTINCT FROM t.unresolved_custom_items
        OR g.archived_items IS DISTINCT FROM t.archived_items;

    PERFORM app.assert_true(
        v_mismatch_count = 0,
        'get_catalog_kind_summary() does not match catalog_kind_summary table contents'
    );

    PERFORM app.assert_true(
        (
            SELECT active_items
            FROM reporting.get_catalog_kind_summary()
            WHERE item_kind = 'PART'
        ) >= 1,
        'get_catalog_kind_summary() did not reflect the seeded ACTIVE PART'
    );

    PERFORM app.assert_true(
        (
            SELECT retired_items
            FROM reporting.get_catalog_kind_summary()
            WHERE item_kind = 'MOC'
        ) >= 1,
        'get_catalog_kind_summary() did not reflect the seeded RETIRED MOC'
    );
END;
$$;


/* ============================================================================
 * ===== reporting.get_import_summary(integer) =====
 *
 * Gap: previously never invoked directly. Seed source runs (which populate
 * reporting.import_summary via trg_import_summary_source_run), then exercise
 * both normal bounds and the documented 1-500 clamp.
 * ============================================================================
 */
DO $$
DECLARE
    v_source_id smallint;
    v_run_1 uuid := app.uuid_v7();
    v_run_2 uuid := app.uuid_v7();
    v_run_3 uuid := app.uuid_v7();
    v_seen_count integer;
    v_total_rows bigint;
    v_low_count integer;
    v_high_count integer;
BEGIN
    SELECT source_id
      INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    PERFORM app.assert_true(
        v_source_id IS NOT NULL,
        'REBRICKABLE external source is not seeded'
    );

    INSERT INTO import.source_runs(
        source_run_id, source_id, status, started_at
    )
    VALUES
        (v_run_1, v_source_id, 'STARTED', clock_timestamp()),
        (v_run_2, v_source_id, 'STARTED', clock_timestamp()),
        (v_run_3, v_source_id, 'STARTED', clock_timestamp());

    SELECT count(*)
      INTO v_seen_count
      FROM reporting.get_import_summary(10)
     WHERE source_run_id IN (v_run_1, v_run_2, v_run_3);

    PERFORM app.assert_true(
        v_seen_count = 3,
        'get_import_summary(10) did not return the seeded source runs'
    );

    SELECT count(*)
      INTO v_total_rows
      FROM reporting.import_summary;

    /* Documented bound: p_limit is clamped to [1, 500]. */
    SELECT count(*) INTO v_low_count FROM reporting.get_import_summary(0);
    PERFORM app.assert_true(
        v_low_count = 1,
        'get_import_summary(0) did not clamp to a minimum of 1 row'
    );

    SELECT count(*) INTO v_high_count FROM reporting.get_import_summary(501);
    PERFORM app.assert_true(
        v_high_count = LEAST(v_total_rows, 500),
        'get_import_summary(501) did not clamp to a maximum of 500 rows'
    );
END;
$$;


/* ============================================================================
 * ===== reporting.get_owner_summary(uuid) =====
 *
 * Gap: previously never invoked directly. Seed an owner plus a collection
 * entry and a wishlist/wishlist entry (both refresh reporting.owner_summary
 * via trigger cascade already tested indirectly), then confirm the direct
 * read matches.
 *
 * A build-goal fixture was intentionally omitted: wanted.build_goals
 * requires a definition.inventory_versions row, which itself requires a
 * definition.inventory_definitions row -- too deep a fixture chain to justify
 * here. active_build_goal_count is exercised as a stable zero instead.
 * ============================================================================
 */
DO $$
DECLARE
    v_owner_id uuid;
    v_item_id uuid := app.uuid_v7();
    v_wishlist_item_id uuid := app.uuid_v7();
    v_wishlist_id uuid := app.uuid_v7();
    v_summary reporting.owner_summary;
BEGIN
    v_owner_id := identity.ensure_owner_for_user(
        '00000000-0000-4000-8000-000000005913'::uuid
    );

    PERFORM app.assert_true(
        v_owner_id IS NOT NULL,
        'ensure_owner_for_user() did not return an owner_id'
    );

    INSERT INTO catalog.items(
        catalog_item_id, item_kind, canonical_name, status
    )
    VALUES
        (v_item_id, 'PART', 'Owner summary test part', 'ACTIVE'),
        (v_wishlist_item_id, 'PART', 'Owner summary wishlist part', 'ACTIVE');

    INSERT INTO collection.entries(
        owner_id, catalog_item_id, quantity, status
    )
    VALUES (
        v_owner_id, v_item_id, 3, 'ACTIVE'
    );

    INSERT INTO wanted.wishlists(
        wishlist_id, owner_id, wishlist_name
    )
    VALUES (
        v_wishlist_id, v_owner_id, '5913 owner summary test wishlist'
    );

    INSERT INTO wanted.wishlist_entries(
        wishlist_id, catalog_item_id, desired_quantity
    )
    VALUES (
        v_wishlist_id, v_wishlist_item_id, 2
    );

    v_summary := reporting.get_owner_summary(v_owner_id);

    PERFORM app.assert_true(
        v_summary.owner_id = v_owner_id,
        'get_owner_summary() returned the wrong owner'
    );

    PERFORM app.assert_true(
        v_summary.collection_entry_count = 1
        AND v_summary.collection_quantity = 3,
        'get_owner_summary() did not reflect the seeded collection entry'
    );

    PERFORM app.assert_true(
        v_summary.active_wishlist_count = 1
        AND v_summary.active_wishlist_entry_count = 1
        AND v_summary.active_wishlist_desired_quantity = 2,
        'get_owner_summary() did not reflect the seeded wishlist entry'
    );

    PERFORM app.assert_true(
        v_summary.active_build_goal_count = 0,
        'get_owner_summary() unexpectedly reported build goals'
    );

    /* Direct read must match the underlying table row exactly. */
    PERFORM app.assert_true(
        EXISTS (
            SELECT 1
            FROM reporting.owner_summary t
            WHERE t.owner_id = v_owner_id
              AND t.collection_entry_count = v_summary.collection_entry_count
              AND t.collection_quantity = v_summary.collection_quantity
              AND t.active_wishlist_count = v_summary.active_wishlist_count
              AND t.active_wishlist_entry_count = v_summary.active_wishlist_entry_count
              AND t.active_wishlist_desired_quantity = v_summary.active_wishlist_desired_quantity
        ),
        'get_owner_summary() diverged from reporting.owner_summary'
    );
END;
$$;


/* ============================================================================
 * ===== reporting.get_set_manifest_enrichment(text) =====
 *
 * Gap: 5904_test_set_manifest_enrichment.sql only checks that this routine
 * exists (pg_proc/to_regprocedure signature check), never invokes it. Seed a
 * SET catalog item with a REBRICKABLE external identifier plus a
 * definition.set_manifest_components row (the table
 * import.upsert_set_manifest_component would normally populate), then call
 * the function with the bare set number and confirm the enrichment row
 * matches what was seeded.
 * ============================================================================
 */
DO $$
DECLARE
    v_set_id uuid := app.uuid_v7();
    v_source_id smallint;
    v_set_num text := '5913-1';
    v_bare_set_num text := '5913';
    v_component_id uuid;
    v_row record;
    v_row_count integer;
BEGIN
    SELECT source_id
      INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    INSERT INTO catalog.items(
        catalog_item_id, item_kind, canonical_name, status
    )
    VALUES (
        v_set_id, 'SET', '5913 manifest enrichment test set', 'ACTIVE'
    );

    INSERT INTO catalog.external_identifiers(
        source_id, entity_namespace, external_id, catalog_item_id
    )
    VALUES (
        v_source_id, 'SET', v_set_num, v_set_id
    );

    INSERT INTO definition.set_manifest_components(
        set_manifest_component_id,
        set_catalog_item_id,
        component_kind,
        source_code,
        external_id,
        display_name,
        source_url,
        quantity,
        source_present,
        last_seen_at
    )
    VALUES (
        app.uuid_v7(),
        v_set_id,
        'INSTRUCTIONS',
        'REBRICKABLE',
        v_set_num || '-instructions',
        '5913 manifest test instructions',
        'https://rebrickable.com/instructions/5913-1/',
        1,
        true,
        clock_timestamp()
    )
    RETURNING set_manifest_component_id INTO v_component_id;

    SELECT count(*)
      INTO v_row_count
      FROM reporting.get_set_manifest_enrichment(v_bare_set_num);

    PERFORM app.assert_true(
        v_row_count = 1,
        'get_set_manifest_enrichment() did not return the seeded component'
    );

    SELECT *
      INTO v_row
      FROM reporting.get_set_manifest_enrichment(v_bare_set_num);

    PERFORM app.assert_true(
        v_row.component_kind = 'INSTRUCTIONS'
        AND v_row.external_id = v_set_num || '-instructions'
        AND v_row.display_name = '5913 manifest test instructions'
        AND v_row.source_code = 'REBRICKABLE'
        AND v_row.quantity = 1
        AND v_row.source_present = true,
        'get_set_manifest_enrichment() returned data that does not match the seeded component'
    );

    /* Bare set-number matching must also work via the "-1" suffix form. */
    PERFORM app.assert_true(
        (
            SELECT count(*)
            FROM reporting.get_set_manifest_enrichment(v_set_num)
        ) = 1,
        'get_set_manifest_enrichment() did not match the exact "-1" external_id'
    );

    /* Unknown set number returns no rows, not an error. */
    PERFORM app.assert_true(
        (
            SELECT count(*)
            FROM reporting.get_set_manifest_enrichment('no-such-set-9999')
        ) = 0,
        'get_set_manifest_enrichment() returned rows for an unknown set number'
    );
END;
$$;


/* ============================================================================
 * ===== reporting.refresh_owner_summary(uuid) direct invocation =====
 *
 * Gap: previously PERFORM'd only from 5 owner-scoped triggers, never called
 * by name. Corrupt an owner_summary row directly, then confirm the direct
 * call recomputes and corrects it (the fixture owner already has a real
 * collection entry and wishlist from the get_owner_summary() section above).
 * ============================================================================
 */
DO $$
DECLARE
    v_owner_id uuid;
    v_after reporting.owner_summary;
BEGIN
    SELECT owner_id
      INTO v_owner_id
      FROM identity.owners
     WHERE user_id = '00000000-0000-4000-8000-000000005913'::uuid;

    PERFORM app.assert_true(
        v_owner_id IS NOT NULL,
        'Fixture owner from the get_owner_summary() section is missing'
    );

    UPDATE reporting.owner_summary
       SET collection_entry_count = 999,
           collection_quantity = 999,
           active_wishlist_count = 999,
           active_wishlist_entry_count = 999,
           active_wishlist_desired_quantity = 999
     WHERE owner_id = v_owner_id;

    PERFORM app.assert_true(
        (
            SELECT collection_entry_count
            FROM reporting.owner_summary
            WHERE owner_id = v_owner_id
        ) = 999,
        'Corruption setup for refresh_owner_summary() did not take effect'
    );

    PERFORM reporting.refresh_owner_summary(v_owner_id);

    SELECT *
      INTO v_after
      FROM reporting.owner_summary
     WHERE owner_id = v_owner_id;

    PERFORM app.assert_true(
        v_after.collection_entry_count = 1
        AND v_after.collection_quantity = 3,
        'refresh_owner_summary() did not correct the corrupted collection counts'
    );

    PERFORM app.assert_true(
        v_after.active_wishlist_count = 1
        AND v_after.active_wishlist_entry_count = 1
        AND v_after.active_wishlist_desired_quantity = 2,
        'refresh_owner_summary() did not correct the corrupted wishlist counts'
    );

    /* NULL owner_id is a documented no-op, not an error. */
    PERFORM reporting.refresh_owner_summary(NULL);
END;
$$;


/* ============================================================================
 * ===== reporting.rebuild_system_summary() direct invocation =====
 *
 * Gap: zero callers anywhere except its own one-time bootstrap seed call in
 * 1010_reporting_system_summary.sql. Corrupt reporting.system_summary
 * directly, then confirm the direct call recomputes true counts from
 * catalog.items/import.source_runs.
 * ============================================================================
 */
DO $$
DECLARE
    v_true_total bigint;
    v_true_active bigint;
    v_result jsonb;
BEGIN
    SELECT count(*),
           count(*) FILTER (WHERE status = 'ACTIVE')
      INTO v_true_total, v_true_active
      FROM catalog.items;

    UPDATE reporting.system_summary
       SET total_catalog_items = v_true_total + 987654,
           active_catalog_items = 0
     WHERE summary_id = 1;

    PERFORM app.assert_true(
        (
            SELECT total_catalog_items
            FROM reporting.system_summary
            WHERE summary_id = 1
        ) = v_true_total + 987654,
        'Corruption setup for rebuild_system_summary() did not take effect'
    );

    v_result := reporting.rebuild_system_summary();

    PERFORM app.assert_true(
        (v_result->>'total_catalog_items')::bigint = v_true_total,
        'rebuild_system_summary() did not correct total_catalog_items'
    );

    PERFORM app.assert_true(
        (v_result->>'active_catalog_items')::bigint = v_true_active,
        'rebuild_system_summary() did not correct active_catalog_items'
    );

    PERFORM app.assert_true(
        (
            SELECT total_catalog_items
            FROM reporting.system_summary
            WHERE summary_id = 1
        ) = v_true_total,
        'rebuild_system_summary() did not persist the corrected total to the table'
    );
END;
$$;


/*
 * ===== import.accumulate_catalog_summary_delta(...) =====
 *
 * Defined in this same source file (1000_reporting/1011_reporting_aggregate_
 * tables.sql, ~line 222) but is logically an import-schema function. It is
 * covered in 5000_function/5900_tests/5909_test_import_lifecycle.sql instead
 * of here, to avoid duplicate coverage.
 */


ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5913_test_reporting_lifecycle.sql');
\echo '[TEST PASS] 5913_test_reporting_lifecycle.sql'
