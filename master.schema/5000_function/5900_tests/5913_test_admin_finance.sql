/*
===============================================================================
 File:           5000_function/5900_tests/5913_test_admin_finance.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Stored-procedure contract tests for 5000_function/5100_admin/5130_admin_finance.sql.
 Depends On:     5000_function/5100_admin/5130_admin_finance.sql
 Creates:        Test assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5913_test_admin_finance.sql', ARRAY['5000_function/5100_admin/5130_admin_finance.sql']::text[]);

\echo '[TEST] 5913_test_admin_finance'

BEGIN;

DO $$
DECLARE
    v record;
    v_oid oid;
    v_kind "char";
BEGIN
    FOR v IN
        SELECT *
        FROM (VALUES
            ('admin.post_financial_transaction(text,app.currency_code,text,jsonb,uuid)', 'f'),
            ('finance.trg_validate_transaction_balance()', 'f'),
            ('finance.trg_validate_ledger_currency()', 'f'),
            ('finance.trg_protect_posted_account_identity()', 'f'),
            ('finance.trg_prevent_ledger_mutation()', 'f')
        ) AS x(signature, expected_kind)
    LOOP
        v_oid := to_regprocedure(v.signature);
        PERFORM app.assert_true(
            v_oid IS NOT NULL,
            format('Required routine %s is missing', v.signature)
        );

        SELECT p.prokind
          INTO v_kind
          FROM pg_proc p
         WHERE p.oid = v_oid;

        PERFORM app.assert_true(
            v_kind = v.expected_kind::"char",
            format(
                'Routine %s has prokind=%s; expected=%s',
                v.signature, v_kind, v.expected_kind
            )
        );
    END LOOP;
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5913_test_admin_finance.sql');
