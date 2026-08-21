/*
===============================================================================
 File:           0700_mocs/0705_moc_assets.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store metadata for MOC Studio files, images, instructions and
                 other binary assets.
 Depends On:     moc.revisions
                 app.sha256_digest
 Creates:        moc.assets
 Key Rules:      Binary contents remain in object storage.
                 PostgreSQL stores object keys, metadata and checksums only.
                 Assets remain associated with the exact MOC revision.
 Validation:     Enforces non-empty type/storage-key/filename values and
                 non-negative optional byte size.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0700_mocs/0705_moc_assets.sql', ARRAY['moc.revisions', 'app.sha256_digest']::text[]);



CREATE TABLE moc.assets (
    moc_asset_id uuid NOT NULL DEFAULT app.uuid_v7(),

    moc_revision_id uuid NOT NULL,

    asset_type text NOT NULL,

    storage_key text NOT NULL,
    original_filename text NOT NULL,
    mime_type text,

    size_bytes bigint,
    checksum_sha256 app.sha256_digest,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_moc_assets
        PRIMARY KEY (moc_asset_id),

    CONSTRAINT fk_moc_assets_revision
        FOREIGN KEY (moc_revision_id)
        REFERENCES moc.revisions(moc_revision_id),

    CONSTRAINT ck_moc_assets_type
        CHECK (btrim(asset_type) <> ''),

    CONSTRAINT ck_moc_assets_key
        CHECK (btrim(storage_key) <> ''),

    CONSTRAINT ck_moc_assets_filename
        CHECK (btrim(original_filename) <> ''),

    CONSTRAINT ck_moc_assets_size
        CHECK (
            size_bytes IS NULL
            OR size_bytes >= 0
        )
);

CREATE INDEX ix_moc_assets_revision
    ON moc.assets(moc_revision_id);

SELECT app.assert_table_exists(
    'moc',
    'assets'
);

\echo '[PASS] 0705_moc_assets.sql'
SELECT pg_temp.bt_mark_completed('0700_mocs/0705_moc_assets.sql');
