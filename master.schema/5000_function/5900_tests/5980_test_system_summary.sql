
/*
===============================================================================
 File:           5000_function/5900_tests/5980_test_system_summary.sql
 Purpose:        Contract-test incremental system summary maintenance.
 Depends On:     1000_reporting/1010_reporting_system_summary.sql
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5980_test_system_summary.sql', ARRAY['1000_reporting/1010_reporting_system_summary.sql']::text[]);

BEGIN;


/*
 * Establish a real authenticated application actor for audit-trigger coverage.
 * identity.users is audited, so disable only its audit trigger for the fixture
 * insert. The entire test runs inside a transaction and rolls back.
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
    '00000000-0000-4000-8000-000000005980'::uuid,
    'bt_test_summary_5980',
    'BrickTrackr System Summary Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

SELECT app.set_authenticated_user(
    '00000000-0000-4000-8000-000000005980'::uuid
);

SELECT app.set_request_context(
    '00000000-0000-4000-8000-000000005981'::uuid,
    '5980-system-summary-test',
    'SYSTEM'
);

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
END
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5980_test_system_summary.sql');
\echo '[TEST PASS] 5980_test_system_summary.sql'
