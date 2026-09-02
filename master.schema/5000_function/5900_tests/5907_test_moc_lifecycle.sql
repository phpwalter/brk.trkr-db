/*
===============================================================================
 File:           5000_function/5900_tests/5907_test_moc_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for the moc schema: publication immutability,
                 fork eligibility, subassembly cycle prevention, and revision
                 cross-row integrity.
 Depends On:     5000_function/5700_system/5706_system_moc.sql
                 5000_function/5700_system/5701_system_hierarchy.sql
                 5000_function/5700_system/5708_system_integrity_hardening.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5907_test_moc_lifecycle.sql', ARRAY['5000_function/5700_system/5706_system_moc.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql']::text[]);

\echo '[TEST] 5907_test_moc_lifecycle.sql'

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
    '00000000-0000-4000-8000-000000005907'::uuid,
    'bt_test_moc_5907',
    'BrickTrackr MOC Lifecycle Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

SELECT app.set_request_context(
    '00000000-0000-4000-8000-000000005907'::uuid,
    '00000000-0000-4000-8000-000000005908'::uuid,
    '5907-moc-lifecycle-test',
    'USER'
);

DO $$
DECLARE
    v_user_id uuid := '00000000-0000-4000-8000-000000005907'::uuid;
    v_owner_id uuid;
    v_moc_item_id uuid := gen_random_uuid();
    v_other_moc_item_id uuid := gen_random_uuid();
    v_moc_id uuid;
    v_no_fork_moc_id uuid;
    v_no_fork_item_id uuid := gen_random_uuid();
    v_definition_id uuid;
    v_version_id uuid;
    v_other_version_id uuid;
    v_no_fork_version_id uuid;
    v_draft_revision_id uuid;
    v_published_revision_id uuid;
    v_no_fork_revision_id uuid;
    v_fork_id uuid;
    v_forked_moc_id uuid;
    v_forked_item_id uuid := gen_random_uuid();
    v_sub_a uuid;
    v_sub_b uuid;
    v_failed boolean;
BEGIN
    /* ----------------------------------------------------------------------
     * Fixtures
     * -------------------------------------------------------------------- */
    INSERT INTO identity.owners (owner_type, user_id)
    VALUES ('USER', v_user_id)
    RETURNING owner_id INTO v_owner_id;

    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES
        (v_moc_item_id, 'MOC', 'TEST 5907 moc item', 'ACTIVE'),
        (v_other_moc_item_id, 'MOC', 'TEST 5907 other moc item', 'ACTIVE'),
        (v_no_fork_item_id, 'MOC', 'TEST 5907 no-fork moc item', 'ACTIVE'),
        (v_forked_item_id, 'MOC', 'TEST 5907 forked moc item', 'ACTIVE');

    INSERT INTO catalog.mocs (catalog_item_id)
    VALUES
        (v_moc_item_id),
        (v_other_moc_item_id),
        (v_no_fork_item_id),
        (v_forked_item_id);

    INSERT INTO moc.mocs (
        moc_id, catalog_item_id, owner_id, title, forks_allowed, created_by_user_id
    )
    VALUES (
        gen_random_uuid(), v_moc_item_id, v_owner_id,
        'TEST 5907 forkable MOC', true, v_user_id
    )
    RETURNING moc_id INTO v_moc_id;

    INSERT INTO moc.mocs (
        moc_id, catalog_item_id, owner_id, title, forks_allowed, created_by_user_id
    )
    VALUES (
        gen_random_uuid(), v_no_fork_item_id, v_owner_id,
        'TEST 5907 non-forkable MOC', false, v_user_id
    )
    RETURNING moc_id INTO v_no_fork_moc_id;

    INSERT INTO moc.mocs (
        moc_id, catalog_item_id, owner_id, title, forks_allowed, created_by_user_id
    )
    VALUES (
        gen_random_uuid(), v_forked_item_id, v_owner_id,
        'TEST 5907 forked MOC', true, v_user_id
    )
    RETURNING moc_id INTO v_forked_moc_id;

    /* An inventory version describing v_moc_item_id, for revision-integrity checks. */
    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_moc_item_id, 'MOC_MANIFEST')
    RETURNING inventory_definition_id INTO v_definition_id;

    INSERT INTO definition.inventory_versions (
        inventory_definition_id, semantic_version, status
    )
    VALUES (v_definition_id, 1, 'DRAFT')
    RETURNING inventory_version_id INTO v_version_id;

    /* An inventory version describing a *different* catalog item. */
    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_other_moc_item_id, 'MOC_MANIFEST')
    RETURNING inventory_definition_id INTO v_definition_id;

    INSERT INTO definition.inventory_versions (
        inventory_definition_id, semantic_version, status
    )
    VALUES (v_definition_id, 1, 'DRAFT')
    RETURNING inventory_version_id INTO v_other_version_id;

    /* An inventory version describing the non-forkable MOC's catalog item. */
    INSERT INTO definition.inventory_definitions (catalog_item_id, definition_kind)
    VALUES (v_no_fork_item_id, 'MOC_MANIFEST')
    RETURNING inventory_definition_id INTO v_definition_id;

    INSERT INTO definition.inventory_versions (
        inventory_definition_id, semantic_version, status
    )
    VALUES (v_definition_id, 1, 'DRAFT')
    RETURNING inventory_version_id INTO v_no_fork_version_id;

    /* ----------------------------------------------------------------------
     * moc.validate_revision_integrity()
     * -------------------------------------------------------------------- */

    /* Revision inventory version must describe the MOC's catalog item. */
    v_failed := false;
    BEGIN
        INSERT INTO moc.revisions (
            moc_id, revision_number, inventory_version_id, created_by_user_id
        )
        VALUES (v_moc_id, 1, v_other_version_id, v_user_id);
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_revision_integrity() accepted an inventory version for the wrong catalog item');

    /* DRAFT revision may not have published_at. */
    v_failed := false;
    BEGIN
        INSERT INTO moc.revisions (
            moc_id, revision_number, status, published_at, created_by_user_id
        )
        VALUES (v_moc_id, 1, 'DRAFT', clock_timestamp(), v_user_id);
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_revision_integrity() accepted a DRAFT revision with published_at set');

    /* Valid first (root) revision. */
    INSERT INTO moc.revisions (
        moc_id, revision_number, inventory_version_id, status, created_by_user_id
    )
    VALUES (v_moc_id, 1, v_version_id, 'DRAFT', v_user_id)
    RETURNING moc_revision_id INTO v_draft_revision_id;

    /* Parent revision must belong to the same MOC. */
    v_failed := false;
    DECLARE
        v_foreign_revision_id uuid;
    BEGIN
        INSERT INTO moc.revisions (
            moc_id, revision_number, status, created_by_user_id
        )
        VALUES (v_no_fork_moc_id, 5, 'DRAFT', v_user_id)
        RETURNING moc_revision_id INTO v_foreign_revision_id;

        BEGIN
            INSERT INTO moc.revisions (
                moc_id, revision_number, parent_revision_id, status, created_by_user_id
            )
            VALUES (v_moc_id, 2, v_foreign_revision_id, 'DRAFT', v_user_id);
        EXCEPTION
            WHEN OTHERS THEN v_failed := true;
        END;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_revision_integrity() accepted a parent revision from a different MOC');

    /* Parent revision number must be lower than the child. */
    v_failed := false;
    BEGIN
        INSERT INTO moc.revisions (
            moc_id, revision_number, parent_revision_id, status, created_by_user_id
        )
        VALUES (v_moc_id, 1, v_draft_revision_id, 'DRAFT', v_user_id);
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_revision_integrity() accepted a child revision_number <= parent revision_number');

    /* Valid second, published revision descending from the first. */
    INSERT INTO moc.revisions (
        moc_id, revision_number, parent_revision_id, inventory_version_id,
        status, published_at, semantic_hash, created_by_user_id
    )
    VALUES (
        v_moc_id, 2, v_draft_revision_id, v_version_id, 'PUBLISHED',
        clock_timestamp(), pg_catalog.sha256('5907-published-2'::bytea), v_user_id
    )
    RETURNING moc_revision_id INTO v_published_revision_id;

    /* A published root revision on the non-forkable MOC, for fork tests. */
    INSERT INTO moc.revisions (
        moc_id, revision_number, inventory_version_id, status,
        published_at, semantic_hash, created_by_user_id
    )
    VALUES (
        v_no_fork_moc_id, 1, v_no_fork_version_id, 'PUBLISHED', clock_timestamp(),
        pg_catalog.sha256('5907-no-fork-1'::bytea), v_user_id
    )
    RETURNING moc_revision_id INTO v_no_fork_revision_id;

    /* ----------------------------------------------------------------------
     * moc.prevent_published_revision_mutation()
     * -------------------------------------------------------------------- */
    v_failed := false;
    BEGIN
        UPDATE moc.revisions
           SET status = 'DRAFT'
         WHERE moc_revision_id = v_published_revision_id;
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_published_revision_mutation() allowed UPDATE of a published revision');

    v_failed := false;
    BEGIN
        DELETE FROM moc.revisions
         WHERE moc_revision_id = v_published_revision_id;
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_published_revision_mutation() allowed DELETE of a published revision');

    /* An unpublished (DRAFT) revision remains mutable. */
    UPDATE moc.revisions
       SET published_at = NULL
     WHERE moc_revision_id = v_draft_revision_id;

    PERFORM app.assert_true(
        (SELECT status FROM moc.revisions WHERE moc_revision_id = v_draft_revision_id) = 'DRAFT',
        'A DRAFT revision should remain freely mutable'
    );

    /* ----------------------------------------------------------------------
     * moc.validate_fork()
     * -------------------------------------------------------------------- */

    /* Source MOC must allow forks. */
    v_failed := false;
    BEGIN
        INSERT INTO moc.forks (
            source_moc_id, source_revision_id, forked_moc_id, forked_by_user_id
        )
        VALUES (
            v_no_fork_moc_id, v_no_fork_revision_id, v_forked_moc_id, v_user_id
        );
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_fork() allowed a fork from a MOC with forks_allowed = false');

    /* Only published revisions may be forked. */
    v_failed := false;
    BEGIN
        INSERT INTO moc.forks (
            source_moc_id, source_revision_id, forked_moc_id, forked_by_user_id
        )
        VALUES (
            v_moc_id, v_draft_revision_id, v_forked_moc_id, v_user_id
        );
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_fork() allowed forking a non-published revision');

    /* Fork source revision must belong to source_moc_id. */
    v_failed := false;
    BEGIN
        INSERT INTO moc.forks (
            source_moc_id, source_revision_id, forked_moc_id, forked_by_user_id
        )
        VALUES (
            v_moc_id, v_no_fork_revision_id, v_forked_moc_id, v_user_id
        );
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_fork() allowed a source_revision_id that does not belong to source_moc_id');

    /* Valid fork of a published revision on a forks-allowed MOC. */
    INSERT INTO moc.forks (
        source_moc_id, source_revision_id, forked_moc_id, forked_by_user_id
    )
    VALUES (
        v_moc_id, v_published_revision_id, v_forked_moc_id, v_user_id
    )
    RETURNING moc_fork_id INTO v_fork_id;

    PERFORM app.assert_true(v_fork_id IS NOT NULL,
        'validate_fork() rejected a legitimate fork of a published, forkable revision');

    /* ----------------------------------------------------------------------
     * moc.validate_subassembly_cycle()
     * -------------------------------------------------------------------- */
    INSERT INTO moc.subassemblies (moc_revision_id, subassembly_name)
    VALUES (v_draft_revision_id, 'TEST 5907 root subassembly')
    RETURNING subassembly_id INTO v_sub_a;

    INSERT INTO moc.subassemblies (
        moc_revision_id, parent_subassembly_id, subassembly_name
    )
    VALUES (v_draft_revision_id, v_sub_a, 'TEST 5907 child subassembly')
    RETURNING subassembly_id INTO v_sub_b;

    /* A subassembly cannot become its own ancestor. */
    v_failed := false;
    BEGIN
        UPDATE moc.subassemblies
           SET parent_subassembly_id = v_sub_b
         WHERE subassembly_id = v_sub_a;
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_subassembly_cycle() allowed a parent/child cycle');

    /* Parent and child subassemblies must belong to the same MOC revision. */
    v_failed := false;
    DECLARE
        v_other_sub uuid;
    BEGIN
        INSERT INTO moc.subassemblies (moc_revision_id, subassembly_name)
        VALUES (v_no_fork_revision_id, 'TEST 5907 foreign subassembly')
        RETURNING subassembly_id INTO v_other_sub;

        BEGIN
            UPDATE moc.subassemblies
               SET parent_subassembly_id = v_other_sub
             WHERE subassembly_id = v_sub_b;
        EXCEPTION
            WHEN OTHERS THEN v_failed := true;
        END;
    END;
    PERFORM app.assert_true(v_failed,
        'validate_subassembly_cycle() allowed a parent subassembly from a different MOC revision');
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5907_test_moc_lifecycle.sql');
