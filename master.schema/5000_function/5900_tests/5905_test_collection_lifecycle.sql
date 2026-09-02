/*
===============================================================================
 File:           5000_function/5900_tests/5905_test_collection_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for collection ownership consistency, the
                 explicit loose-part balance projection, storage-location
                 cycle prevention and collection cross-row integrity
                 (instance/adjustment/acquisition/tag/transfer invariants).
 Depends On:     5000_function/5700_system/5704_system_collection.sql
                 5000_function/5700_system/5701_system_hierarchy.sql
                 5000_function/5700_system/5708_system_integrity_hardening.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5905_test_collection_lifecycle.sql', ARRAY['5000_function/5700_system/5704_system_collection.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql']::text[]);

\echo '[TEST] 5905_test_collection_lifecycle.sql'

BEGIN;

/*
 * collection.validate_instance_definition/adjustment/acquisition_item/
 * entry_tag/transfer and prevent_transfer_mutation are all created in
 * 5708_system_integrity_hardening.sql rather than in 5704_system_collection.sql
 * or 5701_system_hierarchy.sql; it is added to Depends On above (and to the
 * bt_preflight array) because this file exercises those routines directly.
 *
 * identity.users is itself audited, so disable only its audit trigger for the
 * fixture insert. This entire test runs inside a transaction and rolls back.
 */
ALTER TABLE identity.users DISABLE TRIGGER trg_audit_users;

INSERT INTO identity.users (
    user_id, username, display_name, account_status, activated_at
)
VALUES
    ('00000000-0000-4000-8000-000000005906'::uuid, 'bt_test_collection_5906', 'BrickTrackr Collection Test User 1', 'ACTIVE', clock_timestamp()),
    ('00000000-0000-4000-8000-000000005907'::uuid, 'bt_test_collection_5907', 'BrickTrackr Collection Test User 2', 'ACTIVE', clock_timestamp());

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

SELECT app.set_request_context(
    NULL,
    '00000000-0000-4000-8000-000000005908'::uuid,
    '5905-collection-lifecycle-test',
    'ADMIN'
);

DO $$
DECLARE
    v_user_1 uuid := '00000000-0000-4000-8000-000000005906'::uuid;
    v_user_2 uuid := '00000000-0000-4000-8000-000000005907'::uuid;

    v_owner_1 uuid;
    v_owner_2 uuid;
    v_owner_family uuid;
    v_family_id uuid;

    v_set_item uuid := gen_random_uuid();
    v_other_set_item uuid := gen_random_uuid();
    v_part_design uuid := gen_random_uuid();
    v_variant uuid;

    v_def uuid;
    v_ver1 uuid;
    v_def_other uuid;
    v_ver_other uuid;

    v_group_ok bigint;
    v_group_bad bigint;

    v_entry_1 uuid;
    v_entry_2 uuid;
    v_entry_owner2 uuid;
    v_entry_part_active uuid;
    v_entry_part_archived uuid;

    v_instance_1 uuid;
    v_instance_2 uuid;
    v_instance_ver1 uuid;

    v_loc_1 uuid;
    v_loc_2 uuid;
    v_loc_child uuid;

    v_tag_1 uuid;
    v_tag_2 uuid;

    v_acq_1 uuid;

    v_transfer_id uuid;

    v_failed boolean;
    v_owned numeric;
    v_allocated numeric;
    v_available numeric;
