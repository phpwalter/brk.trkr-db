/*
===============================================================================
 File:           0760_finance/0761_financial_readiness_anchors.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Preserve source provenance and invariant anchors required for
                 safe future financial-ledger expansion.
 Depends On:     0760_finance/0760_financial_ledger.sql
                 pgcrypto
                 app.idempotency_key
                 app.sha256_digest
 Creates:        finance.source_events
                 finance.trg_hash_source_event_payload()
 Key Rules:      Source events are durable business-fact anchors.
                 Idempotency is explicit and payloads are fingerprinted.
                 A financial transaction may reference at most one source event.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0760_finance/0761_financial_readiness_anchors.sql', ARRAY['0760_finance/0760_financial_ledger.sql', 'pgcrypto', 'app.idempotency_key', 'app.sha256_digest']::text[]);


CREATE TABLE finance.source_events (
    financial_source_event_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    idempotency_key app.idempotency_key NOT NULL UNIQUE,
    source_system text NOT NULL,
    event_type text NOT NULL,
    source_object_type text NOT NULL,
    source_object_key text NOT NULL,
    currency app.currency_code,
    amount app.money_amount,
    occurred_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    payload_sha256 app.sha256_digest NOT NULL,

    CONSTRAINT ck_finance_source_system_nonblank
        CHECK (btrim(source_system) <> ''),
    CONSTRAINT ck_finance_source_event_type_nonblank
        CHECK (btrim(event_type) <> ''),
    CONSTRAINT ck_finance_source_object_type_nonblank
        CHECK (btrim(source_object_type) <> ''),
    CONSTRAINT ck_finance_source_object_key_nonblank
        CHECK (btrim(source_object_key) <> ''),
    CONSTRAINT ck_finance_source_amount_currency
        CHECK (amount IS NULL OR currency IS NOT NULL)
);

CREATE INDEX ix_finance_source_events_object
    ON finance.source_events(source_system, source_object_type, source_object_key, occurred_at DESC);

CREATE OR REPLACE FUNCTION finance.trg_hash_source_event_payload()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
    NEW.payload_sha256 :=
        public.digest(
            pg_catalog.convert_to(NEW.payload::text, 'UTF8'),
            'sha256'
        );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_finance_source_event_payload_hash
BEFORE INSERT ON finance.source_events
FOR EACH ROW
EXECUTE FUNCTION finance.trg_hash_source_event_payload();

ALTER TABLE finance.transactions
    ADD CONSTRAINT fk_finance_transaction_source_event
        FOREIGN KEY (financial_source_event_id)
        REFERENCES finance.source_events(financial_source_event_id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT uq_finance_transaction_source_event
        UNIQUE (financial_source_event_id);

COMMENT ON TABLE finance.source_events IS
    'Immutable source business events retained as provenance anchors for current and future ledger posting.';

COMMENT ON COLUMN finance.transactions.request_hash IS
    'SHA-256 fingerprint of the canonical posting request used to detect idempotency-key reuse with different payloads.';

COMMENT ON COLUMN finance.transactions.financial_source_event_id IS
    'Optional durable provenance link to the source business event that caused this posting.';

SELECT pg_temp.bt_mark_completed('0760_finance/0761_financial_readiness_anchors.sql');
