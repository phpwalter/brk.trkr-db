/*
===============================================================================
 File:           0500_collections/0508_collection_groups.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Add named collection containers without changing aggregate
                 ownership, and add deterministic API edit revisions to mutable
                 collection-domain resources.
 Depends On:     identity.owners
                 collection.entries
                 collection.storage_locations
                 collection.instances
 Creates:        collection.collections
                 collection.collection_memberships
 Key Rules:      Named collections group existing owned entries; membership does
                 not create or transfer ownership. An entry may appear in more
                 than one named collection. Mutable API resources carry a
                 positive edit_revision used for ETag / If-Match concurrency.
 Validation:     Enforces owner consistency through API routines/RLS and unique
                 collection-entry membership.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '0500_collections/0508_collection_groups.sql',
    ARRAY[
        'identity.owners',
        'collection.entries',
        'collection.storage_locations',
        'collection.instances'
    ]::text[]
);

CREATE TYPE collection.collection_visibility AS ENUM (
    'PRIVATE',
    'FAMILY',
    'PUBLIC'
);

CREATE TABLE collection.collections (
    collection_id uuid NOT NULL DEFAULT app.uuid_v7(),
    owner_id uuid NOT NULL,
    collection_name text NOT NULL,
    description text,
    visibility collection.collection_visibility NOT NULL DEFAULT 'PRIVATE',
    edit_revision bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,

    CONSTRAINT pk_collections PRIMARY KEY (collection_id),
    CONSTRAINT fk_collections_owner
        FOREIGN KEY (owner_id) REFERENCES identity.owners(owner_id),
    CONSTRAINT ck_collections_name CHECK (btrim(collection_name) <> ''),
    CONSTRAINT ck_collections_revision CHECK (edit_revision > 0)
);

CREATE INDEX ix_collections_owner
    ON collection.collections(owner_id, archived_at);

CREATE TABLE collection.collection_memberships (
    collection_id uuid NOT NULL,
    collection_entry_id uuid NOT NULL,
    sort_order integer,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_collection_memberships
        PRIMARY KEY (collection_id, collection_entry_id),
    CONSTRAINT fk_collection_memberships_collection
        FOREIGN KEY (collection_id)
        REFERENCES collection.collections(collection_id),
    CONSTRAINT fk_collection_memberships_entry
        FOREIGN KEY (collection_entry_id)
        REFERENCES collection.entries(collection_entry_id),
    CONSTRAINT ck_collection_memberships_sort
        CHECK (sort_order IS NULL OR sort_order >= 0)
);

CREATE INDEX ix_collection_memberships_entry
    ON collection.collection_memberships(collection_entry_id);

ALTER TABLE collection.storage_locations
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_storage_locations_revision CHECK (edit_revision > 0);

ALTER TABLE collection.entries
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_collection_entries_revision CHECK (edit_revision > 0);

ALTER TABLE collection.instances
    ADD COLUMN edit_revision bigint NOT NULL DEFAULT 1,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
    ADD CONSTRAINT ck_collection_instances_revision CHECK (edit_revision > 0);

SELECT app.assert_table_exists('collection', 'collections');
SELECT app.assert_table_exists('collection', 'collection_memberships');

\echo '[PASS] 0508_collection_groups.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0508_collection_groups.sql');
