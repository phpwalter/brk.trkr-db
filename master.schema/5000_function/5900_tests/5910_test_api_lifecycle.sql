/*
===============================================================================
 File:           5000_function/5900_tests/5910_test_api_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for the api.* runtime surface: MOC visibility
                 boundaries, catalog search, notification acknowledgement and
                 collection quantity transfer.
 Depends On:     5000_function/5200_api/5200_api_moc_access.sql
                 5000_function/5200_api/5210_api_operational.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5910_test_api_lifecycle.sql', ARRAY['5000_function/5200_api/5200_api_moc_access.sql', '5000_function/5200_api/5210_api_operational.sql']::text[]);

\echo '[TEST] 5910_test_api_lifecycle.sql'

BEGIN;

/*
 * Establish real authenticated application actors for owner/visibility
 * coverage. identity.users is itself audited, so disable only its audit
 * trigger for the fixture insert. This entire test runs inside a
 * transaction and rolls back.
 */
ALTER TABLE identity.users DISABLE TRIGGER trg_audit_users;

INSERT INTO identity.users (
    user_id, username, display_name, account_status, activated_at
)
VALUES
    ('00000000-0000-4000-8000-000000005910'::uuid, 'bt_test_api_owner_5910', 'BrickTrackr API Test Owner', 'ACTIVE', clock_timestamp()),
    ('00000000-0000-4000-8000-000000005913'::uuid, 'bt_test_api_stranger_5910', 'BrickTrackr API Test Stranger', 'ACTIVE', clock_timestamp());

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

-- ADMIN actor class never carries an application user UUID (see
-- 5709_system_request_context.sql). The fixture rows above are used to
-- establish real USER contexts later in this test via app.set_request_context.
SELECT app.set_request_context(
    NULL,
    '00000000-0000-4000-8000-000000005912'::uuid,
    '5910-api-lifecycle-test',
    'ADMIN'
);

DO $$
DECLARE
    v_owner_user_id uuid := '00000000-0000-4000-8000-000000005910'::uuid;
    v_stranger_user_id uuid := '00000000-0000-4000-8000-000000005913'::uuid;
    v_owner_owner_id uuid;
    v_stranger_owner_id uuid;
    v_family_id uuid := gen_random_uuid();
    v_family_owner_id uuid;

    v_pub_item_id uuid := gen_random_uuid();
    v_pub_moc_id uuid := gen_random_uuid();
    v_pub_definition_id uuid := gen_random_uuid();
    v_pub_version_id uuid := gen_random_uuid();
    v_pub_revision_id uuid := gen_random_uuid();

    v_unlisted_item_id uuid := gen_random_uuid();
    v_unlisted_moc_id uuid := gen_random_uuid();
    v_unlisted_definition_id uuid := gen_random_uuid();
    v_unlisted_version_id uuid := gen_random_uuid();
    v_unlisted_revision_id uuid := gen_random_uuid();

    v_priv_item_id uuid := gen_random_uuid();
    v_priv_moc_id uuid := gen_random_uuid();
    v_priv_definition_id uuid := gen_random_uuid();
    v_priv_version_id uuid := gen_random_uuid();
    v_priv_revision_id uuid := gen_random_uuid();

    v_part_item_id uuid := gen_random_uuid();

    v_notification_id uuid := gen_random_uuid();
    v_other_notification_id uuid := gen_random_uuid();

    v_entry_full_id uuid := gen_random_uuid();
    v_entry_partial_id uuid := gen_random_uuid();
    v_entry_same_owner_id uuid := gen_random_uuid();
    v_entry_unauth_id uuid := gen_random_uuid();

    v_count integer;
    v_found boolean;
    v_read boolean;
    v_read_at timestamptz;
    v_owner_after uuid;
    v_failed boolean;
