/*
===============================================================================
 File:           0100_identity/0100_users.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define application users and account lifecycle state.
 Depends On:     app.uuid_v7()
                 citext
 Creates:        identity.account_management_type
                 identity.account_status
                 identity.users
 Key Rules:      Managed children remain real user accounts.
                 User email is optional.
                 Username and email comparisons are case-insensitive.
                 Archived accounts retain historical identity.
 Validation:     Enforces username/display-name validity, email shape and
                 lifecycle timestamp consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0100_identity/0100_users.sql', ARRAY['app.uuid_v7()', 'citext']::text[]);



CREATE TYPE identity.account_management_type AS ENUM (
    'INDEPENDENT',
    'MANAGED_CHILD'
);

CREATE TYPE identity.account_status AS ENUM (
    'PENDING',
    'ACTIVE',
    'LOCKED',
    'DISABLED',
    'ARCHIVED'
);

CREATE TABLE identity.users (
    user_id uuid NOT NULL DEFAULT app.uuid_v7(),

    username citext NOT NULL,
    display_name text NOT NULL,
    email citext,

    account_management_type identity.account_management_type
        NOT NULL DEFAULT 'INDEPENDENT',

    account_status identity.account_status
        NOT NULL DEFAULT 'PENDING',

    date_of_birth date,
    locale text,
    timezone_name text,

    created_at timestamptz NOT NULL DEFAULT now(),
    activated_at timestamptz,
    archived_at timestamptz,

    CONSTRAINT pk_users
        PRIMARY KEY (user_id),

    CONSTRAINT uq_users_username
        UNIQUE (username),

    CONSTRAINT uq_users_email
        UNIQUE (email),

    CONSTRAINT ck_users_username
        CHECK (btrim(username::text) <> ''),

    CONSTRAINT ck_users_display_name
        CHECK (btrim(display_name) <> ''),

    CONSTRAINT ck_users_email
        CHECK (
            email IS NULL
            OR email::text ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
        ),

    CONSTRAINT ck_users_active
        CHECK (
            account_status <> 'ACTIVE'
            OR activated_at IS NOT NULL
        ),

    CONSTRAINT ck_users_archived
        CHECK (
            account_status <> 'ARCHIVED'
            OR archived_at IS NOT NULL
        )
);

CREATE INDEX ix_users_status
    ON identity.users(account_status);

CREATE INDEX ix_users_management_type
    ON identity.users(account_management_type);

SELECT app.assert_table_exists('identity', 'users');
SELECT app.assert_constraint_exists('identity', 'users', 'pk_users');
SELECT app.assert_constraint_exists('identity', 'users', 'uq_users_username');
SELECT app.assert_index_exists('identity', 'ix_users_status');

\echo '[PASS] 0100_users.sql'
SELECT pg_temp.bt_mark_completed('0100_identity/0100_users.sql');
