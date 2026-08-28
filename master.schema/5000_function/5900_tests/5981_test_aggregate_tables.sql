/*
===============================================================================
 File:           5000_function/5900_tests/5981_test_aggregate_tables.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Contract-test the Greenfield aggregate-table surface and
                 catalog-kind transactional maintenance.
 Depends On:     1000_reporting/1011_reporting_aggregate_tables.sql
                 5000_function/5900_tests/5980_test_system_summary.sql
 Creates:        Test assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5981_test_aggregate_tables.sql', ARRAY['1000_reporting/1011_reporting_aggregate_tables.sql', '5000_function/5900_tests/5980_test_system_summary.sql']::text[]);

\echo '[TEST] 5981_test_aggregate_tables'

BEGIN;

/* Audit-trigger fixture, rollback-safe. */
ALTER TABLE identity.users DISABLE TRIGGER trg_audit_users;

INSERT INTO identity.users (
    user_id,
    username,
    display_name,
    account_status,
    activated_at
)
VALUES (
    '00000000-0000-4000-8000-000000005982'::uuid,
    'bt_test_aggregate_5981',
    'BrickTrackr Aggregate Table Test',
    'ACTIVE',
    clock_timestamp()
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;

SELECT app.set_authenticated_user(
    '00000000-0000-4000-8000-000000005982'::uuid
);

SELECT app.set_request_context(
    '00000000-0000-4000-8000-000000005983'::uuid,
    '5981-aggregate-table-test',
    'SYSTEM'
);

DO $$
DECLARE
    v_id uuid := app.uuid_v7();
    v_before bigint;
    v_after bigint;
BEGIN
    SELECT total_items
      INTO v_before
      FROM reporting.catalog_kind_summary
     WHERE item_kind = 'INSTRUCTIONS';

    INSERT INTO catalog.items(
        catalog_item_id,
        item_kind,
        canonical_name,
        status
    )
    VALUES (
        v_id,
        'INSTRUCTIONS',
        'Aggregate table test instructions',
        'ACTIVE'
    );

    SELECT total_items
      INTO v_after
      FROM reporting.catalog_kind_summary
     WHERE item_kind = 'INSTRUCTIONS';

    PERFORM app.assert_true(
        v_after = v_before + 1,
        'catalog_kind_summary did not increment INSTRUCTIONS total'
    );

    PERFORM app.assert_true(
        (
            SELECT active_items
            FROM reporting.catalog_kind_summary
            WHERE item_kind = 'INSTRUCTIONS'
        ) >= 1,
        'catalog_kind_summary did not increment ACTIVE INSTRUCTIONS'
    );

    UPDATE catalog.items
       SET status = 'RETIRED'
     WHERE catalog_item_id = v_id;

    PERFORM app.assert_true(
        (
            SELECT retired_items
            FROM reporting.catalog_kind_summary
            WHERE item_kind = 'INSTRUCTIONS'
        ) >= 1,
        'catalog_kind_summary did not track ACTIVE -> RETIRED'
    );
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5981_test_aggregate_tables.sql');
\echo '[TEST PASS] 5981_test_aggregate_tables.sql'