BEGIN
    /* -------------------------------------------------------------- */
    /* Fixtures: owners, family (owner_user is PARENT)                 */
    /* -------------------------------------------------------------- */
    INSERT INTO identity.owners (owner_id, owner_type, user_id)
    VALUES (gen_random_uuid(), 'USER', v_owner_user_id)
    RETURNING owner_id INTO v_owner_owner_id;

    INSERT INTO identity.owners (owner_id, owner_type, user_id)
    VALUES (gen_random_uuid(), 'USER', v_stranger_user_id)
    RETURNING owner_id INTO v_stranger_owner_id;

    INSERT INTO identity.families (family_id, family_name, created_by_user_id)
    VALUES (v_family_id, 'TEST family 5910', v_owner_user_id);

    INSERT INTO identity.owners (owner_id, owner_type, family_id)
    VALUES (gen_random_uuid(), 'FAMILY', v_family_id)
    RETURNING owner_id INTO v_family_owner_id;

    INSERT INTO identity.family_memberships (
        family_id, user_id, member_role, membership_status
    )
    VALUES (v_family_id, v_owner_user_id, 'PARENT', 'ACTIVE');

    /* -------------------------------------------------------------- */
    /* Fixtures: PUBLIC MOC with a published revision + subordinates   */
    /* -------------------------------------------------------------- */
    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES (v_pub_item_id, 'MOC', 'TEST public MOC 5910', 'ACTIVE');
    INSERT INTO catalog.mocs (catalog_item_id) VALUES (v_pub_item_id);

    INSERT INTO moc.mocs (
        moc_id, catalog_item_id, owner_id, title, visibility, created_by_user_id
    )
    VALUES (
        v_pub_moc_id, v_pub_item_id, v_owner_owner_id, 'TEST public MOC 5910',
        'PUBLIC', v_owner_user_id
    );

    INSERT INTO definition.inventory_definitions (
        inventory_definition_id, catalog_item_id, definition_kind
    )
    VALUES (v_pub_definition_id, v_pub_item_id, 'MOC_MANIFEST');

    INSERT INTO definition.inventory_versions (
        inventory_version_id, inventory_definition_id, semantic_version,
        semantic_hash, status, finalized_at
    )
    VALUES (
        v_pub_version_id, v_pub_definition_id, 1,
        public.digest(pg_catalog.convert_to('pub-moc-5910-v1', 'UTF8'), 'sha256'),
        'FINALIZED', clock_timestamp()
    );

    INSERT INTO moc.revisions (
        moc_revision_id, moc_id, revision_number, inventory_version_id,
        status, semantic_hash, created_by_user_id, published_at
    )
    VALUES (
        v_pub_revision_id, v_pub_moc_id, 1, v_pub_version_id,
        'PUBLISHED',
        public.digest(pg_catalog.convert_to('pub-moc-5910-rev1', 'UTF8'), 'sha256'),
        v_owner_user_id, clock_timestamp()
    );

    INSERT INTO moc.assets (moc_revision_id, asset_type, storage_key, original_filename)
    VALUES (v_pub_revision_id, 'MODEL_FILE', 'test/5910/pub-asset.io', 'pub-asset.io');

    INSERT INTO moc.licenses (moc_revision_id, license_type, applies_to_design)
    VALUES (v_pub_revision_id, 'CC_BY', true);

    INSERT INTO moc.subassemblies (moc_revision_id, subassembly_name)
    VALUES (v_pub_revision_id, 'TEST main build 5910');

    /* -------------------------------------------------------------- */
    /* Fixtures: UNLISTED MOC with a published revision                */
    /* -------------------------------------------------------------- */
    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES (v_unlisted_item_id, 'MOC', 'TEST unlisted MOC 5910', 'ACTIVE');
    INSERT INTO catalog.mocs (catalog_item_id) VALUES (v_unlisted_item_id);

    INSERT INTO moc.mocs (
        moc_id, catalog_item_id, owner_id, title, visibility, created_by_user_id
    )
    VALUES (
        v_unlisted_moc_id, v_unlisted_item_id, v_owner_owner_id, 'TEST unlisted MOC 5910',
        'UNLISTED', v_owner_user_id
    );

    INSERT INTO definition.inventory_definitions (
        inventory_definition_id, catalog_item_id, definition_kind
    )
    VALUES (v_unlisted_definition_id, v_unlisted_item_id, 'MOC_MANIFEST');

    INSERT INTO definition.inventory_versions (
        inventory_version_id, inventory_definition_id, semantic_version,
        semantic_hash, status, finalized_at
    )
    VALUES (
        v_unlisted_version_id, v_unlisted_definition_id, 1,
        public.digest(pg_catalog.convert_to('unlisted-moc-5910-v1', 'UTF8'), 'sha256'),
        'FINALIZED', clock_timestamp()
    );

    INSERT INTO moc.revisions (
        moc_revision_id, moc_id, revision_number, inventory_version_id,
        status, semantic_hash, created_by_user_id, published_at
    )
    VALUES (
        v_unlisted_revision_id, v_unlisted_moc_id, 1, v_unlisted_version_id,
        'PUBLISHED',
        public.digest(pg_catalog.convert_to('unlisted-moc-5910-rev1', 'UTF8'), 'sha256'),
        v_owner_user_id, clock_timestamp()
    );

    /* -------------------------------------------------------------- */
    /* Fixtures: PRIVATE MOC with a published revision + subordinates  */
    /* -------------------------------------------------------------- */
    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES (v_priv_item_id, 'MOC', 'TEST private MOC 5910', 'ACTIVE');
    INSERT INTO catalog.mocs (catalog_item_id) VALUES (v_priv_item_id);

    INSERT INTO moc.mocs (
        moc_id, catalog_item_id, owner_id, title, visibility, created_by_user_id
    )
    VALUES (
        v_priv_moc_id, v_priv_item_id, v_owner_owner_id, 'TEST private MOC 5910',
        'PRIVATE', v_owner_user_id
    );

    INSERT INTO definition.inventory_definitions (
        inventory_definition_id, catalog_item_id, definition_kind
    )
    VALUES (v_priv_definition_id, v_priv_item_id, 'MOC_MANIFEST');

    INSERT INTO definition.inventory_versions (
        inventory_version_id, inventory_definition_id, semantic_version,
        semantic_hash, status, finalized_at
    )
    VALUES (
        v_priv_version_id, v_priv_definition_id, 1,
        public.digest(pg_catalog.convert_to('priv-moc-5910-v1', 'UTF8'), 'sha256'),
        'FINALIZED', clock_timestamp()
    );

    INSERT INTO moc.revisions (
        moc_revision_id, moc_id, revision_number, inventory_version_id,
        status, semantic_hash, created_by_user_id, published_at
    )
    VALUES (
        v_priv_revision_id, v_priv_moc_id, 1, v_priv_version_id,
        'PUBLISHED',
        public.digest(pg_catalog.convert_to('priv-moc-5910-rev1', 'UTF8'), 'sha256'),
        v_owner_user_id, clock_timestamp()
    );

    INSERT INTO moc.assets (moc_revision_id, asset_type, storage_key, original_filename)
    VALUES (v_priv_revision_id, 'MODEL_FILE', 'test/5910/priv-asset.io', 'priv-asset.io');

    INSERT INTO moc.licenses (moc_revision_id, license_type, applies_to_design)
    VALUES (v_priv_revision_id, 'CC_BY', true);

    INSERT INTO moc.subassemblies (moc_revision_id, subassembly_name)
    VALUES (v_priv_revision_id, 'TEST private build 5910');

    /* -------------------------------------------------------------- */
    /* Fixtures: searchable catalog item, notifications, entries       */
    /* -------------------------------------------------------------- */
    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES (v_part_item_id, 'PART', 'TEST Search Widget 5910', 'ACTIVE');

    INSERT INTO operations.notifications (
        notification_id, user_id, owner_id, notification_type, title
    )
    VALUES (v_notification_id, v_owner_user_id, v_owner_owner_id, 'TEST', 'TEST notification 5910');

    INSERT INTO operations.notifications (
        notification_id, user_id, owner_id, notification_type, title
    )
    VALUES (v_other_notification_id, v_stranger_user_id, v_stranger_owner_id, 'TEST', 'TEST stranger notification 5910');

    INSERT INTO collection.entries (collection_entry_id, owner_id, catalog_item_id, quantity)
    VALUES
        (v_entry_full_id, v_owner_owner_id, v_part_item_id, 5),
        (v_entry_partial_id, v_owner_owner_id, v_part_item_id, 2),
        (v_entry_same_owner_id, v_owner_owner_id, v_part_item_id, 3),
        (v_entry_unauth_id, v_owner_owner_id, v_part_item_id, 1);

    /* ================================================================ */
    /* Phase 1: anonymous access under ADMIN/no-user context             */
    /* ================================================================ */

    SELECT count(*) INTO v_count FROM api.get_moc_by_id(v_pub_moc_id);
    PERFORM app.assert_true(v_count = 1, 'PUBLIC MOC not visible to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_by_id(v_unlisted_moc_id);
    PERFORM app.assert_true(v_count = 1, 'UNLISTED MOC not visible to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_by_id(v_priv_moc_id);
    PERFORM app.assert_true(v_count = 0, 'PRIVATE MOC leaked to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_revisions(v_pub_moc_id);
    PERFORM app.assert_true(v_count = 1, 'PUBLIC MOC published revision not visible to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_revisions(v_priv_moc_id);
    PERFORM app.assert_true(v_count = 0, 'PRIVATE MOC revision leaked to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_assets(v_pub_moc_id, v_pub_revision_id);
    PERFORM app.assert_true(v_count = 1, 'PUBLIC MOC assets not visible to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_licenses(v_pub_moc_id, v_pub_revision_id);
    PERFORM app.assert_true(v_count = 1, 'PUBLIC MOC licenses not visible to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_subassemblies(v_pub_moc_id, v_pub_revision_id);
    PERFORM app.assert_true(v_count = 1, 'PUBLIC MOC subassemblies not visible to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_assets(v_priv_moc_id, v_priv_revision_id);
    PERFORM app.assert_true(v_count = 0, 'PRIVATE MOC assets leaked to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_licenses(v_priv_moc_id, v_priv_revision_id);
    PERFORM app.assert_true(v_count = 0, 'PRIVATE MOC licenses leaked to anonymous caller');

    SELECT count(*) INTO v_count FROM api.get_moc_subassemblies(v_priv_moc_id, v_priv_revision_id);
    PERFORM app.assert_true(v_count = 0, 'PRIVATE MOC subassemblies leaked to anonymous caller');

    SELECT count(*) INTO v_count
      FROM api.search_catalog('Search Widget', 10)
     WHERE catalog_item_id = v_part_item_id;
    PERFORM app.assert_true(v_count = 1, 'api.search_catalog() did not find the fixture catalog item');

    /* Fail-closed identity guard: no user context established yet. */
    v_failed := false;
    BEGIN
        PERFORM api.mark_notification_read(v_notification_id);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '28000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'api.mark_notification_read() did not fail closed without a user context');

    v_failed := false;
    BEGIN
        CALL api.transfer_collection_quantity(v_entry_full_id, v_family_owner_id, 1, 'no context test');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '28000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'api.transfer_collection_quantity() did not fail closed without a user context');

    /* ================================================================ */
    /* Phase 2: authenticated owner context                              */
    /* ================================================================ */
    PERFORM app.set_request_context(
        v_owner_user_id,
        gen_random_uuid(),
        '5910-api-lifecycle-test-owner',
        'USER'
    );

    SELECT count(*) INTO v_count FROM api.get_moc_by_id(v_priv_moc_id);
    PERFORM app.assert_true(v_count = 1, 'Owner could not see own PRIVATE MOC');

    SELECT count(*) INTO v_count FROM api.get_moc_assets(v_priv_moc_id, v_priv_revision_id);
    PERFORM app.assert_true(v_count = 1, 'Owner could not see own PRIVATE MOC assets');

    /* Notifications: owned, not-owned and unknown. */
    v_read := api.mark_notification_read(v_notification_id);
    PERFORM app.assert_true(v_read, 'api.mark_notification_read() did not mark the caller-owned notification read');

    SELECT is_read, read_at INTO v_found, v_read_at
      FROM operations.notifications
     WHERE notification_id = v_notification_id;
    PERFORM app.assert_true(v_found, 'Notification row was not marked is_read');
    PERFORM app.assert_true(v_read_at IS NOT NULL, 'Notification row read_at was not set');

    v_read := api.mark_notification_read(v_notification_id);
    PERFORM app.assert_true(v_read, 'api.mark_notification_read() is not idempotent on an already-read notification');

    v_read := api.mark_notification_read(v_other_notification_id);
    PERFORM app.assert_true(NOT v_read, 'api.mark_notification_read() marked a notification owned by another user');

    v_read := api.mark_notification_read(gen_random_uuid());
    PERFORM app.assert_true(NOT v_read, 'api.mark_notification_read() reported success for an unknown notification');

    /* Collection transfers: happy path (full quantity, to a family the owner parents). */
    CALL api.transfer_collection_quantity(v_entry_full_id, v_family_owner_id, 5, 'TEST full transfer 5910');

    SELECT owner_id INTO v_owner_after
      FROM collection.entries
     WHERE collection_entry_id = v_entry_full_id;
    PERFORM app.assert_true(v_owner_after = v_family_owner_id,
        'api.transfer_collection_quantity() did not reassign the collection entry owner');

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM collection.transfers
             WHERE collection_entry_id = v_entry_full_id
               AND reason = 'TEST full transfer 5910'
        ),
        'api.transfer_collection_quantity() did not record a transfer row'
    );

    /* Collection transfers: negative paths. */
    v_failed := false;
    BEGIN
        CALL api.transfer_collection_quantity(v_entry_partial_id, v_family_owner_id, 5, 'exceeds available');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23514' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'api.transfer_collection_quantity() accepted a quantity exceeding what is available');

    v_failed := false;
    BEGIN
        CALL api.transfer_collection_quantity(v_entry_same_owner_id, v_owner_owner_id, 1, 'same owner');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23514' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'api.transfer_collection_quantity() accepted a transfer to the same owner');

    v_failed := false;
    BEGIN
        CALL api.transfer_collection_quantity(gen_random_uuid(), v_family_owner_id, 1, 'unknown entry');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0002' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'api.transfer_collection_quantity() did not reject an unknown collection entry');

    /* ================================================================ */
    /* Phase 3: unrelated user context (no ownership, no family ties)    */
    /* ================================================================ */
    PERFORM app.set_request_context(
        v_stranger_user_id,
        gen_random_uuid(),
        '5910-api-lifecycle-test-stranger',
        'USER'
    );

    SELECT count(*) INTO v_count FROM api.get_moc_by_id(v_priv_moc_id);
    PERFORM app.assert_true(v_count = 0, 'PRIVATE MOC leaked to an unrelated authenticated caller');

    v_failed := false;
    BEGIN
        CALL api.transfer_collection_quantity(v_entry_unauth_id, v_stranger_owner_id, 1, 'unauthorized transfer');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '42501' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'api.transfer_collection_quantity() allowed an unauthorized transfer of another owner''s entry');
END;
$$;

/* Runtime roles without brktrkr_api authority must not reach the api.* surface. */
DO $$
DECLARE
    v_role name;
    v_failed boolean;
BEGIN
    FOR v_role IN
        SELECT rolname
          FROM pg_roles
         WHERE rolname IN ('brktrkr_import','brktrkr_reporting')
         ORDER BY rolname
    LOOP
        v_failed := false;
        EXECUTE format('SET LOCAL ROLE %I', v_role);

        BEGIN
            PERFORM api.search_catalog('anything', 1);
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLSTATE IN ('42501','42883') THEN
                    v_failed := true;
                ELSE
                    RESET ROLE;
                    RAISE;
                END IF;
        END;

        RESET ROLE;

        PERFORM app.assert_true(
            v_failed,
            format('%s was able to invoke api.search_catalog() without brktrkr_api authority', v_role)
        );
    END LOOP;
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5910_test_api_lifecycle.sql');
