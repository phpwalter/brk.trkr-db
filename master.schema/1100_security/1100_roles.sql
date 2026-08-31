/*
===============================================================================
 File:           1100_security/1100_roles.sql
 Project:        BrickTrackr
 Schema Version: 1.2.0
 PostgreSQL:     16+
 Purpose:        Reconcile the canonical BrickTrackr database capability roles.
 Depends On:     PostgreSQL role-creation privileges
 Creates:        brktrkr_owner
                 brktrkr_api
                 brktrkr_import
                 brktrkr_admin
                 brktrkr_reporting
                 brktrkr_migrator
 Key Rules:      All six capability roles are NOLOGIN.
                 Runtime/admin/import/reporting roles are NOBYPASSRLS.
                 brktrkr_owner owns application objects.
                 brktrkr_migrator is the only deployment capability role
                 intended to assume brktrkr_owner.
                 Human/service LOGIN roles are created separately and are
                 granted membership in one of these capability roles.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1100_roles.sql', ARRAY['PostgreSQL role-creation privileges']::text[]);

\echo '[SECURITY] Reconciling canonical BrickTrackr capability roles...'

DO $role_setup$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'brktrkr_owner') THEN
        CREATE ROLE brktrkr_owner
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE brktrkr_owner WITH
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'brktrkr_api') THEN
        CREATE ROLE brktrkr_api
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            INHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE brktrkr_api WITH
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            INHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'brktrkr_import') THEN
        CREATE ROLE brktrkr_import
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            INHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE brktrkr_import WITH
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            INHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'brktrkr_admin') THEN
        CREATE ROLE brktrkr_admin
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            INHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE brktrkr_admin WITH
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            INHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'brktrkr_reporting') THEN
        CREATE ROLE brktrkr_reporting
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            INHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE brktrkr_reporting WITH
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            INHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'brktrkr_migrator') THEN
        CREATE ROLE brktrkr_migrator
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE brktrkr_migrator WITH
            NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;
END
$role_setup$;

DO $validate_roles$
DECLARE
    v_role text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[
        'brktrkr_owner',
        'brktrkr_api',
        'brktrkr_import',
        'brktrkr_admin',
        'brktrkr_reporting',
        'brktrkr_migrator'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_roles
            WHERE rolname = v_role
              AND NOT rolcanlogin
              AND NOT rolsuper
              AND NOT rolcreatedb
              AND NOT rolcreaterole
              AND NOT rolreplication
              AND NOT rolbypassrls
        ) THEN
            RAISE EXCEPTION
                'Role % is missing or violates the canonical NOLOGIN/NOBYPASSRLS capability-role contract.',
                v_role;
        END IF;
    END LOOP;

    IF (SELECT rolinherit FROM pg_catalog.pg_roles WHERE rolname = 'brktrkr_owner') THEN
        RAISE EXCEPTION 'brktrkr_owner must be NOINHERIT.';
    END IF;

    IF (SELECT rolinherit FROM pg_catalog.pg_roles WHERE rolname = 'brktrkr_migrator') THEN
        RAISE EXCEPTION 'brktrkr_migrator must be NOINHERIT.';
    END IF;
END
$validate_roles$;

COMMENT ON ROLE brktrkr_owner IS
    'NOLOGIN owner of BrickTrackr schemas and objects. Never a normal runtime login.';
COMMENT ON ROLE brktrkr_api IS
    'NOLOGIN execute-only capability role for the BrickTrackr application API.';
COMMENT ON ROLE brktrkr_import IS
    'NOLOGIN capability role for authoritative import-service logins.';
COMMENT ON ROLE brktrkr_admin IS
    'NOLOGIN execute-only capability role for reviewed admin.* procedures.';
COMMENT ON ROLE brktrkr_reporting IS
    'NOLOGIN read-only capability role for reporting.* relations.';
COMMENT ON ROLE brktrkr_migrator IS
    'NOLOGIN deployment capability role permitted to assume brktrkr_owner for migrations.';

\echo '[PASS] 1100_roles.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1100_roles.sql');
