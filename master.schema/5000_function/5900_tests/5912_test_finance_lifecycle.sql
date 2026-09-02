/*
===============================================================================
 File:           5000_function/5900_tests/5912_test_finance_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for finance-schema ledger integrity triggers
                 and the source-event provenance payload hash.
 Depends On:     5000_function/5100_admin/5130_admin_finance.sql
                 0760_finance/0761_financial_readiness_anchors.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5912_test_finance_lifecycle.sql', ARRAY['5000_function/5100_admin/5130_admin_finance.sql', '0760_finance/0761_financial_readiness_anchors.sql']::text[]);

\echo '[TEST] 5912_test_finance_lifecycle.sql'

BEGIN;

/*
 * finance.transactions.posted_by_user_id is nullable, and none of the
 * routines exercised here call identity.current_user_id(), so a plain ADMIN
 * context is sufficient for this entire file. Ledger rows are inserted
 * directly to exercise the trigger layer independently of
 * admin.post_financial_transaction(), which is covered separately.
 */
SELECT app.set_request_context(
    NULL,
    gen_random_uuid(),
    '5912-finance-lifecycle-test',
    'ADMIN'
);

DO $$
DECLARE
    v_asset_account uuid := gen_random_uuid();
    v_revenue_account uuid := gen_random_uuid();
    v_eur_account uuid := gen_random_uuid();
    v_unposted_account uuid := gen_random_uuid();

    v_txn_balanced uuid := gen_random_uuid();
    v_txn_balance_probe uuid := gen_random_uuid();
    v_txn_currency_probe uuid := gen_random_uuid();

    v_failed boolean;
BEGIN
    INSERT INTO finance.accounts (financial_account_id, account_code, account_name, account_kind, currency, is_active)
    VALUES
        (v_asset_account, 'TEST-5912-ASSET', 'TEST asset account 5912', 'ASSET', 'USD', true),
        (v_revenue_account, 'TEST-5912-REVENUE', 'TEST revenue account 5912', 'REVENUE', 'USD', true),
        (v_eur_account, 'TEST-5912-EUR', 'TEST EUR account 5912', 'ASSET', 'EUR', true),
        (v_unposted_account, 'TEST-5912-UNPOSTED', 'TEST unposted account 5912', 'ASSET', 'USD', true);

    /* -------------------------------------------------------------- */
    /* A balanced, fully-posted transaction used by later assertions.  */
    /* -------------------------------------------------------------- */
    INSERT INTO finance.transactions (
        financial_transaction_id, idempotency_key, request_hash, description, currency
    )
    VALUES (
        v_txn_balanced,
        'test-idem-5912-balanced-01',
        public.digest(pg_catalog.convert_to('test-idem-5912-balanced-01', 'UTF8'), 'sha256'),
        'TEST balanced ledger fixture 5912',
        'USD'
    );

    INSERT INTO finance.ledger_entries (financial_transaction_id, financial_account_id, debit_amount, credit_amount)
    VALUES
        (v_txn_balanced, v_asset_account, 100.00, 0),
        (v_txn_balanced, v_revenue_account, 0, 100.00);

    /* ================================================================ */
    /* finance.trg_validate_transaction_balance()                        */
    /* ================================================================ */
    INSERT INTO finance.transactions (
        financial_transaction_id, idempotency_key, request_hash, description, currency
    )
    VALUES (
        v_txn_balance_probe,
        'test-idem-5912-unbalanced-01',
        public.digest(pg_catalog.convert_to('test-idem-5912-unbalanced-01', 'UTF8'), 'sha256'),
        'TEST unbalanced ledger probe 5912',
        'USD'
    );

    /*
     * Only the ledger-level balance trigger is forced immediate here: the
     * transaction-level trigger would otherwise fire the instant the
     * transaction row above is inserted (before any ledger entries exist)
     * and reject a legitimately balanced multi-statement posting sequence.
     */
    SET CONSTRAINTS finance.trg_finance_transaction_balance_on_ledger IMMEDIATE;

    v_failed := false;
    BEGIN
        INSERT INTO finance.ledger_entries (financial_transaction_id, financial_account_id, debit_amount, credit_amount)
        VALUES (v_txn_balance_probe, v_asset_account, 50.00, 0);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23514' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_validate_transaction_balance() accepted a one-sided ledger entry');

    SET CONSTRAINTS finance.trg_finance_transaction_balance_on_ledger DEFERRED;

    /* ================================================================ */
    /* finance.trg_validate_ledger_currency()                            */
    /* ================================================================ */
    INSERT INTO finance.transactions (
        financial_transaction_id, idempotency_key, request_hash, description, currency
    )
    VALUES (
        v_txn_currency_probe,
        'test-idem-5912-currency-01',
        public.digest(pg_catalog.convert_to('test-idem-5912-currency-01', 'UTF8'), 'sha256'),
        'TEST currency mismatch probe 5912',
        'USD'
    );

    v_failed := false;
    BEGIN
        INSERT INTO finance.ledger_entries (financial_transaction_id, financial_account_id, debit_amount, credit_amount)
        VALUES (v_txn_currency_probe, v_eur_account, 10.00, 0);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23514' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_validate_ledger_currency() accepted a ledger entry in a different currency than its transaction');

    v_failed := false;
    BEGIN
        INSERT INTO finance.ledger_entries (financial_transaction_id, financial_account_id, debit_amount, credit_amount)
        VALUES (v_txn_currency_probe, gen_random_uuid(), 10.00, 0);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '23503' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_validate_ledger_currency() accepted a ledger entry referencing an unresolvable account');

    /* ================================================================ */
    /* finance.trg_protect_posted_account_identity()                     */
    /* ================================================================ */
    v_failed := false;
    BEGIN
        UPDATE finance.accounts SET currency = 'EUR' WHERE financial_account_id = v_asset_account;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_protect_posted_account_identity() allowed changing the currency of a posted account');

    /* Non-identity columns remain freely editable on a posted account. */
    UPDATE finance.accounts SET account_name = 'TEST asset account 5912 renamed' WHERE financial_account_id = v_asset_account;
    PERFORM app.assert_true(
        (SELECT account_name FROM finance.accounts WHERE financial_account_id = v_asset_account)
            = 'TEST asset account 5912 renamed',
        'finance.trg_protect_posted_account_identity() blocked a non-identity column update'
    );

    /* Identity columns remain editable on an account with no posted ledger entries. */
    UPDATE finance.accounts SET account_code = 'TEST-5912-UNPOSTED-RENAMED' WHERE financial_account_id = v_unposted_account;
    PERFORM app.assert_true(
        (SELECT account_code FROM finance.accounts WHERE financial_account_id = v_unposted_account)
            = 'TEST-5912-UNPOSTED-RENAMED',
        'finance.trg_protect_posted_account_identity() blocked an identity column update on an unposted account'
    );

    /* ================================================================ */
    /* finance.trg_prevent_ledger_mutation()                             */
    /* ================================================================ */
    v_failed := false;
    BEGIN
        UPDATE finance.transactions SET description = 'TEST mutated' WHERE financial_transaction_id = v_txn_balanced;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_prevent_ledger_mutation() allowed an UPDATE on finance.transactions');

    v_failed := false;
    BEGIN
        DELETE FROM finance.transactions WHERE financial_transaction_id = v_txn_balanced;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_prevent_ledger_mutation() allowed a DELETE on finance.transactions');

    v_failed := false;
    BEGIN
        UPDATE finance.ledger_entries SET debit_amount = 999 WHERE financial_transaction_id = v_txn_balanced;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_prevent_ledger_mutation() allowed an UPDATE on finance.ledger_entries');

    v_failed := false;
    BEGIN
        DELETE FROM finance.ledger_entries WHERE financial_transaction_id = v_txn_balanced;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_prevent_ledger_mutation() allowed a DELETE on finance.ledger_entries');
