/*
===============================================================================
 File:           5000_function/5900_tests/5904_test_definition_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for semantic inventory-version immutability,
                 definition authority integrity, and the manifest-subassembly
                 graph engine (acyclic validation, requirement placement
                 scoping and admin graph cloning).
 Depends On:     5000_function/5700_system/5703_system_definition.sql
                 5000_function/5100_admin/5120_admin_definition_graph.sql
                 0400_definitions/0405_manifest_graph.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5904_test_definition_lifecycle.sql', ARRAY['5000_function/5700_system/5703_system_definition.sql', '5000_function/5100_admin/5120_admin_definition_graph.sql', '0400_definitions/0405_manifest_graph.sql']::text[]);

\echo '[TEST] 5904_test_definition_lifecycle.sql'

BEGIN;

/*
 * A real identity.users row is required as created_by_user_id for the
 * admin-correction inventory versions exercised below.
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
    '00000000-0000-4000-8000-000000005904'::uuid,
    'bt_test_definition_5904',
    'BrickTrackr Definition Lifecycle Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

SELECT app.set_request_context(
    NULL,
    '00000000-0000-4000-8000-000000005905'::uuid,
    '5904-definition-lifecycle-test',
    'ADMIN'
);

DO $$
DECLARE
    v_user_id uuid := '00000000-0000-4000-8000-000000005904'::uuid;

    v_item_a uuid := gen_random_uuid();
    v_item_b uuid := gen_random_uuid();

    v_def_a uuid;
    v_def_b uuid;

    v_version_a1 uuid;        -- def_a, DRAFT, source of truth for effective_inventory_version
    v_version_a2_admin uuid;  -- def_a, DRAFT, is_admin_correction
    v_version_a3 uuid;        -- def_a, DRAFT, empty clone destination
    v_version_finalized uuid; -- def_a, FINALIZED at creation
    v_version_grp_test uuid;  -- def_a, DRAFT -> FINALIZED in-test
    v_version_b1 uuid;        -- def_b, DRAFT
    v_version_b_admin uuid;   -- def_b, DRAFT, is_admin_correction

    v_group_id bigint;        -- requirement_key = 'root_group', scoped to v_version_a1
    v_group_b bigint;         -- scoped to v_version_b1 (mismatched-scope fixture)
    v_group_dst bigint;       -- requirement_key = 'root_group', scoped to v_version_a3
    v_group_grp_test bigint;

    v_sub_root uuid := gen_random_uuid();
    v_sub_child uuid := gen_random_uuid();
    v_sub_self uuid := gen_random_uuid();

    v_effective uuid;
    v_failed boolean;
    v_count integer;
BEGIN
    /* ----------------------------------------------------------------------
     * Fixtures: two independent SET manifests.
     * ---------------------------------------------------------------------- */
    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES
        (v_item_a, 'SET', 'TEST 5904 definition set A', 'ACTIVE'),
        (v_item_b, 'SET', 'TEST 5904 definition set B', 'ACTIVE');

    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_item_a, 'SET_MANIFEST')
    RETURNING inventory_definition_id INTO v_def_a;

    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_item_b, 'SET_MANIFEST')
    RETURNING inventory_definition_id INTO v_def_b;

    INSERT INTO definition.inventory_versions (inventory_definition_id, semantic_version, status)
    VALUES (v_def_a, 1, 'DRAFT')
    RETURNING inventory_version_id INTO v_version_a1;

    INSERT INTO definition.inventory_versions (
        inventory_definition_id, semantic_version, status,
        is_admin_correction, created_by_user_id
    )
    VALUES (v_def_a, 2, 'DRAFT', true, v_user_id)
    RETURNING inventory_version_id INTO v_version_a2_admin;

    INSERT INTO definition.inventory_versions (inventory_definition_id, semantic_version, status)
    VALUES (v_def_a, 4, 'DRAFT')
    RETURNING inventory_version_id INTO v_version_a3;

    /* Created FINALIZED directly: INSERT is not covered by the immutability trigger. */
    INSERT INTO definition.inventory_versions (
        inventory_definition_id, semantic_version, status,
        semantic_hash, finalized_at
    )
    VALUES (
        v_def_a, 3, 'FINALIZED',
        decode(md5('5904-finalized-a')||md5('5904-finalized-a-2'), 'hex'),
        clock_timestamp()
    )
    RETURNING inventory_version_id INTO v_version_finalized;

    INSERT INTO definition.inventory_versions (inventory_definition_id, semantic_version, status)
    VALUES (v_def_a, 5, 'DRAFT')
    RETURNING inventory_version_id INTO v_version_grp_test;

    INSERT INTO definition.inventory_versions (inventory_definition_id, semantic_version, status)
    VALUES (v_def_b, 1, 'DRAFT')
    RETURNING inventory_version_id INTO v_version_b1;

    INSERT INTO definition.inventory_versions (
        inventory_definition_id, semantic_version, status,
        is_admin_correction, created_by_user_id
    )
    VALUES (v_def_b, 2, 'DRAFT', true, v_user_id)
    RETURNING inventory_version_id INTO v_version_b_admin;

    /* ------------------------------------------------------------------
     * definition.effective_inventory_version(): coalesce(admin, source)
     * ------------------------------------------------------------------ */
    INSERT INTO definition.definition_authority (inventory_definition_id, latest_source_version_id)
    VALUES (v_def_a, v_version_a1);

    v_effective := definition.effective_inventory_version(v_def_a);
    PERFORM app.assert_true(v_effective = v_version_a1,
        'effective_inventory_version() did not fall back to latest_source_version_id');

    UPDATE definition.definition_authority
       SET active_admin_version_id = v_version_a2_admin
     WHERE inventory_definition_id = v_def_a;

    v_effective := definition.effective_inventory_version(v_def_a);
    PERFORM app.assert_true(v_effective = v_version_a2_admin,
        'effective_inventory_version() did not prefer active_admin_version_id');

    /* ------------------------------------------------------------------
     * definition.validate_authority(): cross-definition rejection.
     * ------------------------------------------------------------------ */
    v_failed := false;
    BEGIN
        UPDATE definition.definition_authority
           SET latest_source_version_id = v_version_b1
         WHERE inventory_definition_id = v_def_a;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_authority() accepted a latest_source_version_id from another definition');

    v_failed := false;
    BEGIN
        UPDATE definition.definition_authority
           SET active_admin_version_id = v_version_b_admin
         WHERE inventory_definition_id = v_def_a;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_authority() accepted an active_admin_version_id from another definition');

    /* validate_authority(): admin pointer must reference an admin-correction version. */
    v_failed := false;
    BEGIN
        UPDATE definition.definition_authority
           SET active_admin_version_id = v_version_a1
         WHERE inventory_definition_id = v_def_a;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_authority() accepted a non-admin-correction version as active_admin_version_id');

    /* ------------------------------------------------------------------
     * definition.prevent_finalized_version_mutation()
     * ------------------------------------------------------------------ */
    v_failed := false;
    BEGIN
        UPDATE definition.inventory_versions
           SET semantic_version = 30
         WHERE inventory_version_id = v_version_finalized;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_finalized_version_mutation() allowed UPDATE of a FINALIZED version');

    v_failed := false;
    BEGIN
        DELETE FROM definition.inventory_versions
         WHERE inventory_version_id = v_version_finalized;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_finalized_version_mutation() allowed DELETE of a FINALIZED version');

    /* A DRAFT version remains freely mutable. */
    UPDATE definition.inventory_versions
       SET last_seen_at = clock_timestamp()
     WHERE inventory_version_id = v_version_a1;

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM definition.inventory_versions
             WHERE inventory_version_id = v_version_a1
        ),
        'DRAFT inventory version mutation unexpectedly failed'
    );

    /* ------------------------------------------------------------------
     * definition.prevent_finalized_graph_mutation(): requirement_groups.
     * ------------------------------------------------------------------ */
    v_failed := false;
    BEGIN
        INSERT INTO definition.requirement_groups (inventory_version_id, required_quantity)
        VALUES (v_version_finalized, 1);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_finalized_graph_mutation() allowed a new requirement group on a FINALIZED version');

    INSERT INTO definition.requirement_groups (
        inventory_version_id, required_quantity, requirement_key
    )
    VALUES (v_version_a1, 1, 'root_group')
    RETURNING requirement_group_id INTO v_group_id;

    /* prevent_finalized_graph_mutation(): requirement_options join branch. */
    INSERT INTO definition.requirement_groups (inventory_version_id, required_quantity)
    VALUES (v_version_grp_test, 1)
    RETURNING requirement_group_id INTO v_group_grp_test;

    INSERT INTO definition.requirement_options (
        requirement_group_id, catalog_item_id, is_primary
    )
    VALUES (v_group_grp_test, v_item_a, true);

    /* Finalizing is allowed: OLD.status was DRAFT, not FINALIZED. */
    UPDATE definition.inventory_versions
       SET status = 'FINALIZED',
           semantic_hash = decode(md5('5904-grp-test')||md5('5904-grp-test-2'), 'hex'),
           finalized_at = clock_timestamp()
     WHERE inventory_version_id = v_version_grp_test;

    v_failed := false;
    BEGIN
        INSERT INTO definition.requirement_options (
            requirement_group_id, catalog_item_id, is_primary
        )
        VALUES (v_group_grp_test, v_item_a, false);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_finalized_graph_mutation() allowed a new requirement option under a FINALIZED version');

    v_failed := false;
    BEGIN
        UPDATE definition.requirement_groups
           SET sort_order = 5
         WHERE requirement_group_id = v_group_grp_test;
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_finalized_graph_mutation() allowed mutating a requirement group under a FINALIZED version');

    /* ------------------------------------------------------------------
     * definition.validate_manifest_subassembly_acyclic() / trigger.
     * ------------------------------------------------------------------ */
    INSERT INTO definition.manifest_subassemblies (
        manifest_subassembly_id, inventory_version_id, parent_subassembly_id,
        subassembly_key, display_name
    )
    VALUES (v_sub_root, v_version_a1, NULL, 'root', 'Root subassembly');

    INSERT INTO definition.manifest_subassemblies (
        manifest_subassembly_id, inventory_version_id, parent_subassembly_id,
        subassembly_key, display_name
    )
    VALUES (v_sub_child, v_version_a1, v_sub_root, 'child', 'Child subassembly');

    /* Direct function call: a node cannot parent itself. */
    v_failed := false;
    BEGIN
        PERFORM definition.validate_manifest_subassembly_acyclic(v_sub_self, v_sub_self);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23514' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_manifest_subassembly_acyclic() allowed a node to parent itself');

    /* Trigger: re-parenting the root under its own descendant is a cycle. */
    v_failed := false;
    BEGIN
        UPDATE definition.manifest_subassemblies
           SET parent_subassembly_id = v_sub_child
         WHERE manifest_subassembly_id = v_sub_root;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23514' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'trg_validate_manifest_subassembly_acyclic allowed a cycle');

    /* ------------------------------------------------------------------
     * definition.trg_validate_manifest_requirement_scope()
     *
     * New coverage: manifest_requirement_placements.inventory_version_id
     * must agree with the referenced requirement group's own
     * inventory_version_id.
     * ------------------------------------------------------------------ */
    INSERT INTO definition.requirement_groups (inventory_version_id, required_quantity)
    VALUES (v_version_b1, 1)
    RETURNING requirement_group_id INTO v_group_b;

    /* Mismatched scope: v_group_b belongs to v_version_b1, not v_version_a1. */
    v_failed := false;
    BEGIN
        INSERT INTO definition.manifest_requirement_placements (
            requirement_group_id, manifest_subassembly_id, inventory_version_id, position_index
        )
        VALUES (v_group_b, v_sub_root, v_version_a1, 0);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23514' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'trg_validate_manifest_requirement_scope accepted a mismatched-scope placement');

    /* Correctly scoped placement succeeds. */
    INSERT INTO definition.manifest_requirement_placements (
        requirement_group_id, manifest_subassembly_id, inventory_version_id, position_index
    )
    VALUES (v_group_id, v_sub_root, v_version_a1, 0);

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM definition.manifest_requirement_placements
             WHERE requirement_group_id = v_group_id
        ),
        'trg_validate_manifest_requirement_scope rejected a correctly-scoped placement'
    );

    /* ------------------------------------------------------------------
     * admin.clone_manifest_graph()
     *
     * Documented cross-schema note: the graph-cloning behavior below is
     * fundamentally about definition-schema objects (manifest_subassemblies,
     * manifest_requirement_placements, requirement_groups) even though its
     * callable wrapper lives in the admin schema
     * (5000_function/5100_admin/5120_admin_definition_graph.sql). Its
     * CALL/assertions are kept here rather than in an admin-schema test file.
     * ------------------------------------------------------------------ */
    INSERT INTO definition.requirement_groups (
        inventory_version_id, required_quantity, requirement_key
    )
    VALUES (v_version_a3, 1, 'root_group')
    RETURNING requirement_group_id INTO v_group_dst;

    /* Source and destination must differ. */
    v_failed := false;
    BEGIN
        PERFORM admin.clone_manifest_graph(v_version_a1, v_version_a1);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'clone_manifest_graph() accepted identical source/destination versions');

    PERFORM admin.clone_manifest_graph(v_version_a1, v_version_a3);

    SELECT count(*) INTO v_count
      FROM definition.manifest_subassemblies
     WHERE inventory_version_id = v_version_a3;

    PERFORM app.assert_true(v_count = 2,
        'clone_manifest_graph() did not clone all source subassemblies');

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1
              FROM definition.manifest_subassemblies parent
              JOIN definition.manifest_subassemblies child
                ON child.parent_subassembly_id = parent.manifest_subassembly_id
             WHERE parent.inventory_version_id = v_version_a3
               AND parent.subassembly_key = 'root'
               AND child.subassembly_key = 'child'
        ),
        'clone_manifest_graph() did not preserve parent/child structure'
    );

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1
              FROM definition.manifest_requirement_placements p
              JOIN definition.manifest_subassemblies s
                ON s.manifest_subassembly_id = p.manifest_subassembly_id
             WHERE p.requirement_group_id = v_group_dst
               AND s.inventory_version_id = v_version_a3
               AND s.subassembly_key = 'root'
        ),
        'clone_manifest_graph() did not clone requirement placements by requirement_key'
    );

    /* A destination that already has a graph is rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.clone_manifest_graph(v_version_a1, v_version_a3);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23505' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'clone_manifest_graph() allowed cloning onto a destination that already has a graph');
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5904_test_definition_lifecycle.sql');
