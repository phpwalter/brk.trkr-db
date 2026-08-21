/*
===============================================================================
 File:           0000_bootstrap/0000_extensions.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Install PostgreSQL extensions required by the schema.
 Depends On:     PostgreSQL extension installation privileges
 Creates:        pgcrypto
                 citext
                 pg_trgm
 Key Rules:      Required extensions must exist before schema construction
                 continues.
                 Extension installation failure aborts bootstrap.
 Validation:     Verifies pgcrypto, citext and pg_trgm are registered in pg_extension.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0000_bootstrap/0000_extensions.sql', ARRAY['PostgreSQL extension installation privileges']::text[]);



CREATE EXTENSION pgcrypto;
CREATE EXTENSION citext;
CREATE EXTENSION pg_trgm;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'pgcrypto'
    ) THEN
        RAISE EXCEPTION 'Required extension "pgcrypto" is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'citext'
    ) THEN
        RAISE EXCEPTION 'Required extension "citext" is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'pg_trgm'
    ) THEN
        RAISE EXCEPTION 'Required extension "pg_trgm" is missing';
    END IF;
END;
$$;

\echo '[PASS] 0000_extensions.sql'
SELECT pg_temp.bt_mark_completed('0000_bootstrap/0000_extensions.sql');
