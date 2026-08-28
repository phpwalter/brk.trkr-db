/*
===============================================================================
 File:           0300_catalog/0300_catalog_items.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.2.0
 PostgreSQL:     16+
 Purpose:        Define the canonical root identity for every collectible catalog
                 object.
 Depends On:     identity.owners
 Creates:        catalog.item_kind
                 catalog.item_status
                 catalog.items
 Key Rules:      Internal canonical identity uses UUIDv7.
                 Public API identity uses stable item_num and never exposes the
                 internal UUID as the primary resource identifier.
                 LEGO/source identifiers are mappings, never primary keys.
                 Every declared item kind has a dedicated subtype table.
                 UNRESOLVED_CUSTOM items are private to an owner until promoted.
 Validation:     Enforces valid unresolved-owner state, non-empty names and
                 archive timestamp consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0300_catalog_items.sql', ARRAY['identity.owners']::text[]);

CREATE TYPE catalog.item_kind AS ENUM (
    'SET',
    'PART',
    'MINIFIGURE',
    'BOOK',
    'MOC',
    'STICKER_SHEET',
    'INSTRUCTIONS',
    'PACKAGING',
    'GEAR',
    'ACCESSORY',
    'POLYBAG',
    'PROMOTIONAL_ITEM',
    'PUBLICATION',
    'OTHER'
);

CREATE TYPE catalog.item_status AS ENUM (
    'ACTIVE',
    'RETIRED',
    'SOURCE_MISSING',
    'UNRESOLVED_CUSTOM',
    'ARCHIVED'
);

CREATE TABLE catalog.items (
    catalog_item_id uuid NOT NULL DEFAULT app.uuid_v7(),

    item_kind catalog.item_kind NOT NULL,
    item_num text,
    canonical_name text NOT NULL,

    status catalog.item_status
        NOT NULL DEFAULT 'ACTIVE',

    /*
     * Canonical shared catalog rows use NULL.
     * Owner-private unresolved imports must identify their owner.
     */
    unresolved_owner_id uuid,

    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,

    CONSTRAINT pk_catalog_items
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_items_unresolved_owner
        FOREIGN KEY (unresolved_owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT ck_catalog_items_item_num
        CHECK (
            item_num IS NULL
            OR item_num ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        ),

    CONSTRAINT ck_catalog_items_name
        CHECK (btrim(canonical_name) <> ''),

    CONSTRAINT ck_catalog_items_unresolved_owner
        CHECK (
            (
                status = 'UNRESOLVED_CUSTOM'
                AND unresolved_owner_id IS NOT NULL
            )
            OR
            (
                status <> 'UNRESOLVED_CUSTOM'
                AND unresolved_owner_id IS NULL
            )
        ),

    CONSTRAINT ck_catalog_items_archive
        CHECK (
            status <> 'ARCHIVED'
            OR archived_at IS NOT NULL
        )
);

CREATE UNIQUE INDEX uq_catalog_items_item_num
    ON catalog.items(item_num)
    WHERE item_num IS NOT NULL;

CREATE INDEX ix_catalog_items_kind_status
    ON catalog.items(
        item_kind,
        status
    );

CREATE INDEX ix_catalog_items_name
    ON catalog.items(canonical_name);

CREATE INDEX ix_catalog_items_unresolved_owner
    ON catalog.items(unresolved_owner_id)
    WHERE unresolved_owner_id IS NOT NULL;

SELECT app.assert_table_exists('catalog', 'items');
SELECT app.assert_constraint_exists('catalog', 'items', 'pk_catalog_items');
SELECT app.assert_index_exists('catalog', 'uq_catalog_items_item_num');

\echo '[PASS] 0300_catalog_items.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0300_catalog_items.sql');
