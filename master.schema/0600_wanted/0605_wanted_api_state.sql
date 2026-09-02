/*
===============================================================================
 File:           0600_wanted/0605_wanted_api_state.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Add deterministic API edit revisions and update timestamps to
                 mutable wishlist and build-goal resources.
 Depends On:     wanted.wishlists
                 wanted.wishlist_entries
                 wanted.build_goals
 Creates:        API concurrency state on wanted-domain resources
 Key Rules:      Mutations increment edit_revision exactly once per successful
                 logical change. Archived/satisfied history remains retained.
 Validation:     Revisions are positive.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '0600_wanted/0605_wanted_api_state.sql',
    ARRAY[
        'wanted.wishlists',
        'wanted.wishlist_entries',
        'wanted.build_goals'
    ]::text[]
);

ALTER TABLE wanted.wishlists
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_wishlists_revision CHECK (edit_revision > 0);

ALTER TABLE wanted.wishlist_entries
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_wishlist_entries_revision CHECK (edit_revision > 0);

ALTER TABLE wanted.build_goals
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_build_goals_revision CHECK (edit_revision > 0);

\echo '[PASS] 0605_wanted_api_state.sql'
SELECT pg_temp.bt_mark_completed('0600_wanted/0605_wanted_api_state.sql');
