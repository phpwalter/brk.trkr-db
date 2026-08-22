/*
===============================================================================
 File:           1100_security/1100_roles.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Ensure database group roles for application, administration and
                 authoritative import execution exist with the required attributes.
 Depends On:     PostgreSQL role-creation privileges
 Creates:        lego_app
                 lego_admin
                 lego_importer
                 lego_api
                 lego_reporting
                 lego_owner
                 lego_deployer
 Key Rules:      Application users connect through a NOLOGIN group role.
                 Administrator/import execution roles may bypass RLS where
                 explicitly required.
                 End-user authentication identities remain application users,
                 not one PostgreSQL login per person.
 Validation:     Verifies all required database roles exist after reconciliation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1100_roles.sql', ARRAY['PostgreSQL role-creation privileges']::text[]);



DO $role_setup$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_app') THEN
        CREATE ROLE lego_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE lego_app WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_admin') THEN
        CREATE ROLE lego_admin NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS;
    ELSE
        ALTER ROLE lego_admin WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_importer') THEN
        CREATE ROLE lego_importer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS;
    ELSE
        ALTER ROLE lego_importer WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION BYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_api') THEN
        CREATE ROLE lego_api NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE lego_api WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_reporting') THEN
        CREATE ROLE lego_reporting NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE lego_reporting WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_owner') THEN
        CREATE ROLE lego_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE lego_owner WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_deployer') THEN
        CREATE ROLE lego_deployer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    ELSE
        ALTER ROLE lego_deployer WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;
END
$role_setup$;

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'lego_app'
    ),
    'lego_app role is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'lego_admin'
    ),
    'lego_admin role is missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'lego_importer'
    ),
    'lego_importer role is missing'
);

SELECT app.assert_true(
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_api'),
    'lego_api role is missing'
);
SELECT app.assert_true(
    EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_reporting'),
    'lego_reporting role is missing'
);

SELECT app.assert_true(
    NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'lego_app')
    AND NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'lego_app'),
    'lego_app must be NOLOGIN NOBYPASSRLS'
);

SELECT app.assert_true(
    NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'lego_admin')
    AND (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'lego_admin'),
    'lego_admin must be NOLOGIN BYPASSRLS'
);

SELECT app.assert_true(
    NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'lego_importer')
    AND (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'lego_importer'),
    'lego_importer must be NOLOGIN BYPASSRLS'
);

SELECT app.assert_true(
    NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'lego_api')
    AND NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'lego_api'),
    'lego_api must be NOLOGIN NOBYPASSRLS'
);

SELECT app.assert_true(
    NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'lego_reporting')
    AND NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'lego_reporting'),
    'lego_reporting must be NOLOGIN NOBYPASSRLS'
);


SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'lego_owner'
          AND NOT rolcanlogin
          AND NOT rolsuper
          AND NOT rolcreatedb
          AND NOT rolcreaterole
          AND NOT rolinherit
          AND NOT rolreplication
          AND NOT rolbypassrls
    ),
    'lego_owner must be NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1 FROM pg_roles
        WHERE rolname = 'lego_deployer'
          AND NOT rolcanlogin
          AND NOT rolsuper
          AND NOT rolcreatedb
          AND NOT rolcreaterole
          AND NOT rolinherit
          AND NOT rolreplication
          AND NOT rolbypassrls
    ),
    'lego_deployer must be NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS'
);

\echo '[PASS] 1100_roles.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1100_roles.sql');
