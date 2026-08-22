/*
===============================================================================
 File:           1200_validation/1220_financial_readiness_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Mechanically enforce financial-ledger readiness invariants so
                 future schema/API changes cannot weaken provenance, precision,
                 idempotency, immutability, or currency safety.
 Depends On:     0760_finance/0761_financial_readiness_anchors.sql
                 1000_function/1014_finance_function.sql
                 1100_security/1107_grants.sql
                 1200_validation/1219_migration_framework_validation.sql
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1220_financial_readiness_validation.sql', ARRAY['0760_finance/0761_financial_readiness_anchors.sql', '1000_function/1014_finance_function.sql', '1100_security/1107_grants.sql', '1200_validation/1219_migration_framework_validation.sql']::text[]);

\echo '[VALIDATE] 1220_financial_readiness_validation.sql'

/* Shared type anchors. */
SELECT app.assert_true(
    to_regtype('app.currency_code') IS NOT NULL,
    'app.currency_code domain is missing'
);

SELECT app.assert_true(
    to_regtype('app.money_amount') IS NOT NULL,
    'app.money_amount domain is missing'
);

SELECT app.assert_true(
    to_regtype('app.idempotency_key') IS NOT NULL,
    'app.idempotency_key domain is missing'
);

SELECT app.assert_true(
    (
        SELECT format_type(t.typbasetype, t.typtypmod)
          FROM pg_type t
          JOIN pg_namespace n ON n.oid = t.typnamespace
         WHERE n.nspname = 'app'
           AND t.typname = 'money_amount'
    ) = 'numeric(18,4)',
    'app.money_amount must remain numeric(18,4)'
);

/* Financial source-event provenance anchors. */
SELECT app.assert_table_exists('finance','source_events');

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema='finance'
           AND table_name='source_events'
           AND column_name='idempotency_key'
           AND domain_schema='app'
           AND domain_name='idempotency_key'
    ),
    'finance.source_events.idempotency_key must use app.idempotency_key'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema='finance'
           AND table_name='source_events'
           AND column_name='payload_sha256'
           AND domain_schema='app'
           AND domain_name='sha256_digest'
    ),
    'finance.source_events.payload_sha256 must use app.sha256_digest'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_trigger
         WHERE tgrelid='finance.source_events'::regclass
           AND tgname='trg_finance_source_event_payload_hash'
           AND NOT tgisinternal
    ),
    'finance.source_events payload hashing trigger is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_trigger
         WHERE tgrelid='finance.source_events'::regclass
           AND tgname='trg_finance_source_events_immutable'
           AND NOT tgisinternal
    ),
    'finance.source_events must remain append-only'
);

/* Posting idempotency must bind a key to one exact request payload. */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema='finance'
           AND table_name='transactions'
           AND column_name='idempotency_key'
           AND domain_schema='app'
           AND domain_name='idempotency_key'
    ),
    'finance.transactions.idempotency_key must use app.idempotency_key'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema='finance'
           AND table_name='transactions'
           AND column_name='request_hash'
           AND is_nullable='NO'
           AND domain_schema='app'
           AND domain_name='sha256_digest'
    ),
    'finance.transactions.request_hash must be required app.sha256_digest'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conrelid='finance.transactions'::regclass
           AND contype='f'
           AND conname='fk_finance_transaction_source_event'
    ),
    'finance.transactions source-event provenance FK is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_constraint
         WHERE conrelid='finance.transactions'::regclass
           AND contype='u'
           AND conname='uq_finance_transaction_source_event'
    ),
    'A source event must not post more than one financial transaction'
);

DO $$
DECLARE
    v_def text;
BEGIN
    SELECT pg_get_functiondef(
        'admin.post_financial_transaction(text,app.currency_code,text,jsonb,uuid)'::regprocedure
    )
      INTO v_def;

    PERFORM app.assert_true(
        v_def ILIKE '%request_hash%'
        AND v_def ILIKE '%public.digest%'
        AND v_def ILIKE '%different financial request%',
        'admin.post_financial_transaction must fingerprint requests and reject idempotency-key payload drift'
    );
END;
$$;