END;
$$;

/* ==================================================================== */
/* finance.trg_hash_source_event_payload() and source_events invariants  */
/* ==================================================================== */

DO $$
DECLARE
    v_payload jsonb := '{"order_ref": "TEST-5912", "amount_cents": 4200, "nested": {"a": 1, "b": [1, 2, 3]}}'::jsonb;
    v_stored_payload jsonb;
    v_stored_hash app.sha256_digest;
    v_expected_hash app.sha256_digest;
    v_failed boolean;
BEGIN
    INSERT INTO finance.source_events (
        idempotency_key, source_system, event_type, source_object_type,
        source_object_key, occurred_at, payload
    )
    VALUES (
        'test-src-evt-5912-01', 'TEST_SOURCE', 'TEST_EVENT', 'TEST_OBJECT',
        'obj-5912-01', clock_timestamp(), v_payload
    );

    SELECT payload, payload_sha256
      INTO v_stored_payload, v_stored_hash
      FROM finance.source_events
     WHERE idempotency_key = 'test-src-evt-5912-01';

    v_expected_hash := public.digest(pg_catalog.convert_to(v_stored_payload::text, 'UTF8'), 'sha256');

    PERFORM app.assert_true(v_stored_hash IS NOT NULL,
        'finance.trg_hash_source_event_payload() did not populate payload_sha256');
    PERFORM app.assert_true(v_stored_hash = v_expected_hash,
        'finance.trg_hash_source_event_payload() computed an incorrect payload_sha256');

    /* Duplicate idempotency_key is rejected. */
    v_failed := false;
    BEGIN
        INSERT INTO finance.source_events (
            idempotency_key, source_system, event_type, source_object_type,
            source_object_key, occurred_at, payload
        )
        VALUES (
            'test-src-evt-5912-01', 'TEST_SOURCE', 'TEST_EVENT', 'TEST_OBJECT',
            'obj-5912-02', clock_timestamp(), '{}'::jsonb
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
        'finance.source_events accepted a duplicate idempotency_key');

    /* An amount without a currency violates the source-amount check. */
    v_failed := false;
    BEGIN
        INSERT INTO finance.source_events (
            idempotency_key, source_system, event_type, source_object_type,
            source_object_key, occurred_at, amount, currency
        )
        VALUES (
            'test-src-evt-5912-03', 'TEST_SOURCE', 'TEST_EVENT', 'TEST_OBJECT',
            'obj-5912-03', clock_timestamp(), 10.00, NULL
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
        'finance.source_events accepted a non-null amount without a currency');

    /* Blank source_system is rejected. */
    v_failed := false;
    BEGIN
        INSERT INTO finance.source_events (
            idempotency_key, source_system, event_type, source_object_type,
            source_object_key, occurred_at
        )
        VALUES (
            'test-src-evt-5912-04', '   ', 'TEST_EVENT', 'TEST_OBJECT',
            'obj-5912-04', clock_timestamp()
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
        'finance.source_events accepted a blank source_system');

    /* source_events rows are immutable via the shared ledger-mutation guard. */
    v_failed := false;
    BEGIN
        UPDATE finance.source_events SET event_type = 'MUTATED' WHERE idempotency_key = 'test-src-evt-5912-01';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_prevent_ledger_mutation() allowed an UPDATE on finance.source_events');

    v_failed := false;
    BEGIN
        DELETE FROM finance.source_events WHERE idempotency_key = 'test-src-evt-5912-01';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed,
        'finance.trg_prevent_ledger_mutation() allowed a DELETE on finance.source_events');
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5912_test_finance_lifecycle.sql');
