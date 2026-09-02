/*
===============================================================================
 File:           5000_function/5900_tests/5908_test_audit_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for the audit schema: append-only enforcement
                 and generic JSONB row-change capture across business tables.
 Depends On:     5000_function/5700_system/5707_system_audit.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5908_test_audit_lifecycle.sql', ARRAY['5000_function/5700_system/5707_system_audit.sql']::text[]);

\echo '[TEST] 5908_test_audit_lifecycle.sql'

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
    '00000000-0000-4000-8000-000000005908'::uuid,
    'bt_test_audit_5908',
    'BrickTrackr Audit Lifecycle Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

SELECT app.set_request_context(
    '00000000-0000-4000-8000-000000005908'::uuid,
    '00000000-0000-4000-8000-000000005909'::uuid,
    '5908-audit-lifecycle-test',
    'USER'
);

DO $$
DECLARE
    v_user_id uuid := '00000000-0000-4000-8000-000000005908'::uuid;
    v_owner_id uuid;
    v_item_id uuid := gen_random_uuid();
    v_moc_item_id uuid := gen_random_uuid();
    v_moc_id uuid;
    v_kind catalog.item_kind;
    v_event_id uuid;
    v_rename_event_id uuid;
    v_metadata jsonb;
    v_failed boolean;
    v_change_count integer;
BEGIN
    /* ------------------------------------------------------------------
     * audit.prevent_mutation() -- append-only enforcement on both audit
     * tables, exercised against a real event captured by
     * audit.capture_row_change() below.
     * ------------------------------------------------------------------ */

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

    /* ------------------------------------------------------------------
     * audit.capture_row_change() -- INSERT capture on catalog.items, one
     * of the 11 business tables wired to trg_audit_* triggers.
     * ------------------------------------------------------------------ */
    INSERT INTO catalog.items (
        catalog_item_id, item_kind, canonical_name, status
    )
    VALUES (v_item_id, v_kind, 'TEST 5908 audited item', 'ACTIVE');

    SELECT e.audit_event_id, e.metadata
      INTO v_event_id, v_metadata
      FROM audit.events e
     WHERE e.entity_schema = 'catalog'
       AND e.entity_table = 'items'
       AND e.entity_id = v_item_id::text
       AND e.event_type = 'INSERT'
     LIMIT 1;

    PERFORM app.assert_true(v_event_id IS NOT NULL,
        'capture_row_change() did not write an INSERT audit event for catalog.items');
    PERFORM app.assert_true(
        (SELECT actor_user_id FROM audit.events WHERE audit_event_id = v_event_id) = v_user_id,
        'capture_row_change() did not record the current USER actor'
    );

    /* Every populated column on the new row must appear as a change, since
     * old_value is NULL for an INSERT (every key differs from NULL). */
    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM audit.changes c
             WHERE c.audit_event_id = v_event_id
               AND c.field_name = 'canonical_name'
               AND c.new_value = to_jsonb('TEST 5908 audited item'::text)
        ),
        'capture_row_change() did not record the canonical_name field on INSERT'
    );

    /* ------------------------------------------------------------------
     * UPDATE capture: only the fields that actually change produce
     * audit.changes rows.
     * ------------------------------------------------------------------ */
    UPDATE catalog.items
       SET canonical_name = 'TEST 5908 audited item (renamed)'
     WHERE catalog_item_id = v_item_id;

    SELECT e.audit_event_id
      INTO v_event_id
      FROM audit.events e
     WHERE e.entity_schema = 'catalog'
       AND e.entity_table = 'items'
       AND e.entity_id = v_item_id::text
       AND e.event_type = 'UPDATE'
     LIMIT 1;

    PERFORM app.assert_true(v_event_id IS NOT NULL,
        'capture_row_change() did not write an UPDATE audit event for catalog.items');

    /* audit.events.occurred_at defaults to now(), which is frozen for the
     * whole transaction -- every event in this test shares the same
     * timestamp, so it cannot be used to order/distinguish events. Remember
     * this event's id explicitly instead. */
    v_rename_event_id := v_event_id;

    SELECT count(*) INTO v_change_count
      FROM audit.changes
     WHERE audit_event_id = v_event_id;

    PERFORM app.assert_true(
        v_change_count = 1,
        'capture_row_change() recorded changes for unmodified fields on UPDATE'
    );
    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM audit.changes c
             WHERE c.audit_event_id = v_event_id
               AND c.field_name = 'canonical_name'
               AND c.old_value = to_jsonb('TEST 5908 audited item'::text)
               AND c.new_value = to_jsonb('TEST 5908 audited item (renamed)'::text)
        ),
        'capture_row_change() did not record the correct old/new canonical_name values'
    );

    /* A no-op UPDATE (no column values actually change) must still write an
     * audit.events row (one per statement) but no audit.changes rows. */
    UPDATE catalog.items
       SET canonical_name = canonical_name
     WHERE catalog_item_id = v_item_id;

    SELECT e.audit_event_id
      INTO v_event_id
      FROM audit.events e
     WHERE e.entity_schema = 'catalog'
       AND e.entity_table = 'items'
       AND e.entity_id = v_item_id::text
       AND e.event_type = 'UPDATE'
       AND e.audit_event_id <> v_rename_event_id
     LIMIT 1;

    PERFORM app.assert_true(v_event_id IS NOT NULL,
        'capture_row_change() did not write an audit event for the no-op UPDATE');

    SELECT count(*) INTO v_change_count
      FROM audit.changes
     WHERE audit_event_id = v_event_id;

    PERFORM app.assert_true(
        v_change_count = 0,
        'capture_row_change() recorded a change row for a field that did not change'
    );

    /* ------------------------------------------------------------------
     * DELETE capture: old_value populated, new_value NULL.
     * ------------------------------------------------------------------ */
    DELETE FROM catalog.items WHERE catalog_item_id = v_item_id;

    SELECT e.audit_event_id
      INTO v_event_id
      FROM audit.events e
     WHERE e.entity_schema = 'catalog'
       AND e.entity_table = 'items'
       AND e.entity_id = v_item_id::text
       AND e.event_type = 'DELETE'
     LIMIT 1;

    PERFORM app.assert_true(v_event_id IS NOT NULL,
        'capture_row_change() did not write a DELETE audit event for catalog.items');
    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM audit.changes c
             WHERE c.audit_event_id = v_event_id
               AND c.field_name = 'canonical_name'
               AND c.new_value IS NULL
        ),
        'capture_row_change() did not null out new_value on DELETE'
    );

    /* ------------------------------------------------------------------
     * A second attached table: moc.mocs, confirming the trigger is wired
     * beyond the identity/catalog domains covered above.
     * ------------------------------------------------------------------ */
    INSERT INTO identity.owners (owner_type, user_id)
    VALUES ('USER', v_user_id)
    RETURNING owner_id INTO v_owner_id;

    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES (v_moc_item_id, 'MOC', 'TEST 5908 moc item', 'ACTIVE');

    INSERT INTO catalog.mocs (catalog_item_id)
    VALUES (v_moc_item_id);

    INSERT INTO moc.mocs (
        moc_id, catalog_item_id, owner_id, title, created_by_user_id
    )
    VALUES (gen_random_uuid(), v_moc_item_id, v_owner_id, 'TEST 5908 moc', v_user_id)
    RETURNING moc_id INTO v_moc_id;

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1 FROM audit.events e
             WHERE e.entity_schema = 'moc'
               AND e.entity_table = 'mocs'
               AND e.entity_id = v_moc_id::text
               AND e.event_type = 'INSERT'
        ),
        'capture_row_change() is not wired to moc.mocs'
    );

    /* ------------------------------------------------------------------
     * audit.prevent_mutation(): audit.events and audit.changes are
     * append-only, even for rows written moments ago by triggers above.
     * ------------------------------------------------------------------ */
    v_failed := false;
    BEGIN
        UPDATE audit.events
           SET metadata = '{"tampered":true}'::jsonb
         WHERE audit_event_id = v_event_id;
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_mutation() allowed UPDATE of audit.events');

    v_failed := false;
    BEGIN
        DELETE FROM audit.events WHERE audit_event_id = v_event_id;
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_mutation() allowed DELETE of audit.events');

    v_failed := false;
    BEGIN
        UPDATE audit.changes
           SET new_value = '"tampered"'::jsonb
         WHERE audit_event_id = v_event_id;
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_mutation() allowed UPDATE of audit.changes');

    v_failed := false;
    BEGIN
        DELETE FROM audit.changes WHERE audit_event_id = v_event_id;
    EXCEPTION
        WHEN OTHERS THEN v_failed := true;
    END;
    PERFORM app.assert_true(v_failed,
        'prevent_mutation() allowed DELETE of audit.changes');
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5908_test_audit_lifecycle.sql');
