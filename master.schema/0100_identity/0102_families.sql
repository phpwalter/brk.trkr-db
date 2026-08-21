/*
===============================================================================
 File:           0100_identity/0102_families.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define family identities and lifecycle state.
 Depends On:     identity.users
 Creates:        identity.family_status
                 identity.families
 Key Rules:      Families are persistent principals whose history is retained.
                 Family creation records the acting user.
                 Archived family records are not hard-deleted.
 Validation:     Enforces non-empty family names and archive timestamp
                 consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0100_identity/0102_families.sql', ARRAY['identity.users']::text[]);



CREATE TYPE identity.family_status AS ENUM (
    'ACTIVE',
    'ARCHIVED'
);

CREATE TABLE identity.families (
    family_id uuid NOT NULL DEFAULT app.uuid_v7(),
    family_name text NOT NULL,

    status identity.family_status
        NOT NULL DEFAULT 'ACTIVE',

    created_by_user_id uuid NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,

    CONSTRAINT pk_families
        PRIMARY KEY (family_id),

    CONSTRAINT fk_families_created_by
        FOREIGN KEY (created_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_families_name
        CHECK (btrim(family_name) <> ''),

    CONSTRAINT ck_families_archived
        CHECK (
            status <> 'ARCHIVED'
            OR archived_at IS NOT NULL
        )
);

CREATE INDEX ix_families_created_by
    ON identity.families(created_by_user_id);

SELECT app.assert_table_exists('identity', 'families');
SELECT app.assert_constraint_exists('identity', 'families', 'pk_families');

\echo '[PASS] 0102_families.sql'
SELECT pg_temp.bt_mark_completed('0100_identity/0102_families.sql');
