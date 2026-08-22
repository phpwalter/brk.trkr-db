/*
===============================================================================
 File:           0000_bootstrap/0002_types.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define scalar domains shared across multiple application areas.
 Depends On:     app schema
 Creates:        app.currency_code
                 app.quantity
                 app.whole_quantity
                 app.nonnegative_quantity
                 app.money_amount
                 app.idempotency_key
                 app.sha256_digest
 Key Rules:      Money values use NUMERIC rather than floating-point types.
                 Piece quantities use integral values where appropriate.
                 Currency values use uppercase three-letter codes.
                 SHA-256 digests are stored as raw 32-byte values.
                 This file must not create or recreate the app schema.
 Validation:     Verifies every expected shared domain resolves successfully
                 after creation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0000_bootstrap/0002_types.sql', ARRAY['app schema']::text[]);



\echo '[0002] Creating shared scalar domains...'


/* -------------------------------------------------------------------------- */
/* Currency                                                                   */
/* -------------------------------------------------------------------------- */

CREATE DOMAIN app.currency_code AS text
    CONSTRAINT ck_currency_code_format
    CHECK (
        VALUE ~ '^[A-Z]{3}$'
    );

COMMENT ON DOMAIN app.currency_code IS
    'Uppercase three-letter currency code, normally ISO 4217.';


/* -------------------------------------------------------------------------- */
/* Quantities                                                                 */
/* -------------------------------------------------------------------------- */

CREATE DOMAIN app.quantity AS numeric(18,4)
    CONSTRAINT ck_quantity_positive
    CHECK (
        VALUE > 0
    );

COMMENT ON DOMAIN app.quantity IS
    'Strictly positive quantity supporting fractional quantities where required.';


CREATE DOMAIN app.whole_quantity AS bigint
    CONSTRAINT ck_whole_quantity_positive
    CHECK (
        VALUE > 0
    );

COMMENT ON DOMAIN app.whole_quantity IS
    'Strictly positive integral quantity for physical item and piece counts.';


CREATE DOMAIN app.nonnegative_quantity AS numeric(18,4)
    CONSTRAINT ck_nonnegative_quantity
    CHECK (
        VALUE >= 0
    );

COMMENT ON DOMAIN app.nonnegative_quantity IS
    'Quantity greater than or equal to zero.';


/* -------------------------------------------------------------------------- */
/* Money                                                                      */
/* -------------------------------------------------------------------------- */

CREATE DOMAIN app.money_amount AS numeric(18,4)
    CONSTRAINT ck_money_amount_nonnegative
    CHECK (
        VALUE >= 0
    );

COMMENT ON DOMAIN app.money_amount IS
    'Non-negative monetary amount. Currency is stored independently.';


/* -------------------------------------------------------------------------- */
/* Idempotency                                                                */
/* -------------------------------------------------------------------------- */

CREATE DOMAIN app.idempotency_key AS text
    CONSTRAINT ck_idempotency_key_format
    CHECK (
        VALUE = btrim(VALUE)
        AND char_length(VALUE) BETWEEN 8 AND 200
    );

COMMENT ON DOMAIN app.idempotency_key IS
    'Stable client/request idempotency key. Keys are trimmed and 8-200 characters.';


/* -------------------------------------------------------------------------- */
/* Cryptographic digests                                                      */
/* -------------------------------------------------------------------------- */

CREATE DOMAIN app.sha256_digest AS bytea
    CONSTRAINT ck_sha256_digest_length
    CHECK (
        octet_length(VALUE) = 32
    );

COMMENT ON DOMAIN app.sha256_digest IS
    'Raw 32-byte SHA-256 cryptographic digest.';


/* -------------------------------------------------------------------------- */
/* File-local validation                                                      */
/* -------------------------------------------------------------------------- */

DO $$
DECLARE
    v_type text;
BEGIN
    FOREACH v_type IN ARRAY ARRAY[
        'app.currency_code',
        'app.quantity',
        'app.whole_quantity',
        'app.nonnegative_quantity',
        'app.money_amount',
        'app.idempotency_key',
        'app.sha256_digest'
    ]
    LOOP
        IF to_regtype(v_type) IS NULL THEN
            RAISE EXCEPTION
                'Required shared domain "%" was not created',
                v_type;
        END IF;
    END LOOP;
END;
$$;


\echo '[PASS] 0002_types.sql'
SELECT pg_temp.bt_mark_completed('0000_bootstrap/0002_types.sql');
