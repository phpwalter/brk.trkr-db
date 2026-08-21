/*
===============================================================================
 File:           0600_wanted/0600_wishlists.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define named user/family wishlists and their visibility.
 Depends On:     identity.owners
 Creates:        wanted.visibility
                 wanted.wishlists
 Key Rules:      Wishlists are separate from ownership.
                 An owner may maintain multiple named wishlists.
                 Only one active default wishlist may exist per owner.
 Validation:     Enforces non-empty names and one active default wishlist per
                 owner.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0600_wanted/0600_wishlists.sql', ARRAY['identity.owners']::text[]);



CREATE TYPE wanted.visibility AS ENUM (
    'PRIVATE',
    'FAMILY',
    'PUBLIC'
);

CREATE TABLE wanted.wishlists (
    wishlist_id uuid NOT NULL DEFAULT app.uuid_v7(),

    owner_id uuid NOT NULL,

    wishlist_name text NOT NULL,
    description text,

    visibility wanted.visibility
        NOT NULL DEFAULT 'PRIVATE',

    is_default boolean NOT NULL DEFAULT false,

    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,

    CONSTRAINT pk_wishlists
        PRIMARY KEY (wishlist_id),

    CONSTRAINT fk_wishlists_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT ck_wishlists_name
        CHECK (btrim(wishlist_name) <> '')
);

CREATE UNIQUE INDEX uq_default_wishlist_per_owner
    ON wanted.wishlists(owner_id)
    WHERE is_default
      AND archived_at IS NULL;

CREATE INDEX ix_wishlists_owner
    ON wanted.wishlists(owner_id);

SELECT app.assert_table_exists(
    'wanted',
    'wishlists'
);

\echo '[PASS] 0600_wishlists.sql'
SELECT pg_temp.bt_mark_completed('0600_wanted/0600_wishlists.sql');
