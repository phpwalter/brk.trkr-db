/*
===============================================================================
 File:           0400_definitions/0400_inventory_definitions.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define stable identities for versioned manifests/compositions.
 Depends On:     catalog.items
 Creates:        definition.definition_kind
                 definition.inventory_definitions
 Key Rules:      A manifest definition is stable while its semantic versions may
                 change over time.
                 Sets, minifigures, books and MOCs share the same normalized
                 requirement engine.
 Validation:     Enforces one definition of each kind per catalog item.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0400_definitions/0400_inventory_definitions.sql', ARRAY['catalog.items']::text[]);



CREATE TYPE definition.definition_kind AS ENUM (
    'SET_MANIFEST',
    'MINIFIG_COMPOSITION',
    'BOOK_MANIFEST',
    'MOC_MANIFEST',
    'OTHER_MANIFEST'
);

CREATE TABLE definition.inventory_definitions (
    inventory_definition_id uuid NOT NULL DEFAULT app.uuid_v7(),

    catalog_item_id uuid NOT NULL,
    definition_kind definition.definition_kind NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_inventory_definitions
        PRIMARY KEY (inventory_definition_id),

    CONSTRAINT fk_inventory_definitions_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT uq_inventory_definition_item_kind
        UNIQUE (
            catalog_item_id,
            definition_kind
        )
);

CREATE INDEX ix_inventory_definitions_item
    ON definition.inventory_definitions(catalog_item_id);

SELECT app.assert_table_exists(
    'definition',
    'inventory_definitions'
);

\echo '[PASS] 0400_inventory_definitions.sql'
SELECT pg_temp.bt_mark_completed('0400_definitions/0400_inventory_definitions.sql');
