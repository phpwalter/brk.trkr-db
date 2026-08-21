/*
===============================================================================
 File:           0700_mocs/0700_mocs.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define stable authored MOC identities and sharing policy.
 Depends On:     catalog.mocs
                 identity.owners
                 identity.users
 Creates:        moc.visibility
                 moc.mocs
 Key Rules:      Native MOCs have a stable identity separate from revisions.
                 MOC catalog identity is distinct from MOC lifecycle metadata.
                 Creator controls whether forks are permitted.
                 Private MOCs remain owner scoped.
 Validation:     Enforces one MOC lifecycle row per catalog MOC and non-empty
                 titles.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0700_mocs/0700_mocs.sql', ARRAY['catalog.mocs', 'identity.owners', 'identity.users']::text[]);



CREATE TYPE moc.visibility AS ENUM (
    'PRIVATE',
    'FAMILY',
    'UNLISTED',
    'PUBLIC'
);

CREATE TABLE moc.mocs (
    moc_id uuid NOT NULL DEFAULT app.uuid_v7(),

    catalog_item_id uuid NOT NULL,
    owner_id uuid NOT NULL,

    title text NOT NULL,
    description text,

    visibility moc.visibility
        NOT NULL DEFAULT 'PRIVATE',

    forks_allowed boolean NOT NULL DEFAULT true,

    created_by_user_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    archived_at timestamptz,

    CONSTRAINT pk_mocs
        PRIMARY KEY (moc_id),

    CONSTRAINT uq_mocs_catalog_item
        UNIQUE (catalog_item_id),

    CONSTRAINT fk_mocs_catalog_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.mocs(catalog_item_id),

    CONSTRAINT fk_mocs_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT fk_mocs_created_by
        FOREIGN KEY (created_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_mocs_title
        CHECK (btrim(title) <> '')
);

CREATE INDEX ix_mocs_owner
    ON moc.mocs(owner_id);

CREATE INDEX ix_mocs_visibility
    ON moc.mocs(visibility)
    WHERE archived_at IS NULL;

SELECT app.assert_table_exists('moc', 'mocs');

\echo '[PASS] 0700_mocs.sql'
SELECT pg_temp.bt_mark_completed('0700_mocs/0700_mocs.sql');
