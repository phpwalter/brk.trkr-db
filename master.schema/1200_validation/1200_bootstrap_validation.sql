/*
===============================================================================
 File:           1200_validation/1200_bootstrap_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate bootstrap infrastructure required by all application
                 domains.
 Depends On:     0000_bootstrap/0000_extensions.sql
                 0000_bootstrap/0001_schemas.sql
                 0000_bootstrap/0002_types.sql
                 0000_bootstrap/0003_uuid.sql
                 0000_bootstrap/0004_validation_helpers.sql
                 0000_bootstrap/0005_migration_framework.sql
 Creates:        No persistent database objects.
 Key Rules:      All required PostgreSQL extensions must be installed.
                 All application schemas must exist.
                 Shared domains and validation functions must be resolvable.
                 app.uuid_v7() must generate UUID version 7 values with the
                 RFC-compatible variant.
 Validation:     Fails deployment immediately if any bootstrap dependency,
                 shared domain, schema, extension, helper function, or UUIDv7
                 invariant is missing or invalid.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1200_bootstrap_validation.sql', ARRAY['0000_bootstrap/0000_extensions.sql', '0000_bootstrap/0001_schemas.sql', '0000_bootstrap/0002_types.sql', '0000_bootstrap/0003_uuid.sql', '0000_bootstrap/0004_validation_helpers.sql', '0000_bootstrap/0005_migration_framework.sql']::text[]);



\echo '[VALIDATE] 1200_bootstrap_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required extensions                                                        */
/* -------------------------------------------------------------------------- */

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'pgcrypto'
    ),
    'Required extension pgcrypto is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'citext'
    ),
    'Required extension citext is missing'
);


/* -------------------------------------------------------------------------- */
/* Required schemas                                                           */
/* -------------------------------------------------------------------------- */

SELECT app.assert_schema_exists('app');
SELECT app.assert_schema_exists('identity');
SELECT app.assert_schema_exists('reference');
SELECT app.assert_schema_exists('catalog');
SELECT app.assert_schema_exists('definition');
SELECT app.assert_schema_exists('collection');
SELECT app.assert_schema_exists('wanted');
SELECT app.assert_schema_exists('moc');
SELECT app.assert_schema_exists('import');
SELECT app.assert_schema_exists('audit');
SELECT app.assert_schema_exists('api');


/* -------------------------------------------------------------------------- */
/* Shared scalar domains                                                      */
/* -------------------------------------------------------------------------- */

SELECT app.assert_true(
    to_regtype('app.currency_code') IS NOT NULL,
    'Required domain app.currency_code is missing'
);

SELECT app.assert_true(
    to_regtype('app.quantity') IS NOT NULL,
    'Required domain app.quantity is missing'
);

SELECT app.assert_true(
    to_regtype('app.whole_quantity') IS NOT NULL,
    'Required domain app.whole_quantity is missing'
);

SELECT app.assert_true(
    to_regtype('app.nonnegative_quantity') IS NOT NULL,
    'Required domain app.nonnegative_quantity is missing'
);

SELECT app.assert_true(
    to_regtype('app.money_amount') IS NOT NULL,
    'Required domain app.money_amount is missing'
);

SELECT app.assert_true(
    to_regtype('app.sha256_digest') IS NOT NULL,
    'Required domain app.sha256_digest is missing'
);


/* -------------------------------------------------------------------------- */
/* Required bootstrap functions                                               */
/* -------------------------------------------------------------------------- */

SELECT app.assert_function_exists('app.uuid_v7()');
SELECT app.assert_function_exists('app.assert_true(boolean,text)');
SELECT app.assert_function_exists('app.assert_schema_exists(text)');
SELECT app.assert_function_exists('app.assert_table_exists(text,text)');
SELECT app.assert_function_exists('app.assert_column_exists(text,text,text)');
SELECT app.assert_function_exists(
    'app.assert_constraint_exists(text,text,text)'
);
SELECT app.assert_function_exists('app.assert_index_exists(text,text)');
SELECT app.assert_function_exists('app.assert_function_exists(text)');
SELECT app.assert_function_exists('app.assert_no_rows(text,text)');


/* -------------------------------------------------------------------------- */
/* UUIDv7 generator                                                           */
/* -------------------------------------------------------------------------- */

DO $$
DECLARE
    v_id uuid;
    v_text text;
BEGIN
    FOR i IN 1..100 LOOP
        v_id := app.uuid_v7();
        v_text := v_id::text;

        IF substr(v_text, 15, 1) <> '7' THEN
            RAISE EXCEPTION
                'app.uuid_v7() generated UUID "%" with invalid version',
                v_id;
        END IF;

        IF substr(v_text, 20, 1) NOT IN ('8', '9', 'a', 'b') THEN
            RAISE EXCEPTION
                'app.uuid_v7() generated UUID "%" with invalid RFC variant',
                v_id;
        END IF;
    END LOOP;
END;
$$;



SELECT app.assert_table_exists('app', 'schema_migration_baseline');
SELECT app.assert_table_exists('app', 'schema_migrations');

\echo '[VALIDATE PASS] 1200_bootstrap_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1200_bootstrap_validation.sql');
