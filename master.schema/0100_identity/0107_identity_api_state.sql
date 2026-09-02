/*
===============================================================================
 File:           0100_identity/0107_identity_api_state.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Add user-facing profile metadata and deterministic API revisions
                 to user and family resources.
 Depends On:     identity.users
                 identity.families
 Creates:        API profile/concurrency state
 Key Rules:      Authentication identity remains separate from optional public
                 profile metadata. Mutable identity resources use positive
                 edit_revision values for ETag / If-Match.
 Validation:     Revisions are positive.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '0100_identity/0107_identity_api_state.sql',
    ARRAY['identity.users','identity.families']::text[]
);

ALTER TABLE identity.users
    ADD COLUMN bio text,
    ADD COLUMN avatar_url text,
    ADD COLUMN preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_users_edit_revision CHECK (edit_revision > 0),
    ADD CONSTRAINT ck_users_preferences_object CHECK (jsonb_typeof(preferences)='object');

ALTER TABLE identity.families
    ADD COLUMN description text,
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_families_edit_revision CHECK (edit_revision > 0);

\echo '[PASS] 0107_identity_api_state.sql'
SELECT pg_temp.bt_mark_completed('0100_identity/0107_identity_api_state.sql');
