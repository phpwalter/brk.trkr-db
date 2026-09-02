/*
===============================================================================
 File:           5000_function/5900_tests/5911_test_admin_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for the admin.* execute-only surface: the
                 system-administrator guard, generic catalog lifecycle
                 transitions, balanced financial transaction posting, and
                 catalog image/instruction asset administration.
 Depends On:     5000_function/5100_admin/5100_admin_common.sql
                 5000_function/5100_admin/5110_admin_catalog_lifecycle.sql
                 5000_function/5100_admin/5130_admin_finance.sql
                 5000_function/5200_api/5210_api_operational.sql
                 1100_security/1112_admin_execute_only.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5911_test_admin_lifecycle.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql', '5000_function/5100_admin/5130_admin_finance.sql', '5000_function/5200_api/5210_api_operational.sql', '1100_security/1112_admin_execute_only.sql']::text[]);

\echo '[TEST] 5911_test_admin_lifecycle.sql'

BEGIN;

/*
 * Establish a real authenticated application actor for audit-trigger coverage
 * and for the financial posting phase, which requires a genuine USER context.
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

-- ADMIN actor class never carries an application user UUID (see
-- 5709_system_request_context.sql); the identity.users fixture row above
-- exists for audit-trigger coverage and for the later USER-context financial
-- posting phase, not for ADMIN context establishment.
SELECT app.set_request_context(
    NULL,
    '00000000-0000-4000-8000-000000005912'::uuid,
    '5911-admin-lifecycle-test',
    'ADMIN'
);

/* ==================================================================== */
/* Phase 1: admin.assert_system_admin() guard and audit trigger support  */
/* ==================================================================== */

/* Non-admin runtime roles must not pass the system-admin guard. */
DO $$
DECLARE
    v_role name;
    v_failed boolean;
BEGIN
    FOR v_role IN
        SELECT rolname
          FROM pg_roles
         WHERE rolname IN ('brktrkr_api','brktrkr_import','brktrkr_reporting')
         ORDER BY rolname
    LOOP
        v_failed := false;
        EXECUTE format('SET LOCAL ROLE %I', v_role);

        BEGIN
            PERFORM admin.assert_system_admin();
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
            format('%s was not rejected by admin.assert_system_admin()', v_role)
        );
    END LOOP;
END;
$$;

/*
 * brktrkr_admin must not execute the internal guard directly. Positive admin
 * authorization is exercised through the approved SECURITY DEFINER lifecycle
 * entry points below.
 */
DO $$
DECLARE
    v_failed boolean := false;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'brktrkr_admin') THEN
        SET LOCAL ROLE brktrkr_admin;

        BEGIN
            PERFORM admin.assert_system_admin();
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
            'brktrkr_admin unexpectedly executed internal admin.assert_system_admin() directly'
        );
    END IF;
END;
$$;

/* Installed audit trigger must support lifecycle operation/reason metadata. */
SELECT app.assert_true(
    pg_get_functiondef('audit.capture_row_change()'::regprocedure)
        LIKE '%app.audit_reason%'
    AND
    pg_get_functiondef('audit.capture_row_change()'::regprocedure)
        LIKE '%app.audit_operation%',
    'audit.capture_row_change() is missing admin audit metadata support'
);

/* ==================================================================== */
/* Phase 2: generic catalog lifecycle transitions                        */
/* ==================================================================== */

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

/* ==================================================================== */
/* Phase 3: balanced financial transaction posting (USER context)        */
/* ==================================================================== */

SELECT app.set_request_context(
    '00000000-0000-4000-8000-000000005911'::uuid,
    gen_random_uuid(),
    '5911-admin-lifecycle-test-finance',
    'USER'
);

DO $$
DECLARE
    v_asset_account uuid := gen_random_uuid();
    v_revenue_account uuid := gen_random_uuid();
    v_inactive_account uuid := gen_random_uuid();
    v_eur_account uuid := gen_random_uuid();
    v_balanced_entries jsonb;
    v_transaction_id uuid;
    v_transaction_id_2 uuid;
    v_description text;
    v_debit_total numeric;
    v_credit_total numeric;
    v_failed boolean;
