/*
===============================================================================
 File:           0760_finance/0760_financial_ledger.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Provide an idempotent double-entry financial journal.
 Depends On:     identity.owners
                 identity.users
                 marketplace.orders
                 app.money_amount
                 app.idempotency_key
                 app.sha256_digest
 Creates:        finance.account_kind
                 finance.accounts
                 finance.transactions
                 finance.ledger_entries
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0760_finance/0760_financial_ledger.sql', ARRAY['identity.owners', 'identity.users', 'marketplace.orders', 'app.money_amount', 'app.idempotency_key', 'app.sha256_digest']::text[]);



CREATE TYPE finance.account_kind AS ENUM ('ASSET','LIABILITY','EQUITY','REVENUE','EXPENSE','CLEARING');

CREATE TABLE finance.accounts (
    financial_account_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    account_code text NOT NULL UNIQUE,
    account_name text NOT NULL,
    account_kind finance.account_kind NOT NULL,
    owner_id uuid REFERENCES identity.owners(owner_id) ON DELETE RESTRICT,
    currency app.currency_code NOT NULL,
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_finance_account_code CHECK (btrim(account_code) <> ''),
    CONSTRAINT ck_finance_account_name CHECK (btrim(account_name) <> '')
);

CREATE TABLE finance.transactions (
    financial_transaction_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    idempotency_key app.idempotency_key NOT NULL UNIQUE,
    request_hash app.sha256_digest NOT NULL,
    financial_source_event_id uuid,
    order_id uuid REFERENCES marketplace.orders(order_id) ON DELETE RESTRICT,
    description text NOT NULL,
    currency app.currency_code NOT NULL,
    posted_by_user_id uuid REFERENCES identity.users(user_id) ON DELETE RESTRICT,
    posted_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_finance_transaction_key CHECK (btrim(idempotency_key) <> ''),
    CONSTRAINT ck_finance_transaction_description CHECK (btrim(description) <> '')
);

CREATE TABLE finance.ledger_entries (
    financial_ledger_entry_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    financial_transaction_id uuid NOT NULL
        REFERENCES finance.transactions(financial_transaction_id) ON DELETE RESTRICT,
    financial_account_id uuid NOT NULL
        REFERENCES finance.accounts(financial_account_id) ON DELETE RESTRICT,
    debit_amount app.money_amount NOT NULL DEFAULT 0,
    credit_amount app.money_amount NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_finance_ledger_one_side CHECK (
        (debit_amount > 0 AND credit_amount = 0)
        OR (credit_amount > 0 AND debit_amount = 0)
    )
);
CREATE INDEX ix_finance_ledger_transaction ON finance.ledger_entries(financial_transaction_id);
CREATE INDEX ix_finance_ledger_account ON finance.ledger_entries(financial_account_id, created_at DESC);
SELECT pg_temp.bt_mark_completed('0760_finance/0760_financial_ledger.sql');