/* Double-entry and currency invariants must live in PostgreSQL, not only API code. */
SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_trigger
         WHERE tgrelid='finance.ledger_entries'::regclass
           AND tgname='trg_finance_transaction_balance_on_ledger'
           AND NOT tgisinternal
    ),
    'Deferred ledger balance validation trigger is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_trigger
         WHERE tgrelid='finance.ledger_entries'::regclass
           AND tgname='trg_finance_ledger_currency'
           AND NOT tgisinternal
    ),
    'Ledger transaction/account currency consistency trigger is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_trigger
         WHERE tgrelid='finance.transactions'::regclass
           AND tgname='trg_finance_transactions_immutable'
           AND NOT tgisinternal
    )
    AND EXISTS (
        SELECT 1 FROM pg_trigger
         WHERE tgrelid='finance.ledger_entries'::regclass
           AND tgname='trg_finance_ledger_entries_immutable'
           AND NOT tgisinternal
    ),
    'Posted financial transactions and ledger entries must remain immutable'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_trigger
         WHERE tgrelid='finance.accounts'::regclass
           AND tgname='trg_finance_posted_account_identity'
           AND NOT tgisinternal
    ),
    'Posted account identity/currency protection trigger is missing'
);

/* No approximate or PostgreSQL money types in financially relevant schemas. */
DO $$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(format('%I.%I.%I (%s)', table_schema, table_name, column_name, data_type), ', ')
      INTO v_bad
      FROM information_schema.columns
     WHERE table_schema IN ('finance','marketplace','collection')
       AND (
            table_schema IN ('finance','marketplace')
            OR table_name IN ('acquisitions','acquisition_items')
       )
       AND data_type IN ('real','double precision','money');

    PERFORM app.assert_true(
        v_bad IS NULL,
        format('Approximate/native money types are forbidden for financial data: %s', COALESCE(v_bad,''))
    );
END;
$$;

/* Runtime remains stored-procedure-only and cannot mutate ledger/source anchors directly. */
DO $$
DECLARE
    v_role text;
    v_rel text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['lego_api','lego_app']
    LOOP
        FOREACH v_rel IN ARRAY ARRAY[
            'finance.accounts',
            'finance.transactions',
            'finance.ledger_entries',
            'finance.source_events'
        ]
        LOOP
            PERFORM app.assert_true(
                NOT has_table_privilege(v_role, v_rel, 'SELECT')
                AND NOT has_table_privilege(v_role, v_rel, 'INSERT')
                AND NOT has_table_privilege(v_role, v_rel, 'UPDATE')
                AND NOT has_table_privilege(v_role, v_rel, 'DELETE'),
                format('%s must not have direct privileges on %s', v_role, v_rel)
            );
        END LOOP;
    END LOOP;
END;
$$;

/* Behavioral source-event test: hash is generated and rows are immutable. */
DO $$
DECLARE
    v_event_id uuid := app.uuid_v7();
    v_expected app.sha256_digest;
    v_actual app.sha256_digest;
    v_blocked boolean := false;
BEGIN
    BEGIN
        INSERT INTO finance.source_events(
            financial_source_event_id,
            idempotency_key,
            source_system,
            event_type,
            source_object_type,
            source_object_key,
            currency,
            amount,
            occurred_at,
            payload,
            payload_sha256
        )
        VALUES (
            v_event_id,
            'bt-finance-readiness-test',
            'schema-validation',
            'TEST_EVENT',
            'validation',
            v_event_id::text,
            'USD',
            1.0000,
            clock_timestamp(),
            '{"purpose":"financial-readiness"}'::jsonb,
            decode(repeat('00',32),'hex')
        );

        v_expected := public.digest(
            pg_catalog.convert_to('{"purpose": "financial-readiness"}'::jsonb::text, 'UTF8'),
            'sha256'
        );

        SELECT payload_sha256
          INTO v_actual
          FROM finance.source_events
         WHERE financial_source_event_id=v_event_id;

        PERFORM app.assert_true(
            v_actual = v_expected,
            'Source-event payload hash was not generated canonically'
        );

        BEGIN
            UPDATE finance.source_events
               SET event_type='MUTATED'
             WHERE financial_source_event_id=v_event_id;
        EXCEPTION
            WHEN SQLSTATE '55000' THEN
                v_blocked := true;
        END;

        PERFORM app.assert_true(
            v_blocked,
            'Source-event UPDATE must be blocked after insertion'
        );

        RAISE SQLSTATE 'BT007' USING MESSAGE='rollback financial readiness fixture';
    EXCEPTION
        WHEN SQLSTATE 'BT007' THEN
            NULL;
    END;
END;
$$;

\echo '[PASS] 1220_financial_readiness_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1220_financial_readiness_validation.sql');
