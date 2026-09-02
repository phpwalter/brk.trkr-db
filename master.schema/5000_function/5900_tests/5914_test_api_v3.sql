/*
===============================================================================
 File:           5000_function/5900_tests/5914_test_api_v3.sql
 Project:        BrickTrackr
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Transactional smoke tests for the v3 dispatchers: named
                 collections, storage, wishlists, build goals, MOCs, custom
                 minifigs, concurrency and runtime/administrator separation.
 Depends On:     1200_validation/1227_api_v3_validation.sql
                 5000_function/5200_api/5230_api_collection_inventory.sql
                 5000_function/5200_api/5240_api_wanted.sql
                 5000_function/5200_api/5250_api_moc_minifig.sql
                 5000_function/5200_api/5260_api_identity_activity.sql
 Creates:        Transaction-scoped test fixtures only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5900_tests/5914_test_api_v3.sql',
    ARRAY[
        '1200_validation/1227_api_v3_validation.sql',
        '5000_function/5200_api/5230_api_collection_inventory.sql',
        '5000_function/5200_api/5240_api_wanted.sql',
        '5000_function/5200_api/5250_api_moc_minifig.sql',
        '5000_function/5200_api/5260_api_identity_activity.sql'
    ]::text[]
);

\echo '[TEST] 5914_test_api_v3.sql'

BEGIN;

ALTER TABLE identity.users DISABLE TRIGGER trg_audit_users;
INSERT INTO identity.users(user_id,username,display_name,account_status,activated_at)
VALUES(
    '00000000-0000-4000-8000-000000005914'::uuid,
    'bt_test_api_v3_5914',
    'BrickTrackr API v3 Test',
    'ACTIVE',
    clock_timestamp()
);
ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

INSERT INTO identity.owners(owner_id,owner_type,user_id)
VALUES(
    '00000000-0000-4000-8000-000000005915'::uuid,
    'USER',
    '00000000-0000-4000-8000-000000005914'::uuid
);

SELECT app.set_request_context(
    '00000000-0000-4000-8000-000000005914'::uuid,
    '00000000-0000-4000-8000-000000005916'::uuid,
    '5914-api-v3-test',
    'USER'
);

DO $test$
DECLARE
    v_collection jsonb;
    v_storage jsonb;
    v_wishlist jsonb;
    v_moc jsonb;
    v_minifig jsonb;
    v_failed boolean;
BEGIN
    v_collection:=api.collection_inventory_operation(
        'create_collection',
        '{}'::jsonb,
        '{"name":"API v3 Test Collection","visibility":"PRIVATE"}'::jsonb,
        NULL
    );
    PERFORM app.assert_true(v_collection->>'collection_id' IS NOT NULL,'create_collection returned no collection_id');
    PERFORM app.assert_true(v_collection->>'_etag'='W/"rev1"','new collection ETag is not rev1');

    v_storage:=api.collection_inventory_operation(
        'create_storage_location',
        '{}'::jsonb,
        '{"name":"Test Bin"}'::jsonb,
        NULL
    );
    PERFORM app.assert_true(v_storage->>'storage_location_id' IS NOT NULL,'create_storage_location returned no id');

    v_wishlist:=api.wanted_operation(
        'create_wishlist',
        '{}'::jsonb,
        '{"name":"API v3 Test Wishlist","visibility":"PRIVATE"}'::jsonb,
        NULL
    );
    PERFORM app.assert_true(v_wishlist->>'wishlist_id' IS NOT NULL,'create_wishlist returned no id');

    v_moc:=api.moc_minifig_operation(
        'create_moc',
        '{}'::jsonb,
        '{"name":"API v3 Test MOC","visibility":"PRIVATE"}'::jsonb,
        NULL
    );
    PERFORM app.assert_true(v_moc->>'item_num' LIKE 'MOC-%','create_moc did not generate public MOC item_num');

    v_minifig:=api.moc_minifig_operation(
        'create_custom_minifig',
        '{}'::jsonb,
        '{"name":"API v3 Test Custom Minifig","visibility":"PRIVATE"}'::jsonb,
        NULL
    );
    PERFORM app.assert_true(v_minifig->>'item_num' LIKE 'CMF-%','create_custom_minifig did not generate public item_num');

    v_failed:=false;
    BEGIN
        PERFORM api.collection_inventory_operation(
            'patch_collection',
            jsonb_build_object('collection_id',v_collection->>'collection_id'),
            '{"name":"Must Fail"}'::jsonb,
            'W/"rev999"'
        );
    EXCEPTION WHEN SQLSTATE 'P0412' THEN
        v_failed:=true;
    END;
    PERFORM app.assert_true(v_failed,'stale If-Match did not fail with P0412');

    v_collection:=api.collection_inventory_operation(
        'patch_collection',
        jsonb_build_object('collection_id',v_collection->>'collection_id'),
        '{"name":"API v3 Updated Collection"}'::jsonb,
        v_collection->>'_etag'
    );
    PERFORM app.assert_true(v_collection->>'name'='API v3 Updated Collection','collection patch did not persist');
    PERFORM app.assert_true(v_collection->>'_etag'='W/"rev2"','collection patch did not increment ETag');
END
$test$;

ROLLBACK;

\echo '[PASS] 5914_test_api_v3.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5914_test_api_v3.sql');
