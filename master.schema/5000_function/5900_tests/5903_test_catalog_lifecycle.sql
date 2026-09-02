/*
===============================================================================
 File:           5000_function/5900_tests/5903_test_catalog_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for catalog root/subtype consistency and
                 catalog full-text search projection.
 Depends On:     5000_function/5700_system/5702_system_catalog.sql
                 0300_catalog/0320_catalog_search_media.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5903_test_catalog_lifecycle.sql', ARRAY['5000_function/5700_system/5702_system_catalog.sql', '0300_catalog/0320_catalog_search_media.sql']::text[]);

\echo '[TEST] 5903_test_catalog_lifecycle.sql'

BEGIN;

-- ADMIN actor class never carries an application user UUID (see
-- 5709_system_request_context.sql); no identity.users fixture is required
-- because nothing exercised below performs audited identity writes.
SELECT app.set_request_context(
    NULL,
    '00000000-0000-4000-8000-000000005903'::uuid,
    '5903-catalog-lifecycle-test',
    'ADMIN'
);

DO $$
DECLARE
    v_set_item_id uuid := gen_random_uuid();
    v_part_item_id uuid := gen_random_uuid();
    v_failed boolean;
    v_search_text text;
    v_tsv tsvector;
    v_refreshed_before timestamptz;
    v_refreshed_after timestamptz;
BEGIN
    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES
        (v_set_item_id, 'SET', 'TEST 5903 catalog lifecycle set', 'ACTIVE'),
        (v_part_item_id, 'PART', 'TEST 5903 catalog lifecycle part', 'ACTIVE');

    /* catalog.assert_item_kind: matching kind succeeds. */
    PERFORM catalog.assert_item_kind(v_set_item_id, 'SET'::catalog.item_kind);

    /* catalog.assert_item_kind: mismatched kind rejected. */
    v_failed := false;
    BEGIN
        PERFORM catalog.assert_item_kind(v_set_item_id, 'PART'::catalog.item_kind);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'assert_item_kind() accepted a mismatched item kind');

    /* catalog.assert_item_kind: unknown catalog item rejected. */
    v_failed := false;
    BEGIN
        PERFORM catalog.assert_item_kind(gen_random_uuid(), 'SET'::catalog.item_kind);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'assert_item_kind() accepted an unknown catalog item');

    /* catalog.validate_subtype_kind trigger: matching subtype insert succeeds. */
    INSERT INTO catalog.sets (catalog_item_id, lego_set_id, release_year)
    VALUES (v_set_item_id, 990001, 2024);

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM catalog.sets WHERE catalog_item_id = v_set_item_id
        ),
        'catalog.sets accepted a matching-kind insert but the row is missing'
    );

    /* catalog.validate_subtype_kind trigger: mismatched subtype insert rejected. */
    v_failed := false;
    BEGIN
        INSERT INTO catalog.sets (catalog_item_id, lego_set_id, release_year)
        VALUES (v_part_item_id, 990002, 2024);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_subtype_kind trigger allowed a PART item into catalog.sets');

    /*
     * catalog.trg_refresh_item_search: an AFTER INSERT/UPDATE trigger on
     * catalog.items keeps catalog.item_search synchronized.
     */
    SELECT search_text, search_document
      INTO v_search_text, v_tsv
      FROM catalog.item_search
     WHERE catalog_item_id = v_set_item_id;

    PERFORM app.assert_true(v_search_text IS NOT NULL,
        'trg_refresh_item_search did not populate catalog.item_search on insert');
    PERFORM app.assert_true(
        v_search_text LIKE '%TEST 5903 catalog lifecycle set%',
        'catalog.item_search.search_text does not contain the item canonical_name'
    );
    PERFORM app.assert_true(
        v_tsv @@ to_tsquery('simple', 'catalog'),
        'catalog.item_search.search_document does not match an expected term'
    );

    /* Renaming the item re-fires the trigger and refreshes the projection. */
    UPDATE catalog.items
       SET canonical_name = 'TEST 5903 catalog lifecycle set RENAMED'
     WHERE catalog_item_id = v_set_item_id;

    SELECT search_text
      INTO v_search_text
      FROM catalog.item_search
     WHERE catalog_item_id = v_set_item_id;

    PERFORM app.assert_true(
        v_search_text LIKE '%RENAMED%',
        'trg_refresh_item_search did not refresh search_text on canonical_name update'
    );

    /* catalog.refresh_item_search() is independently callable. */
    SELECT refreshed_at
      INTO v_refreshed_before
      FROM catalog.item_search
     WHERE catalog_item_id = v_set_item_id;

    PERFORM catalog.refresh_item_search(v_set_item_id);

    SELECT refreshed_at
      INTO v_refreshed_after
      FROM catalog.item_search
     WHERE catalog_item_id = v_set_item_id;

    PERFORM app.assert_true(
        v_refreshed_after >= v_refreshed_before,
        'refresh_item_search() called directly did not update refreshed_at'
    );

    /* A PART item with no search row yet is populated by a direct call too. */
    DELETE FROM catalog.item_search WHERE catalog_item_id = v_part_item_id;

    PERFORM catalog.refresh_item_search(v_part_item_id);

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1
              FROM catalog.item_search
             WHERE catalog_item_id = v_part_item_id
               AND search_text LIKE '%TEST 5903 catalog lifecycle part%'
        ),
        'refresh_item_search() did not (re)populate catalog.item_search directly'
    );
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5903_test_catalog_lifecycle.sql');
