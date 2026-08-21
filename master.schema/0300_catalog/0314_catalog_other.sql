/*
===============================================================================
 File:           0300_catalog/0314_catalog_other.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store controlled metadata for legitimate catalog items that do
                 not fit another supported item kind.
 Depends On:     catalog.items
 Creates:        catalog.other_items
 Key Rules:      OTHER is a deliberate fallback, not a replacement for modeled
                 first-class catalog kinds.
                 The reason/type description is mandatory.
 Validation:     Requires a non-empty type description and catalog runtime logic
                 verifies item_kind = OTHER.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0314_catalog_other.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.other_items (
    catalog_item_id uuid NOT NULL,

    item_type_description text NOT NULL,
    notes text,

    CONSTRAINT pk_catalog_other_items
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_other_items_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_other_items_description
        CHECK (btrim(item_type_description) <> '')
);

SELECT app.assert_table_exists('catalog', 'other_items');

\echo '[PASS] 0314_catalog_other.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0314_catalog_other.sql');
