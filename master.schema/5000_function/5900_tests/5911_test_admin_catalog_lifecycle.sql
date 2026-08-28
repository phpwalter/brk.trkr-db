/*
===============================================================================
 File:           5000_function/5900_tests/5911_test_admin_catalog_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for generic admin catalog lifecycle routines.
 Depends On:     5000_function/5100_admin/5110_admin_catalog_lifecycle.sql
                 1100_security/1112_admin_execute_only.sql
                 5000_function/5900_tests/5910_test_admin_common.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5911_test_admin_catalog_lifecycle.sql', ARRAY['5000_function/5100_admin/5110_admin_catalog_lifecycle.sql', '1100_security/1112_admin_execute_only.sql', '5000_function/5900_tests/5910_test_admin_common.sql']::text[]);

\echo '[TEST] 5911_test_admin_catalog_lifecycle.sql'

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
    '00000000-0000-4000-8000-000000005911'::uuid,
    'bt_test_admin_5911',
    'BrickTrackr Admin Lifecycle Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

SELECT app.set_authenticated_user(
    '00000000-0000-4000-8000-000000005911'::uuid
);

SELECT app.set_request_context(
    '00000000-0000-4000-8000-000000005912'::uuid,
    '5911-admin-lifecycle-test',
    'ADMIN'
);

DO $$
DECLARE
    v_item_id uuid := gen_random_uuid();
    v_other_id uuid := gen_random_uuid();
    v_kind catalog.item_kind;
    v_status catalog.item_status;
    v_archived_at timestamptz;
    v_result jsonb;
    v_event_id uuid;
    v_metadata jsonb;
    v_failed boolean;
BEGIN
    SELECT e.enumlabel::catalog.item_kind
      INTO v_kind
      FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid
      JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'catalog'
       AND t.typname = 'item_kind'
     ORDER BY CASE WHEN e.enumlabel = 'OTHER' THEN 0 ELSE 1 END,
              e.enumsortorder
     LIMIT 1;

    PERFORM app.assert_true(v_kind IS NOT NULL, 'catalog.item_kind has no values');

    INSERT INTO catalog.items (
        catalog_item_id, item_kind, canonical_name, status
    )
    VALUES
        (v_item_id, v_kind, 'TEST lifecycle item', 'ACTIVE'),
        (v_other_id, v_kind, 'TEST lifecycle item 2', 'ACTIVE');

    /* ACTIVE -> RETIRED */
    v_result := admin.retire_catalog_item(v_item_id, '5911 retire test');

    SELECT status, archived_at
      INTO v_status, v_archived_at
      FROM catalog.items
     WHERE catalog_item_id = v_item_id;

    PERFORM app.assert_true(v_status = 'RETIRED',
        'retire_catalog_item() did not set RETIRED');
    PERFORM app.assert_true(v_archived_at IS NULL,
        'retire_catalog_item() unexpectedly set archived_at');
    PERFORM app.assert_true(
        v_result ->> 'old_status' = 'ACTIVE'
        AND v_result ->> 'new_status' = 'RETIRED',
        'retire_catalog_item() returned incorrect transition metadata'
    );

    /* RETIRED -> ARCHIVED */
    PERFORM admin.archive_catalog_item(v_item_id, '5911 archive test');

    SELECT status, archived_at
      INTO v_status, v_archived_at
      FROM catalog.items
     WHERE catalog_item_id = v_item_id;

    PERFORM app.assert_true(v_status = 'ARCHIVED',
        'archive_catalog_item() did not set ARCHIVED');
    PERFORM app.assert_true(v_archived_at IS NOT NULL,
        'archive_catalog_item() did not set archived_at');

    /* ARCHIVED -> ACTIVE */
    PERFORM admin.restore_catalog_item(
        v_item_id, 'ACTIVE', '5911 restore active test'
    );

    SELECT status, archived_at
      INTO v_status, v_archived_at
      FROM catalog.items
     WHERE catalog_item_id = v_item_id;

    PERFORM app.assert_true(v_status = 'ACTIVE',
        'restore_catalog_item(... ACTIVE ...) did not set ACTIVE');
    PERFORM app.assert_true(v_archived_at IS NULL,
        'restore_catalog_item(... ACTIVE ...) did not clear archived_at');

    /* ACTIVE -> ARCHIVED -> RETIRED */
    PERFORM admin.archive_catalog_item(
        v_item_id, '5911 archive for retired restore test'
    );
    PERFORM admin.restore_catalog_item(
        v_item_id, 'RETIRED', '5911 restore retired test'
    );

    SELECT status, archived_at
      INTO v_status, v_archived_at
      FROM catalog.items
     WHERE catalog_item_id = v_item_id;

    PERFORM app.assert_true(v_status = 'RETIRED',
        'restore_catalog_item(... RETIRED ...) did not set RETIRED');
    PERFORM app.assert_true(v_archived_at IS NULL,
        'restore_catalog_item(... RETIRED ...) did not clear archived_at');

    /* Empty reason rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.archive_catalog_item(v_other_id, '');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'Lifecycle mutation accepted an empty reason');

    /* Same-state transition rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.retire_catalog_item(
            v_item_id, 'same state should fail'
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23514' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'Lifecycle mutation accepted a same-state transition');

    /* Generic engine cannot enter SOURCE_MISSING. */
    v_failed := false;
    BEGIN
        PERFORM catalog.transition_item_status(
            v_other_id,
            'SOURCE_MISSING'::catalog.item_status,
            'source missing must be importer-controlled',
            'TEST'
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '42501' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'Generic lifecycle engine allowed SOURCE_MISSING entry');

    /* Generic engine cannot exit SOURCE_MISSING. */
    UPDATE catalog.items
       SET status = 'SOURCE_MISSING',
           archived_at = NULL
     WHERE catalog_item_id = v_other_id;

    v_failed := false;
    BEGIN
        PERFORM catalog.transition_item_status(
            v_other_id,
            'ACTIVE'::catalog.item_status,
            'source missing exit must be importer-controlled',
            'TEST'
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '42501' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'Generic lifecycle engine allowed SOURCE_MISSING exit');

    /* Restore target must be ACTIVE or RETIRED. */
    UPDATE catalog.items
       SET status = 'ARCHIVED',
           archived_at = clock_timestamp()
     WHERE catalog_item_id = v_other_id;

    v_failed := false;
    BEGIN
        PERFORM admin.restore_catalog_item(
            v_other_id,
            'SOURCE_MISSING',
            'invalid restore target'
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'restore_catalog_item() accepted an invalid target');

    /* Unknown item rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.archive_catalog_item(
            gen_random_uuid(),
            'unknown item test'
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0002' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'archive_catalog_item() did not reject an unknown item');

    /* Verify audit operation/reason on a real lifecycle change. */
    UPDATE catalog.items
       SET status = 'ACTIVE',
           archived_at = NULL
     WHERE catalog_item_id = v_other_id;

    PERFORM admin.archive_catalog_item(
        v_other_id,
        '5911 audit metadata test'
    );

    /*
     * Select the exact lifecycle event by its unique test reason.
     *
     * Do not infer insertion order from occurred_at/audit_event_id:
     * occurred_at uses transaction-stable time and UUIDv7 does not guarantee
     * total ordering for multiple events created in the same timestamp window.
     */
    SELECT e.audit_event_id, e.metadata
      INTO v_event_id, v_metadata
      FROM audit.events e
     WHERE e.entity_schema = 'catalog'
       AND e.entity_table = 'items'
       AND e.entity_id = v_other_id::text
       AND e.metadata ->> 'reason' = '5911 audit metadata test'
     LIMIT 1;

    PERFORM app.assert_true(v_event_id IS NOT NULL,
        'No lifecycle audit event was written');
    PERFORM app.assert_true(v_metadata ->> 'operation' = 'ARCHIVE',
        'Audit metadata operation is not ARCHIVE');
    PERFORM app.assert_true(
        v_metadata ->> 'reason' = '5911 audit metadata test',
        'Audit metadata reason is incorrect'
    );

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1
              FROM audit.changes c
             WHERE c.audit_event_id = v_event_id
               AND c.field_name = 'status'
        ),
        'Audit event does not contain a status field change'
    );
END;
$$;

/* Runtime roles must be unable to invoke admin lifecycle routines. */
DO $$
DECLARE
    v_role name;
    v_failed boolean;
BEGIN
    FOR v_role IN
        SELECT rolname
          FROM pg_roles
         WHERE rolname IN (
             'lego_api','lego_app','lego_importer','lego_reporting'
         )
         ORDER BY rolname
    LOOP
        v_failed := false;
        EXECUTE format('SET LOCAL ROLE %I', v_role);

        BEGIN
            PERFORM admin.archive_catalog_item(
                gen_random_uuid(),
                'authorization negative test'
            );
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
            format('%s was able to invoke an admin lifecycle routine', v_role)
        );
    END LOOP;
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5911_test_admin_catalog_lifecycle.sql');
