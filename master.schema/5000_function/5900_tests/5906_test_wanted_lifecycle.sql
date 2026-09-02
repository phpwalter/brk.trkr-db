/*
===============================================================================
 File:           5000_function/5900_tests/5906_test_wanted_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for the wanted schema: build-goal progress
                 calculation and wanted-schema cross-row integrity triggers.
 Depends On:     5000_function/5700_system/5705_system_wanted.sql
                 5000_function/5700_system/5708_system_integrity_hardening.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5906_test_wanted_lifecycle.sql', ARRAY['5000_function/5700_system/5705_system_wanted.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql']::text[]);

\echo '[TEST] 5906_test_wanted_lifecycle.sql'

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
    '00000000-0000-4000-8000-000000005906'::uuid,
    'bt_test_wanted_5906',
    'BrickTrackr Wanted Lifecycle Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

SELECT app.set_request_context(
    '00000000-0000-4000-8000-000000005906'::uuid,
    '00000000-0000-4000-8000-000000005907'::uuid,
    '5906-wanted-lifecycle-test',
    'USER'
);

DO $$
DECLARE
    v_owner_id uuid;
    v_set_item_id uuid := gen_random_uuid();
    v_other_set_item_id uuid := gen_random_uuid();
    v_part_item_id uuid := gen_random_uuid();
    v_part_variant_id uuid;
    v_definition_id uuid;
    v_version_id uuid;
    v_other_version_id uuid;
    v_group_id bigint;
    v_foreign_group_id bigint;
    v_entry_id uuid;
    v_build_goal_id uuid;
    v_wishlist_id uuid;
    v_wishlist_entry_id uuid;
    v_reservation_id uuid;
    v_failed boolean;
    v_req record;
    v_summary record;
BEGIN
    /* ----------------------------------------------------------------------
     * Fixtures: owner, catalog items, one inventory definition/version with
     * a single ANY requirement group satisfied by an owned part variant.
     * -------------------------------------------------------------------- */
    INSERT INTO identity.owners (owner_type, user_id)
    VALUES ('USER', '00000000-0000-4000-8000-000000005906'::uuid)
    RETURNING owner_id INTO v_owner_id;

    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES
        (v_set_item_id, 'SET', 'TEST 5906 set', 'ACTIVE'),
        (v_other_set_item_id, 'SET', 'TEST 5906 other set', 'ACTIVE'),
        (v_part_item_id, 'PART', 'TEST 5906 part', 'ACTIVE');

    INSERT INTO catalog.parts (catalog_item_id, design_name)
    VALUES (v_part_item_id, 'TEST 5906 part design');

    INSERT INTO catalog.part_variants (part_catalog_item_id)
    VALUES (v_part_item_id)
    RETURNING part_variant_id INTO v_part_variant_id;

    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_set_item_id, 'SET_MANIFEST')
    RETURNING inventory_definition_id INTO v_definition_id;

    INSERT INTO definition.inventory_versions (
        inventory_definition_id, semantic_version, status
    )
    VALUES (v_definition_id, 1, 'DRAFT')
    RETURNING inventory_version_id INTO v_version_id;

    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_other_set_item_id, 'SET_MANIFEST')
    RETURNING inventory_definition_id INTO v_definition_id;

    INSERT INTO definition.inventory_versions (
        inventory_definition_id, semantic_version, status
    )
    VALUES (v_definition_id, 1, 'DRAFT')
    RETURNING inventory_version_id INTO v_other_version_id;

    /* The requirement graph must be built while the version is still DRAFT;
     * prevent_finalized_graph_mutation() blocks graph writes once FINALIZED. */
    INSERT INTO definition.requirement_groups (
        inventory_version_id, required_quantity, fulfillment_rule,
        is_required, is_spare
    )
    VALUES (v_version_id, 2, 'ANY', true, false)
    RETURNING requirement_group_id INTO v_group_id;

    INSERT INTO definition.requirement_options (
        requirement_group_id, part_variant_id, option_quantity
    )
    VALUES (v_group_id, v_part_variant_id, 1);

    /* A second requirement group on the OTHER version, created before it is
     * finalized, so a later test can prove build_allocations rejects a
     * requirement group foreign to the build goal's own inventory version. */
    INSERT INTO definition.requirement_groups (
        inventory_version_id, required_quantity, fulfillment_rule,
        is_required, is_spare
    )
    VALUES (v_other_version_id, 1, 'ANY', true, false)
    RETURNING requirement_group_id INTO v_foreign_group_id;

    INSERT INTO definition.requirement_options (
        requirement_group_id, part_variant_id, option_quantity
    )
    VALUES (v_foreign_group_id, v_part_variant_id, 1);

    UPDATE definition.inventory_versions
       SET status = 'FINALIZED',
           semantic_hash = decode(md5('5906-finalized-a')||md5('5906-finalized-a-2'), 'hex'),
           finalized_at = clock_timestamp()
     WHERE inventory_version_id = v_version_id;

    UPDATE definition.inventory_versions
       SET status = 'FINALIZED',
           semantic_hash = decode(md5('5906-finalized-b')||md5('5906-finalized-b-2'), 'hex'),
           finalized_at = clock_timestamp()
     WHERE inventory_version_id = v_other_version_id;

    INSERT INTO collection.entries (
        collection_entry_id, owner_id, part_variant_id, quantity, status
    )
    VALUES (gen_random_uuid(), v_owner_id, v_part_variant_id, 5, 'ACTIVE')
    RETURNING collection_entry_id INTO v_entry_id;

    /* ----------------------------------------------------------------------
     * wanted.build_goal_requirements() / wanted.build_goal_summary()
     * -------------------------------------------------------------------- */
    INSERT INTO wanted.build_goals (
        owner_id, build_goal_type, target_catalog_item_id,
        inventory_version_id, target_quantity, include_allocated_parts
    )
    VALUES (
        v_owner_id, 'BUILD_FROM_INVENTORY', v_set_item_id,
        v_version_id, 1, false
    )
    RETURNING build_goal_id INTO v_build_goal_id;

    SELECT * INTO v_req
      FROM wanted.build_goal_requirements(v_build_goal_id);

    PERFORM app.assert_true(
        v_req.requirement_group_id = v_group_id,
        'build_goal_requirements() returned an unexpected requirement group'
    );
    PERFORM app.assert_true(
        v_req.required_units = 2,
        'build_goal_requirements() required_units incorrect'
    );
    PERFORM app.assert_true(
        v_req.satisfied_units = 2,
        'build_goal_requirements() satisfied_units did not cap at required_units'
    );
    PERFORM app.assert_true(
        v_req.missing_units = 0,
        'build_goal_requirements() missing_units should be zero when fully owned'
    );
    PERFORM app.assert_true(
        v_req.completion_percent = 100,
        'build_goal_requirements() completion_percent should be 100 when fully satisfied'
    );

    SELECT * INTO v_summary
      FROM wanted.build_goal_summary(v_build_goal_id);

    PERFORM app.assert_true(
        v_summary.requirement_count = 1
        AND v_summary.complete_requirement_count = 1,
        'build_goal_summary() requirement counts incorrect'
    );
    PERFORM app.assert_true(
        v_summary.completion_percent = 100,
        'build_goal_summary() completion_percent incorrect'
    );

    /* ----------------------------------------------------------------------
     * wanted.validate_build_goal()
     * -------------------------------------------------------------------- */

    /* Inventory version must describe target_catalog_item_id. */
    v_failed := false;
    BEGIN
        INSERT INTO wanted.build_goals (
            owner_id, build_goal_type, target_catalog_item_id,
            inventory_version_id, target_quantity
        )
        VALUES (
            v_owner_id, 'BUILD_FROM_INVENTORY', v_other_set_item_id,
            v_version_id, 1
        );
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_build_goal() accepted a mismatched inventory version/target item');

    /* COMPLETE_OWNED_INSTANCE requires collection_instance_id. */
    v_failed := false;
    BEGIN
        INSERT INTO wanted.build_goals (
            owner_id, build_goal_type, target_catalog_item_id,
            inventory_version_id, target_quantity
        )
        VALUES (
            v_owner_id, 'COMPLETE_OWNED_INSTANCE', v_set_item_id,
            v_version_id, 1
        );
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_build_goal() accepted COMPLETE_OWNED_INSTANCE without collection_instance_id');

    /* ----------------------------------------------------------------------
     * wanted.validate_wishlist_entry_version()
     * -------------------------------------------------------------------- */
    INSERT INTO wanted.wishlists (owner_id, wishlist_name)
    VALUES (v_owner_id, 'TEST 5906 wishlist')
    RETURNING wishlist_id INTO v_wishlist_id;

    /* A part-variant entry cannot select an inventory version. */
    v_failed := false;
    BEGIN
        INSERT INTO wanted.wishlist_entries (
            wishlist_id, part_variant_id, preferred_inventory_version_id,
            desired_quantity
        )
        VALUES (v_wishlist_id, v_part_variant_id, v_version_id, 1);
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_wishlist_entry_version() accepted a version on a part-variant entry');

    /* Preferred version must describe the wishlist catalog item. */
    v_failed := false;
    BEGIN
        INSERT INTO wanted.wishlist_entries (
            wishlist_id, catalog_item_id, preferred_inventory_version_id,
            desired_quantity
        )
        VALUES (v_wishlist_id, v_other_set_item_id, v_version_id, 1);
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_wishlist_entry_version() accepted a version describing a different catalog item');

    /* Matching catalog item and version succeeds. */
    INSERT INTO wanted.wishlist_entries (
        wishlist_id, catalog_item_id, preferred_inventory_version_id,
        desired_quantity
    )
    VALUES (v_wishlist_id, v_set_item_id, v_version_id, 3)
    RETURNING wishlist_entry_id INTO v_wishlist_entry_id;

    /* ----------------------------------------------------------------------
     * wanted.validate_reservation_capacity()
     * -------------------------------------------------------------------- */
    INSERT INTO wanted.wishlist_reservations (
        wishlist_entry_id, reserved_by_user_id, quantity
    )
    VALUES (
        v_wishlist_entry_id,
        '00000000-0000-4000-8000-000000005906'::uuid,
        2
    )
    RETURNING wishlist_reservation_id INTO v_reservation_id;

    /* Second active reservation would push total above desired_quantity (3). */
    v_failed := false;
    BEGIN
        INSERT INTO wanted.wishlist_reservations (
            wishlist_entry_id, reserved_by_user_id, quantity
        )
        VALUES (
            v_wishlist_entry_id,
            '00000000-0000-4000-8000-000000005906'::uuid,
            2
        );
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_reservation_capacity() allowed active reservations to exceed desired_quantity');

    /* Releasing the first reservation frees capacity for a new one. */
    UPDATE wanted.wishlist_reservations
       SET released_at = clock_timestamp()
     WHERE wishlist_reservation_id = v_reservation_id;

    INSERT INTO wanted.wishlist_reservations (
        wishlist_entry_id, reserved_by_user_id, quantity
    )
    VALUES (
        v_wishlist_entry_id,
        '00000000-0000-4000-8000-000000005906'::uuid,
        3
    );

    /* ----------------------------------------------------------------------
     * wanted.validate_build_allocation()
     * -------------------------------------------------------------------- */

    /* Allocation of owned, ACTIVE quantity within bounds succeeds. */
    INSERT INTO wanted.build_allocations (
        build_goal_id, collection_entry_id, requirement_group_id, quantity
    )
    VALUES (v_build_goal_id, v_entry_id, v_group_id, 2);

    /* Allocation exceeding the owned collection quantity is rejected. */
    v_failed := false;
    BEGIN
        INSERT INTO wanted.build_allocations (
            build_goal_id, collection_entry_id, requirement_group_id, quantity
        )
        VALUES (v_build_goal_id, v_entry_id, v_group_id, 10);
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_build_allocation() allowed active allocations to exceed owned quantity');

    /* Allocation against a non-ACTIVE collection entry is rejected. */
    UPDATE collection.entries
       SET status = 'ARCHIVED', archived_at = clock_timestamp()
     WHERE collection_entry_id = v_entry_id;

    v_failed := false;
    BEGIN
        INSERT INTO wanted.build_allocations (
            build_goal_id, collection_entry_id, quantity
        )
        VALUES (v_build_goal_id, v_entry_id, 1);
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_build_allocation() allowed an allocation against a non-ACTIVE collection entry');

    UPDATE collection.entries
       SET status = 'ACTIVE', archived_at = NULL
     WHERE collection_entry_id = v_entry_id;

    /* Requirement group must belong to the build-goal inventory version.
     * v_foreign_group_id was created on v_other_version_id back in the
     * fixture section, before that version was finalized. */
    v_failed := false;
    BEGIN
        INSERT INTO wanted.build_allocations (
            build_goal_id, collection_entry_id, requirement_group_id, quantity
        )
        VALUES (v_build_goal_id, v_entry_id, v_foreign_group_id, 1);
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_build_allocation() allowed a requirement group from a foreign inventory version');
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5906_test_wanted_lifecycle.sql');
