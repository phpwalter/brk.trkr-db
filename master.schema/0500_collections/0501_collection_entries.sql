/*
===============================================================================
 File:           0500_collections/0501_collection_entries.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store logical aggregate ownership for catalog items and precise
                 part variants.
 Depends On:     identity.owners
                 catalog.items
                 catalog.part_variants
 Creates:        collection.entry_status
                 collection.entries
 Key Rules:      An entry targets exactly one catalog item or part variant.
                 Logical aggregate ownership is separate from individual
                 physical-instance state.
                 Ownership is distinct from allocation and availability.
 Validation:     Enforces target exclusivity, positive quantities and archive
                 timestamp consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0500_collections/0501_collection_entries.sql', ARRAY['identity.owners', 'catalog.items', 'catalog.part_variants']::text[]);



CREATE TYPE collection.entry_status AS ENUM (
    'ACTIVE',
    'ARCHIVED'
);

CREATE TABLE collection.entries (
    collection_entry_id uuid NOT NULL DEFAULT app.uuid_v7(),

    owner_id uuid NOT NULL,

    catalog_item_id uuid,
    part_variant_id uuid,

    quantity app.quantity NOT NULL DEFAULT 1,

    status collection.entry_status
        NOT NULL DEFAULT 'ACTIVE',

    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,

    CONSTRAINT pk_collection_entries
        PRIMARY KEY (collection_entry_id),

    CONSTRAINT fk_collection_entries_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT fk_collection_entries_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_collection_entries_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT ck_collection_entries_target
        CHECK (
            num_nonnulls(
                catalog_item_id,
                part_variant_id
            ) = 1
        ),

    CONSTRAINT ck_collection_entries_archive
        CHECK (
            status <> 'ARCHIVED'
            OR archived_at IS NOT NULL
        )
);

CREATE INDEX ix_collection_entries_owner
    ON collection.entries(
        owner_id,
        status
    );

CREATE INDEX ix_collection_entries_item
    ON collection.entries(catalog_item_id)
    WHERE catalog_item_id IS NOT NULL;

CREATE INDEX ix_collection_entries_variant
    ON collection.entries(part_variant_id)
    WHERE part_variant_id IS NOT NULL;

SELECT app.assert_table_exists(
    'collection',
    'entries'
);

\echo '[PASS] 0501_collection_entries.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0501_collection_entries.sql');
