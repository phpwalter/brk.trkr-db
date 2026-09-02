/*
===============================================================================
 File:           0400_definitions/0407_custom_minifig_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Distinguish owner-authored custom minifigures from canonical
                 source-controlled MINIFIGURE catalog resources.
 Depends On:     catalog.minifigures
                 identity.owners
                 identity.users
 Creates:        definition.custom_visibility
                 definition.custom_minifigs
 Key Rules:      Canonical imported minifigures remain read-only to normal
                 users. A custom minifigure keeps canonical catalog identity but
                 owner lifecycle state is stored separately. Custom minifigures
                 are soft archived/restored and use edit_revision for API
                 optimistic concurrency.
 Validation:     Enforces one custom lifecycle row per minifigure catalog item,
                 positive revisions and non-empty owner/creator references.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '0400_definitions/0407_custom_minifig_lifecycle.sql',
    ARRAY[
        'catalog.minifigures',
        'identity.owners',
        'identity.users'
    ]::text[]
);

CREATE TYPE definition.custom_visibility AS ENUM (
    'PRIVATE',
    'FAMILY',
    'UNLISTED',
    'PUBLIC'
);

CREATE TABLE definition.custom_minifigs (
    custom_minifig_id uuid NOT NULL DEFAULT app.uuid_v7(),
    catalog_item_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    created_by_user_id uuid NOT NULL,
    visibility definition.custom_visibility NOT NULL DEFAULT 'PRIVATE',
    description text,
    edit_revision bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,

    CONSTRAINT pk_custom_minifigs PRIMARY KEY (custom_minifig_id),
    CONSTRAINT uq_custom_minifigs_catalog_item UNIQUE (catalog_item_id),
    CONSTRAINT fk_custom_minifigs_catalog_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.minifigures(catalog_item_id),
    CONSTRAINT fk_custom_minifigs_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),
    CONSTRAINT fk_custom_minifigs_creator
        FOREIGN KEY (created_by_user_id)
        REFERENCES identity.users(user_id),
    CONSTRAINT ck_custom_minifigs_revision CHECK (edit_revision > 0)
);

CREATE INDEX ix_custom_minifigs_owner
    ON definition.custom_minifigs(owner_id, archived_at);

CREATE INDEX ix_custom_minifigs_visibility
    ON definition.custom_minifigs(visibility)
    WHERE archived_at IS NULL;

SELECT app.assert_table_exists('definition', 'custom_minifigs');

\echo '[PASS] 0407_custom_minifig_lifecycle.sql'
SELECT pg_temp.bt_mark_completed('0400_definitions/0407_custom_minifig_lifecycle.sql');
