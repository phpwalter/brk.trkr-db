/*
===============================================================================
 File:           0700_mocs/0701_moc_revisions.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store draft, published and archived MOC revision history.
 Depends On:     moc.mocs
                 definition.inventory_versions
                 identity.users
 Creates:        moc.revision_status
                 moc.revisions
 Key Rules:      Draft revisions are editable.
                 Published revisions are immutable.
                 Editing a published design requires a new draft revision.
                 Published revisions preserve their exact semantic fingerprint.
 Validation:     Enforces unique revision numbers, positive revision numbers and
                 complete publication state.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0700_mocs/0701_moc_revisions.sql', ARRAY['moc.mocs', 'definition.inventory_versions', 'identity.users']::text[]);



CREATE TYPE moc.revision_status AS ENUM (
    'DRAFT',
    'PUBLISHED',
    'ARCHIVED'
);

CREATE TABLE moc.revisions (
    moc_revision_id uuid NOT NULL DEFAULT app.uuid_v7(),

    moc_id uuid NOT NULL,

    revision_number integer NOT NULL,

    parent_revision_id uuid,

    inventory_version_id uuid,

    status moc.revision_status
        NOT NULL DEFAULT 'DRAFT',

    semantic_hash app.sha256_digest,

    created_by_user_id uuid NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,

    CONSTRAINT pk_moc_revisions
        PRIMARY KEY (moc_revision_id),

    CONSTRAINT fk_moc_revisions_moc
        FOREIGN KEY (moc_id)
        REFERENCES moc.mocs(moc_id),

    CONSTRAINT fk_moc_revisions_parent
        FOREIGN KEY (parent_revision_id)
        REFERENCES moc.revisions(moc_revision_id),

    CONSTRAINT fk_moc_revisions_inventory
        FOREIGN KEY (inventory_version_id)
        REFERENCES definition.inventory_versions(
            inventory_version_id
        ),

    CONSTRAINT fk_moc_revisions_created_by
        FOREIGN KEY (created_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT uq_moc_revision_number
        UNIQUE (
            moc_id,
            revision_number
        ),

    CONSTRAINT ck_moc_revisions_number
        CHECK (revision_number > 0),

    CONSTRAINT ck_moc_revisions_published
        CHECK (
            status <> 'PUBLISHED'
            OR (
                published_at IS NOT NULL
                AND inventory_version_id IS NOT NULL
                AND semantic_hash IS NOT NULL
            )
        )
);

CREATE INDEX ix_moc_revisions_moc
    ON moc.revisions(
        moc_id,
        revision_number DESC
    );

SELECT app.assert_table_exists(
    'moc',
    'revisions'
);

\echo '[PASS] 0701_moc_revisions.sql'
SELECT pg_temp.bt_mark_completed('0700_mocs/0701_moc_revisions.sql');
