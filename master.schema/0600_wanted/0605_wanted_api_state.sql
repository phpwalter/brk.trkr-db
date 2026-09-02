/*
===============================================================================
 File:           0600_wanted/0605_wanted_api_state.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Add deterministic API edit revisions and missing lifecycle state
                 to mutable wishlist and build-goal resources.
 Depends On:     wanted.wishlists
                 wanted.wishlist_entries
                 wanted.build_goals
 Creates:        API concurrency and retained satisfaction/archive state
 Key Rules:      Mutations increment edit_revision exactly once per successful
                 logical change. Satisfaction and archive history is retained.
                 Build goals have user-facing names/notes without conflating
                 them with wishlist acquisition intent.
 Validation:     Revisions are positive; satisfied quantity never exceeds desired
                 quantity.
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
    ADD COLUMN satisfied_quantity app.quantity NOT NULL DEFAULT 0,
    ADD COLUMN archived_at timestamptz,
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_wishlist_entries_satisfied_quantity
        CHECK (satisfied_quantity >= 0 AND satisfied_quantity <= desired_quantity),
    ADD CONSTRAINT ck_wishlist_entries_revision CHECK (edit_revision > 0);

ALTER TABLE wanted.build_goals
    ADD COLUMN goal_name text,
    ADD COLUMN notes text,
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_build_goals_name CHECK (goal_name IS NULL OR btrim(goal_name) <> ''),
    ADD CONSTRAINT ck_build_goals_revision CHECK (edit_revision > 0);

\echo '[PASS] 0605_wanted_api_state.sql'
SELECT pg_temp.bt_mark_completed('0600_wanted/0605_wanted_api_state.sql');
