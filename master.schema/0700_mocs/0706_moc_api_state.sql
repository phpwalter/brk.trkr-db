/*
===============================================================================
 File:           0700_mocs/0706_moc_api_state.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Add deterministic API edit revisions to owner-managed MOC
                 identities and editable draft revisions.
 Depends On:     moc.mocs
                 moc.revisions
 Creates:        API concurrency state on MOC lifecycle resources
 Key Rules:      Published revisions remain immutable. edit_revision protects
                 owner-managed identity metadata and draft revision edits.
 Validation:     Revisions are positive.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '0700_mocs/0706_moc_api_state.sql',
    ARRAY['moc.mocs', 'moc.revisions']::text[]
);

ALTER TABLE moc.mocs
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_mocs_edit_revision CHECK (edit_revision > 0);

ALTER TABLE moc.revisions
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_moc_revisions_edit_revision CHECK (edit_revision > 0);

\echo '[PASS] 0706_moc_api_state.sql'
SELECT pg_temp.bt_mark_completed('0700_mocs/0706_moc_api_state.sql');
