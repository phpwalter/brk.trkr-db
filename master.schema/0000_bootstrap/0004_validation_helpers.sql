/*
===============================================================================
 File:           0000_bootstrap/0004_validation_helpers.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Provide reusable fail-fast deployment validation functions.
 Depends On:     app schema
 Creates:        app.assert_true()
                 app.assert_schema_exists()
                 app.assert_table_exists()
                 app.assert_column_exists()
                 app.assert_constraint_exists()
                 app.assert_index_exists()
                 app.assert_function_exists()
                 app.assert_no_rows()
 Key Rules:      Deployment validation must fail immediately when an invariant
                 is violated.
                 Validation helpers are intended for trusted schema scripts.
 Validation:     Verifies all required validation helper signatures exist.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0000_bootstrap/0004_validation_helpers.sql', ARRAY['app schema']::text[]);



CREATE FUNCTION app.assert_true(
    p_condition boolean,
    p_message text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Schema validation failed: %', p_message;
    END IF;
END;
$$;

CREATE FUNCTION app.assert_schema_exists(
    p_schema text
)
RETURNS void
LANGUAGE sql
AS $$
    SELECT app.assert_true(
        EXISTS (
            SELECT 1
            FROM pg_namespace
            WHERE nspname = p_schema
        ),
        format('Required schema "%s" does not exist', p_schema)
    );
$$;

CREATE FUNCTION app.assert_table_exists(
    p_schema text,
    p_table text
)
RETURNS void
LANGUAGE sql
AS $$
    SELECT app.assert_true(
        to_regclass(format('%I.%I', p_schema, p_table)) IS NOT NULL,
        format(
            'Required table "%s.%s" does not exist',
            p_schema,
            p_table
        )
    );
$$;

CREATE FUNCTION app.assert_column_exists(
    p_schema text,
    p_table text,
    p_column text
)
RETURNS void
LANGUAGE sql
AS $$
    SELECT app.assert_true(
        EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = p_schema
              AND table_name = p_table
              AND column_name = p_column
        ),
        format(
            'Required column "%s.%s.%s" does not exist',
            p_schema,
            p_table,
            p_column
        )
    );
$$;

CREATE FUNCTION app.assert_constraint_exists(
    p_schema text,
    p_table text,
    p_constraint text
)
RETURNS void
LANGUAGE sql
AS $$
    SELECT app.assert_true(
        EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class r
              ON r.oid = c.conrelid
            JOIN pg_namespace n
              ON n.oid = r.relnamespace
            WHERE n.nspname = p_schema
              AND r.relname = p_table
              AND c.conname = p_constraint
        ),
        format(
            'Constraint "%s" is missing from "%s.%s"',
            p_constraint,
            p_schema,
            p_table
        )
    );
$$;

CREATE FUNCTION app.assert_index_exists(
    p_schema text,
    p_index text
)
RETURNS void
LANGUAGE sql
AS $$
    SELECT app.assert_true(
        EXISTS (
            SELECT 1
            FROM pg_indexes
            WHERE schemaname = p_schema
              AND indexname = p_index
        ),
        format(
            'Required index "%s.%s" does not exist',
            p_schema,
            p_index
        )
    );
$$;

CREATE FUNCTION app.assert_function_exists(
    p_signature text
)
RETURNS void
LANGUAGE sql
AS $$
    SELECT app.assert_true(
        to_regprocedure(p_signature) IS NOT NULL,
        format(
            'Required function "%s" does not exist',
            p_signature
        )
    );
$$;

CREATE FUNCTION app.assert_no_rows(
    p_query text,
    p_message text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists boolean;
BEGIN
    EXECUTE format(
        'SELECT EXISTS (%s)',
        p_query
    )
    INTO v_exists;

    IF v_exists THEN
        RAISE EXCEPTION
            'Schema validation failed: %',
            p_message;
    END IF;
END;
$$;

SELECT app.assert_function_exists('app.assert_true(boolean,text)');
SELECT app.assert_function_exists('app.assert_schema_exists(text)');
SELECT app.assert_function_exists('app.assert_table_exists(text,text)');
SELECT app.assert_function_exists('app.assert_column_exists(text,text,text)');
SELECT app.assert_function_exists('app.assert_constraint_exists(text,text,text)');
SELECT app.assert_function_exists('app.assert_index_exists(text,text)');
SELECT app.assert_function_exists('app.assert_function_exists(text)');
SELECT app.assert_function_exists('app.assert_no_rows(text,text)');

\echo '[PASS] 0004_validation_helpers.sql'
SELECT pg_temp.bt_mark_completed('0000_bootstrap/0004_validation_helpers.sql');
