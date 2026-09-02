/*
===============================================================================
 File:           5000_function/5100_admin/5131_admin_finance_actor.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.1
 PostgreSQL:     16+
 Purpose:        Add an administrator financial-posting overload that accepts
                 an explicitly authenticated BrickTrackr actor without placing
                 a USER identity inside ADMIN transaction context.
 Depends On:     5000_function/5100_admin/5130_admin_finance.sql
                 identity.users
                 finance.accounts
                 finance.transactions
                 finance.ledger_entries
                 pgcrypto
 Creates:        admin.post_financial_transaction(...,uuid,uuid)
 Key Rules:      ADMIN database context remains actor_class=ADMIN with no
                 app.current_user_id. The HTTP-authenticated BrickTrackr admin
                 user is passed explicitly for durable financial attribution.
                 Idempotency, balancing, currency, and append-only guarantees
                 are identical to the existing posting routine. Object ownership
                 is assigned later by the canonical 1111 ownership-separation
                 stage, consistent with other pre-role function files.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5100_admin/5131_admin_finance_actor.sql',
    ARRAY[
        '5000_function/5100_admin/5130_admin_finance.sql',
        'identity.users',
        'finance.accounts',
        'finance.transactions',
        'finance.ledger_entries',
        'pgcrypto'
    ]::text[]
);

CREATE OR REPLACE FUNCTION admin.post_financial_transaction(
    p_idempotency_key text,
    p_currency app.currency_code,
    p_description text,
    p_entries jsonb,
    p_order_id uuid,
    p_posted_by_user_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, finance, identity
AS $$
DECLARE
    v_transaction_id uuid;
    v_debits numeric(18,4);
    v_credits numeric(18,4);
    v_bad_accounts bigint;
    v_request_hash app.sha256_digest;
    v_existing_hash app.sha256_digest;
BEGIN
    IF p_posted_by_user_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM identity.users u
        WHERE u.user_id = p_posted_by_user_id
          AND u.account_status <> 'ARCHIVED'
    ) THEN
        RAISE EXCEPTION 'A valid BrickTrackr administrator actor is required'
            USING ERRCODE='42501';
    END IF;

    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
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
        idempotency_key,
        request_hash,
        order_id,
        description,
        currency,
        posted_by_user_id
    )
    VALUES (
        p_idempotency_key::app.idempotency_key,
        v_request_hash,
        p_order_id,
        p_description,
        p_currency,
        p_posted_by_user_id
    )
    RETURNING financial_transaction_id INTO v_transaction_id;

    INSERT INTO finance.ledger_entries(
        financial_transaction_id,
        financial_account_id,
        debit_amount,
        credit_amount
    )
    SELECT
        v_transaction_id,
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

REVOKE ALL ON FUNCTION admin.post_financial_transaction(
    text,
    app.currency_code,
    text,
    jsonb,
    uuid,
    uuid
) FROM PUBLIC;

COMMENT ON FUNCTION admin.post_financial_transaction(
    text,
    app.currency_code,
    text,
    jsonb,
    uuid,
    uuid
) IS
'Posts one balanced idempotent financial transaction with an explicitly authenticated BrickTrackr administrator actor while preserving ADMIN database request-context separation. Ownership is normalized by 1111_role_ownership_separation.sql.';

SELECT pg_temp.bt_mark_completed('5000_function/5100_admin/5131_admin_finance_actor.sql');
\echo '[PASS] 5131_admin_finance_actor.sql v1.3.1'