BEGIN
    /* ----------------------------------------------------------------------
     * Fixtures
     * ---------------------------------------------------------------------- */
    INSERT INTO identity.owners (owner_type, user_id) VALUES ('USER', v_user_1) RETURNING owner_id INTO v_owner_1;
    INSERT INTO identity.owners (owner_type, user_id) VALUES ('USER', v_user_2) RETURNING owner_id INTO v_owner_2;

    /*
     * identity.can_transfer_between() requires the actor to be authorized on
     * BOTH the from-owner and to-owner side. v_owner_1/v_owner_2 are
     * deliberately unrelated (used throughout this file for cross-owner
     * negative-path checks), so the transfer happy path below needs its own
     * destination the acting user is actually authorized to receive into: a
     * FAMILY owner they are a PARENT member of.
     */
    INSERT INTO identity.families (family_name, created_by_user_id)
    VALUES ('TEST 5905 family', v_user_1)
    RETURNING family_id INTO v_family_id;

    INSERT INTO identity.owners (owner_type, family_id) VALUES ('FAMILY', v_family_id) RETURNING owner_id INTO v_owner_family;

    INSERT INTO identity.family_memberships (family_id, user_id, member_role, membership_status)
    VALUES (v_family_id, v_user_1, 'PARENT', 'ACTIVE');

    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES
        (v_set_item, 'SET', 'TEST 5905 collection set', 'ACTIVE'),
        (v_other_set_item, 'SET', 'TEST 5905 collection other set', 'ACTIVE'),
        (v_part_design, 'PART', 'TEST 5905 collection part design', 'ACTIVE');

    INSERT INTO catalog.parts (catalog_item_id, design_name) VALUES (v_part_design, 'TEST 5905 part design');

    INSERT INTO catalog.part_variants (part_catalog_item_id) VALUES (v_part_design) RETURNING part_variant_id INTO v_variant;

    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_set_item, 'SET_MANIFEST') RETURNING inventory_definition_id INTO v_def;
    INSERT INTO definition.inventory_versions (inventory_definition_id, semantic_version, status)
    VALUES (v_def, 1, 'DRAFT') RETURNING inventory_version_id INTO v_ver1;

    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_other_set_item, 'SET_MANIFEST') RETURNING inventory_definition_id INTO v_def_other;
    INSERT INTO definition.inventory_versions (inventory_definition_id, semantic_version, status)
    VALUES (v_def_other, 1, 'DRAFT') RETURNING inventory_version_id INTO v_ver_other;

    INSERT INTO definition.requirement_groups (inventory_version_id, required_quantity)
    VALUES (v_ver1, 1) RETURNING requirement_group_id INTO v_group_ok;
    INSERT INTO definition.requirement_groups (inventory_version_id, required_quantity)
    VALUES (v_ver_other, 1) RETURNING requirement_group_id INTO v_group_bad;

    INSERT INTO collection.entries (owner_id, catalog_item_id, quantity, status)
    VALUES (v_owner_1, v_set_item, 5, 'ACTIVE') RETURNING collection_entry_id INTO v_entry_1;
    INSERT INTO collection.entries (owner_id, catalog_item_id, quantity, status)
    VALUES (v_owner_1, v_set_item, 3, 'ACTIVE') RETURNING collection_entry_id INTO v_entry_2;
    INSERT INTO collection.entries (owner_id, catalog_item_id, quantity, status)
    VALUES (v_owner_2, v_set_item, 1, 'ACTIVE') RETURNING collection_entry_id INTO v_entry_owner2;
    INSERT INTO collection.entries (owner_id, part_variant_id, quantity, status)
    VALUES (v_owner_1, v_variant, 7, 'ACTIVE') RETURNING collection_entry_id INTO v_entry_part_active;
    INSERT INTO collection.entries (owner_id, part_variant_id, quantity, status, archived_at)
    VALUES (v_owner_1, v_variant, 100, 'ARCHIVED', clock_timestamp()) RETURNING collection_entry_id INTO v_entry_part_archived;

    INSERT INTO collection.instances (collection_entry_id) VALUES (v_entry_1) RETURNING collection_instance_id INTO v_instance_1;
    INSERT INTO collection.instances (collection_entry_id) VALUES (v_entry_2) RETURNING collection_instance_id INTO v_instance_2;

    INSERT INTO collection.storage_locations (owner_id, location_name) VALUES (v_owner_1, 'TEST 5905 loc 1') RETURNING storage_location_id INTO v_loc_1;
    INSERT INTO collection.storage_locations (owner_id, location_name) VALUES (v_owner_2, 'TEST 5905 loc 2') RETURNING storage_location_id INTO v_loc_2;
    INSERT INTO collection.storage_locations (owner_id, parent_storage_location_id, location_name)
    VALUES (v_owner_1, v_loc_1, 'TEST 5905 loc child') RETURNING storage_location_id INTO v_loc_child;

    INSERT INTO collection.tags (owner_id, tag_name) VALUES (v_owner_1, 'TEST-5905-tag-1') RETURNING tag_id INTO v_tag_1;
    INSERT INTO collection.tags (owner_id, tag_name) VALUES (v_owner_2, 'TEST-5905-tag-2') RETURNING tag_id INTO v_tag_2;

    INSERT INTO collection.acquisitions (owner_id) VALUES (v_owner_1) RETURNING acquisition_id INTO v_acq_1;

    /* ----------------------------------------------------------------------
     * collection.validate_storage_allocation()
     * ---------------------------------------------------------------------- */
    INSERT INTO collection.storage_allocations (collection_entry_id, storage_location_id, quantity)
    VALUES (v_entry_1, v_loc_1, 2);

    v_failed := false;
    BEGIN
        INSERT INTO collection.storage_allocations (collection_entry_id, storage_location_id, quantity)
        VALUES (v_entry_1, v_loc_2, 1);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_storage_allocation() allowed a storage allocation crossing owners');

    v_failed := false;
    BEGIN
        INSERT INTO collection.storage_allocations (collection_entry_id, collection_instance_id, storage_location_id, quantity)
        VALUES (v_entry_1, v_instance_2, v_loc_1, 1);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_storage_allocation() allowed an instance that does not belong to the allocated entry');

    INSERT INTO collection.storage_allocations (collection_entry_id, collection_instance_id, storage_location_id, quantity)
    VALUES (v_entry_1, v_instance_1, v_loc_1, 1);

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM collection.storage_allocations
             WHERE collection_entry_id = v_entry_1 AND collection_instance_id = v_instance_1
        ),
        'validate_storage_allocation() rejected a correctly-scoped instance allocation'
    );

    /* ----------------------------------------------------------------------
     * collection.explicit_part_balance()
     * ---------------------------------------------------------------------- */
    SELECT owned_quantity, allocated_quantity, available_quantity
      INTO v_owned, v_allocated, v_available
      FROM collection.explicit_part_balance(v_owner_1, v_variant);

    PERFORM app.assert_true(v_owned = 7,
        format('explicit_part_balance() owned_quantity was %s, expected 7 (ARCHIVED entry must be excluded)', v_owned));
    PERFORM app.assert_true(v_allocated = 0,
        format('explicit_part_balance() allocated_quantity was %s, expected 0', v_allocated));
    PERFORM app.assert_true(v_available = 7,
        format('explicit_part_balance() available_quantity was %s, expected 7', v_available));

    /* ----------------------------------------------------------------------
     * collection.validate_storage_cycle() -- storage-location portion only.
     * ---------------------------------------------------------------------- */
    v_failed := false;
    BEGIN
        INSERT INTO collection.storage_locations (owner_id, parent_storage_location_id, location_name)
        VALUES (v_owner_2, v_loc_1, 'TEST 5905 cross-owner child');
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_storage_cycle() allowed a storage parent/child pair across owners');

    v_failed := false;
    BEGIN
        UPDATE collection.storage_locations
           SET parent_storage_location_id = v_loc_child
         WHERE storage_location_id = v_loc_1;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_storage_cycle() allowed a storage hierarchy cycle');

    /* ----------------------------------------------------------------------
     * collection.validate_instance_definition()
     * ---------------------------------------------------------------------- */
    INSERT INTO collection.instances (collection_entry_id, inventory_version_id)
    VALUES (v_entry_1, v_ver1)
    RETURNING collection_instance_id INTO v_instance_ver1;

    v_failed := false;
    BEGIN
        INSERT INTO collection.instances (collection_entry_id, inventory_version_id)
        VALUES (v_entry_1, v_ver_other);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_instance_definition() allowed an inventory version that does not describe the entry');

    /* ----------------------------------------------------------------------
     * collection.validate_instance_adjustment()
     * ---------------------------------------------------------------------- */
    INSERT INTO collection.instance_adjustments (
        collection_instance_id, adjustment_type, expected_requirement_group_id,
        catalog_item_id, quantity
    )
    VALUES (v_instance_ver1, 'MISSING', v_group_ok, v_set_item, 1);

    v_failed := false;
    BEGIN
        INSERT INTO collection.instance_adjustments (
            collection_instance_id, adjustment_type, expected_requirement_group_id,
            catalog_item_id, quantity
        )
        VALUES (v_instance_ver1, 'MISSING', v_group_bad, v_set_item, 1);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_instance_adjustment() allowed a requirement group from a different inventory version');

    v_failed := false;
    BEGIN
        INSERT INTO collection.instance_adjustments (
            collection_instance_id, adjustment_type, expected_requirement_group_id,
            catalog_item_id, quantity
        )
        VALUES (v_instance_1, 'MISSING', v_group_ok, v_set_item, 1);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_instance_adjustment() allowed a requirement group reference on an instance with no inventory version');

    /* ----------------------------------------------------------------------
     * collection.validate_acquisition_item()
     * ---------------------------------------------------------------------- */
    INSERT INTO collection.acquisition_items (acquisition_id, collection_entry_id, quantity)
    VALUES (v_acq_1, v_entry_1, 1);

    v_failed := false;
    BEGIN
        INSERT INTO collection.acquisition_items (acquisition_id, collection_entry_id, quantity)
        VALUES (v_acq_1, v_entry_owner2, 1);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_acquisition_item() allowed an acquisition and entry with different owners');

    v_failed := false;
    BEGIN
        INSERT INTO collection.acquisition_items (acquisition_id, collection_entry_id, collection_instance_id, quantity)
        VALUES (v_acq_1, v_entry_1, v_instance_2, 1);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_acquisition_item() allowed an instance that does not belong to the acquisition entry');

    /* ----------------------------------------------------------------------
     * collection.validate_entry_tag()
     * ---------------------------------------------------------------------- */
    INSERT INTO collection.entry_tags (collection_entry_id, tag_id) VALUES (v_entry_1, v_tag_1);

    v_failed := false;
    BEGIN
        INSERT INTO collection.entry_tags (collection_entry_id, tag_id) VALUES (v_entry_1, v_tag_2);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_entry_tag() allowed an entry and tag with different owners');

    /* ----------------------------------------------------------------------
     * collection.validate_transfer() / prevent_transfer_mutation()
     * ---------------------------------------------------------------------- */
    v_failed := false;
    BEGIN
        INSERT INTO collection.transfers (
            collection_entry_id, from_owner_id, to_owner_id, quantity, actor_user_id
        )
        VALUES (v_entry_1, v_owner_2, v_owner_1, 1, v_user_2);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_transfer() allowed a from_owner_id that does not own the collection entry');

    v_failed := false;
    BEGIN
        INSERT INTO collection.transfers (
            collection_entry_id, from_owner_id, to_owner_id, quantity, actor_user_id
        )
        VALUES (v_entry_1, v_owner_1, v_owner_2, 1, v_user_2);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_transfer() allowed an actor unauthorized for the source owner');

    INSERT INTO collection.transfers (
        collection_entry_id, from_owner_id, to_owner_id, quantity, actor_user_id
    )
    VALUES (v_entry_1, v_owner_1, v_owner_family, 1, v_user_1)
    RETURNING transfer_id INTO v_transfer_id;

    PERFORM app.assert_true(v_transfer_id IS NOT NULL,
        'validate_transfer() rejected a transfer the actor is authorized for on both sides');

    v_failed := false;
    BEGIN
        UPDATE collection.transfers SET quantity = 2 WHERE transfer_id = v_transfer_id;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_transfer_mutation() allowed an UPDATE of a collection transfer');

    v_failed := false;
    BEGIN
        DELETE FROM collection.transfers WHERE transfer_id = v_transfer_id;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_transfer_mutation() allowed a DELETE of a collection transfer');
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5905_test_collection_lifecycle.sql');
