/*
===============================================================================
 File:           5000_function/5100_admin/5130_admin_finance.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Post balanced, retry-safe double-entry financial transactions.
 Depends On:     finance.accounts
                 finance.transactions
                 finance.ledger_entries
                 finance.source_events
                 pgcrypto
 Creates:        admin.post_financial_transaction(...)
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5100_admin/5130_admin_finance.sql', ARRAY['finance.accounts', 'finance.transactions', 'finance.ledger_entries', 'finance.source_events', 'pgcrypto']::text[]);



CREATE OR REPLACE FUNCTION admin.post_financial_transaction(
    p_idempotency_key text,
    p_currency app.currency_code,
    p_description text,
    p_entries jsonb,
    p_order_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, identity
AS $$
DECLARE
    v_transaction_id uuid;
    v_user uuid := identity.current_user_id();
    v_debits numeric(18,4);
    v_credits numeric(18,4);
    v_bad_accounts bigint;
    v_request_hash app.sha256_digest;
    v_existing_hash app.sha256_digest;
BEGIN
    IF p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'p_idempotency_key is required'
            USING ERRCODE='22023';
    END IF;

    IF jsonb_typeof(p_entries) <> 'array' OR jsonb_array_length(p_entries) < 2 THEN
        RAISE EXCEPTION 'p_entries must be a JSON array with at least two ledger lines'
            USING ERRCODE='22023';
    END IF;

    v_request_hash :=
        public.digest(
            pg_catalog.convert_to(
                pg_catalog.jsonb_build_object(
                    'currency', p_currency::text,
                    'description', p_description,
                    'order_id', p_order_id,
                    'entries', p_entries
                )::text,
                'UTF8'
            ),
            'sha256'
        );

    SELECT financial_transaction_id, request_hash
      INTO v_transaction_id, v_existing_hash
      FROM finance.transactions
     WHERE idempotency_key = p_idempotency_key;

    IF FOUND THEN
        IF v_existing_hash IS DISTINCT FROM v_request_hash THEN
            RAISE EXCEPTION
                'Idempotency key "%" was already used with a different financial request',
                p_idempotency_key
                USING ERRCODE='23505';
        END IF;
        RETURN v_transaction_id;
    END IF;

    SELECT
        COALESCE(sum(COALESCE((e->>'debit')::numeric, 0)), 0),
        COALESCE(sum(COALESCE((e->>'credit')::numeric, 0)), 0)
    INTO v_debits, v_credits
    FROM jsonb_array_elements(p_entries) e;

    IF v_debits <= 0 OR v_debits <> v_credits THEN
        RAISE EXCEPTION 'Financial transaction is unbalanced: debits %, credits %',
            v_debits, v_credits USING ERRCODE='23514';
    END IF;

    SELECT count(*)
      INTO v_bad_accounts
      FROM jsonb_array_elements(p_entries) e
      LEFT JOIN finance.accounts a
        ON a.financial_account_id = (e->>'account_id')::uuid
       AND a.currency = p_currency
       AND a.is_active
     WHERE a.financial_account_id IS NULL;

    IF v_bad_accounts <> 0 THEN
        RAISE EXCEPTION 'One or more ledger accounts are missing, inactive, or use a different currency'
            USING ERRCODE='23503';
    END IF;

    INSERT INTO finance.transactions(
        idempotency_key, request_hash, order_id, description, currency, posted_by_user_id
    )
    VALUES (
        p_idempotency_key::app.idempotency_key,
        v_request_hash,
        p_order_id,
        p_description,
        p_currency,
        v_user
    )
    RETURNING financial_transaction_id INTO v_transaction_id;

    INSERT INTO finance.ledger_entries(
        financial_transaction_id, financial_account_id, debit_amount, credit_amount
    )
    SELECT v_transaction_id,
           (e->>'account_id')::uuid,
           COALESCE((e->>'debit')::numeric, 0),
           COALESCE((e->>'credit')::numeric, 0)
      FROM jsonb_array_elements(p_entries) e;

    RETURN v_transaction_id;
EXCEPTION
    WHEN unique_violation THEN
        SELECT financial_transaction_id, request_hash
          INTO v_transaction_id, v_existing_hash
          FROM finance.transactions
         WHERE idempotency_key = p_idempotency_key;

        IF v_transaction_id IS NOT NULL THEN
            IF v_existing_hash IS DISTINCT FROM v_request_hash THEN
                RAISE EXCEPTION
                    'Idempotency key "%" was concurrently used with a different financial request',
                    p_idempotency_key
                    USING ERRCODE='23505';
            END IF;
            RETURN v_transaction_id;
        END IF;
        RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION finance.trg_validate_transaction_balance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, finance
AS $$
DECLARE
    v_transaction_id uuid := COALESCE(NEW.financial_transaction_id, OLD.financial_transaction_id);
    v_debits numeric(18,4);
    v_credits numeric(18,4);
BEGIN
    SELECT COALESCE(sum(debit_amount),0), COALESCE(sum(credit_amount),0)
      INTO v_debits, v_credits
      FROM finance.ledger_entries
     WHERE financial_transaction_id = v_transaction_id;

    IF v_debits <= 0 OR v_debits <> v_credits THEN
        RAISE EXCEPTION 'Financial transaction % is unbalanced: debits %, credits %',
            v_transaction_id, v_debits, v_credits USING ERRCODE='23514';
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE CONSTRAINT TRIGGER trg_finance_transaction_balance_on_transaction
AFTER INSERT ON finance.transactions
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION finance.trg_validate_transaction_balance();

CREATE CONSTRAINT TRIGGER trg_finance_transaction_balance_on_ledger
AFTER INSERT ON finance.ledger_entries
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION finance.trg_validate_transaction_balance();

CREATE OR REPLACE FUNCTION finance.trg_validate_ledger_currency()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, finance
AS $$
DECLARE
    v_transaction_currency app.currency_code;
    v_account_currency app.currency_code;
BEGIN
    SELECT currency
      INTO v_transaction_currency
      FROM finance.transactions
     WHERE financial_transaction_id = NEW.financial_transaction_id;

    SELECT currency
      INTO v_account_currency
      FROM finance.accounts
     WHERE financial_account_id = NEW.financial_account_id;

    IF v_transaction_currency IS NULL OR v_account_currency IS NULL THEN
        RAISE EXCEPTION 'Ledger currency validation could not resolve transaction/account'
            USING ERRCODE='23503';
    END IF;

    IF v_transaction_currency <> v_account_currency THEN
        RAISE EXCEPTION
            'Ledger currency mismatch: transaction %, account %',
            v_transaction_currency, v_account_currency
            USING ERRCODE='23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_finance_ledger_currency
BEFORE INSERT ON finance.ledger_entries
FOR EACH ROW EXECUTE FUNCTION finance.trg_validate_ledger_currency();


CREATE OR REPLACE FUNCTION finance.trg_protect_posted_account_identity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, finance
AS $$
BEGIN
    IF (
        NEW.account_code IS DISTINCT FROM OLD.account_code
        OR NEW.account_kind IS DISTINCT FROM OLD.account_kind
        OR NEW.owner_id IS DISTINCT FROM OLD.owner_id
        OR NEW.currency IS DISTINCT FROM OLD.currency
    )
    AND EXISTS (
        SELECT 1
          FROM finance.ledger_entries le
         WHERE le.financial_account_id = OLD.financial_account_id
    )
    THEN
        RAISE EXCEPTION
            'Posted financial account identity fields are immutable'
            USING ERRCODE='55000';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_finance_posted_account_identity
BEFORE UPDATE OF account_code, account_kind, owner_id, currency
ON finance.accounts
FOR EACH ROW EXECUTE FUNCTION finance.trg_protect_posted_account_identity();


CREATE OR REPLACE FUNCTION finance.trg_prevent_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Posted financial ledger rows are immutable' USING ERRCODE='55000';
END;
$$;

CREATE TRIGGER trg_finance_transactions_immutable
BEFORE UPDATE OR DELETE ON finance.transactions
FOR EACH ROW EXECUTE FUNCTION finance.trg_prevent_ledger_mutation();

CREATE TRIGGER trg_finance_ledger_entries_immutable
BEFORE UPDATE OR DELETE ON finance.ledger_entries
FOR EACH ROW EXECUTE FUNCTION finance.trg_prevent_ledger_mutation();

CREATE TRIGGER trg_finance_source_events_immutable
BEFORE UPDATE OR DELETE ON finance.source_events
FOR EACH ROW EXECUTE FUNCTION finance.trg_prevent_ledger_mutation();
SELECT pg_temp.bt_mark_completed('5000_function/5100_admin/5130_admin_finance.sql');
