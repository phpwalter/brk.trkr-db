/*
===============================================================================
 File:           0300_catalog/0308_catalog_packaging.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store collectible PACKAGING metadata such as boxes and
                 containers.
 Depends On:     catalog.items
 Creates:        catalog.packaging
 Key Rules:      Packaging may be tracked independently from the item it
                 originally contained.
                 Packaging condition is collection-instance state, not canonical
                 catalog metadata.
 Validation:     Enforces non-empty optional type/code values and subtype
                 consistency through catalog runtime validation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0308_catalog_packaging.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.packaging (
    catalog_item_id uuid NOT NULL,

    packaging_type text,
    packaging_code text,
    description text,

    CONSTRAINT pk_catalog_packaging
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_packaging_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_packaging_type
        CHECK (
            packaging_type IS NULL
            OR btrim(packaging_type) <> ''
        ),

    CONSTRAINT ck_catalog_packaging_code
        CHECK (
            packaging_code IS NULL
            OR btrim(packaging_code) <> ''
        )
);

SELECT app.assert_table_exists('catalog', 'packaging');

\echo '[PASS] 0308_catalog_packaging.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0308_catalog_packaging.sql');