BEGIN
    INSERT INTO finance.accounts (financial_account_id, account_code, account_name, account_kind, currency, is_active)
    VALUES
        (v_asset_account, 'TEST-5911-ASSET', 'TEST asset account 5911', 'ASSET', 'USD', true),
        (v_revenue_account, 'TEST-5911-REVENUE', 'TEST revenue account 5911', 'REVENUE', 'USD', true),
        (v_inactive_account, 'TEST-5911-INACTIVE', 'TEST inactive account 5911', 'ASSET', 'USD', false),
        (v_eur_account, 'TEST-5911-EUR', 'TEST EUR account 5911', 'ASSET', 'EUR', true);

    v_balanced_entries := jsonb_build_array(
        jsonb_build_object('account_id', v_asset_account, 'debit', 100.00),
        jsonb_build_object('account_id', v_revenue_account, 'credit', 100.00)
    );

    /* Happy path: post a balanced transaction. */
    v_transaction_id := admin.post_financial_transaction(
        'test-idem-5911-happy-01',
        'USD',
        'TEST balanced transaction 5911',
        v_balanced_entries,
        NULL
    );

    PERFORM app.assert_true(v_transaction_id IS NOT NULL,
        'post_financial_transaction() did not return a transaction id');

    SELECT description INTO v_description
      FROM finance.transactions
     WHERE financial_transaction_id = v_transaction_id;
    PERFORM app.assert_true(v_description = 'TEST balanced transaction 5911',
        'Posted transaction has the wrong description');

    SELECT
        COALESCE(sum(debit_amount), 0),
        COALESCE(sum(credit_amount), 0)
      INTO v_debit_total, v_credit_total
      FROM finance.ledger_entries
     WHERE financial_transaction_id = v_transaction_id;
    PERFORM app.assert_true(v_debit_total = 100.00 AND v_credit_total = 100.00,
        'Posted ledger entries are not balanced at 100.00/100.00');

    /* Idempotency: identical request replays the same transaction. */
    v_transaction_id_2 := admin.post_financial_transaction(
        'test-idem-5911-happy-01',
        'USD',
        'TEST balanced transaction 5911',
        v_balanced_entries,
        NULL
    );
    PERFORM app.assert_true(v_transaction_id_2 = v_transaction_id,
        'post_financial_transaction() did not replay the same transaction for an identical idempotent request');

    /* Idempotency: same key with a different payload is rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.post_financial_transaction(
            'test-idem-5911-happy-01',
            'USD',
            'TEST a different description 5911',
            v_balanced_entries,
            NULL
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23505' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'post_financial_transaction() reused an idempotency key with a different request payload');

    /* Unbalanced entries are rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.post_financial_transaction(
            'test-idem-5911-unbalanced-01',
            'USD',
            'TEST unbalanced transaction 5911',
            jsonb_build_array(
                jsonb_build_object('account_id', v_asset_account, 'debit', 100.00),
                jsonb_build_object('account_id', v_revenue_account, 'credit', 50.00)
            ),
            NULL
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
        'post_financial_transaction() accepted an unbalanced set of entries');

    /* Missing idempotency key is rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.post_financial_transaction(
            NULL,
            'USD',
            'TEST missing idempotency key 5911',
            v_balanced_entries,
            NULL
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
        'post_financial_transaction() accepted a NULL idempotency key');

    /* Inactive account is rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.post_financial_transaction(
            'test-idem-5911-inactive-01',
            'USD',
            'TEST inactive account 5911',
            jsonb_build_array(
                jsonb_build_object('account_id', v_inactive_account, 'debit', 10.00),
                jsonb_build_object('account_id', v_revenue_account, 'credit', 10.00)
            ),
            NULL
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23503' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'post_financial_transaction() accepted an inactive ledger account');

    /* Currency mismatch between transaction and account is rejected. */
    v_failed := false;
    BEGIN
        PERFORM admin.post_financial_transaction(
            'test-idem-5911-currency-01',
            'USD',
            'TEST currency mismatch 5911',
            jsonb_build_array(
                jsonb_build_object('account_id', v_eur_account, 'debit', 10.00),
                jsonb_build_object('account_id', v_revenue_account, 'credit', 10.00)
            ),
            NULL
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23503' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'post_financial_transaction() accepted a ledger account in a different currency');
END;
$$;

/* ==================================================================== */
/* Phase 4: catalog image and instruction asset administration           */
/* ==================================================================== */

SELECT app.set_request_context(
    NULL,
    gen_random_uuid(),
    '5911-admin-lifecycle-test-assets',
    'ADMIN'
);

DO $$
DECLARE
    v_image_item_id uuid := gen_random_uuid();
    v_instruction_item_id uuid := gen_random_uuid();
    v_kind catalog.item_kind;
    v_image_id_1 uuid;
    v_image_id_2 uuid;
    v_image_id_2_again uuid;
    v_asset_id uuid;
    v_asset_id_again uuid;
    v_alt_text text;
    v_is_primary boolean;
    v_booklet smallint;
    v_removed boolean;
BEGIN
    SELECT e.enumlabel::catalog.item_kind
      INTO v_kind
      FROM pg_enum e
      JOIN pg_type t ON t.oid = e.enumtypid
      JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'catalog'
       AND t.typname = 'item_kind'
       AND e.enumlabel = 'PART';

    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES (v_image_item_id, COALESCE(v_kind, 'OTHER'), 'TEST image item 5911', 'ACTIVE');

    INSERT INTO catalog.items (catalog_item_id, item_kind, canonical_name, status)
    VALUES (v_instruction_item_id, 'INSTRUCTIONS', 'TEST instructions item 5911', 'ACTIVE');
    INSERT INTO catalog.instructions (catalog_item_id) VALUES (v_instruction_item_id);

    /* Set a primary image, then set a second image as primary. */
    v_image_id_1 := admin.set_catalog_item_image(
        v_image_item_id, 'test/5911/img1.png', 'first image', true,
        public.digest(pg_catalog.convert_to('5911-img1', 'UTF8'), 'sha256')
    );
    PERFORM app.assert_true(v_image_id_1 IS NOT NULL,
        'set_catalog_item_image() did not return an image id');

    v_image_id_2 := admin.set_catalog_item_image(
        v_image_item_id, 'test/5911/img2.png', 'second image', true, NULL
    );
    PERFORM app.assert_true(v_image_id_2 IS NOT NULL,
        'set_catalog_item_image() did not return an image id for the second image');

    SELECT is_primary INTO v_is_primary
      FROM catalog.item_images
     WHERE catalog_item_image_id = v_image_id_1;
    PERFORM app.assert_true(NOT v_is_primary,
        'set_catalog_item_image() did not demote the previous primary image');

    SELECT is_primary INTO v_is_primary
      FROM catalog.item_images
     WHERE catalog_item_image_id = v_image_id_2;
    PERFORM app.assert_true(v_is_primary,
        'set_catalog_item_image() did not mark the new image primary');

    /* Re-posting the same storage_key upserts the existing row. */
    v_image_id_2_again := admin.set_catalog_item_image(
        v_image_item_id, 'test/5911/img2.png', 'second image updated', true, NULL
    );
    PERFORM app.assert_true(v_image_id_2_again = v_image_id_2,
        'set_catalog_item_image() did not upsert on a repeated storage_key');

    SELECT alt_text INTO v_alt_text
      FROM catalog.item_images
     WHERE catalog_item_image_id = v_image_id_2;
    PERFORM app.assert_true(v_alt_text = 'second image updated',
        'set_catalog_item_image() did not update alt_text on upsert');

    v_removed := admin.remove_catalog_item_image(v_image_id_2);
    PERFORM app.assert_true(v_removed,
        'remove_catalog_item_image() did not report removing an existing image');
    PERFORM app.assert_true(
        NOT EXISTS (SELECT 1 FROM catalog.item_images WHERE catalog_item_image_id = v_image_id_2),
        'remove_catalog_item_image() did not delete the image row'
    );

    v_removed := admin.remove_catalog_item_image(gen_random_uuid());
    PERFORM app.assert_true(NOT v_removed,
        'remove_catalog_item_image() reported removing an unknown image');

    /* Instruction assets: create, upsert on conflict, remove. */
    v_asset_id := admin.set_instruction_asset(
        v_instruction_item_id, 'test/5911/instr1.pdf', 'en', 1::smallint,
        public.digest(pg_catalog.convert_to('5911-instr1', 'UTF8'), 'sha256')::app.sha256_digest, 24
    );
    PERFORM app.assert_true(v_asset_id IS NOT NULL,
        'set_instruction_asset() did not return an asset id');

    v_asset_id_again := admin.set_instruction_asset(
        v_instruction_item_id, 'test/5911/instr1.pdf', 'fr', 2::smallint, NULL::app.sha256_digest, 30
    );
    PERFORM app.assert_true(v_asset_id_again = v_asset_id,
        'set_instruction_asset() did not upsert on a repeated storage_key');

    SELECT booklet_number INTO v_booklet
      FROM catalog.instruction_assets
     WHERE instruction_asset_id = v_asset_id;
    PERFORM app.assert_true(v_booklet = 2,
        'set_instruction_asset() did not update booklet_number on upsert');

    v_removed := admin.remove_instruction_asset(v_asset_id);
    PERFORM app.assert_true(v_removed,
        'remove_instruction_asset() did not report removing an existing asset');
    PERFORM app.assert_true(
        NOT EXISTS (SELECT 1 FROM catalog.instruction_assets WHERE instruction_asset_id = v_asset_id),
        'remove_instruction_asset() did not delete the asset row'
    );

    v_removed := admin.remove_instruction_asset(gen_random_uuid());
    PERFORM app.assert_true(NOT v_removed,
        'remove_instruction_asset() reported removing an unknown asset');
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
             'brktrkr_api','brktrkr_import','brktrkr_reporting'
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

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5911_test_admin_lifecycle.sql');
