/*
===============================================================================
 File:           0300_catalog/0310_catalog_accessories.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store collectible ACCESSORY-specific metadata.
 Depends On:     catalog.items
 Creates:        catalog.accessories
 Key Rules:      Accessories represent collectible non-part accessory products.
                 Extensible descriptive metadata is preferred over prematurely
                 encoding a fixed accessory taxonomy.
 Validation:     Enforces non-empty optional values and catalog runtime logic
                 verifies item_kind = ACCESSORY.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0310_catalog_accessories.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.accessories (
    catalog_item_id uuid NOT NULL,

    accessory_type text,
    product_code text,

    CONSTRAINT pk_catalog_accessories
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_accessories_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_accessories_type
        CHECK (
            accessory_type IS NULL
            OR btrim(accessory_type) <> ''
        ),

    CONSTRAINT ck_catalog_accessories_product_code
        CHECK (
            product_code IS NULL
            OR btrim(product_code) <> ''
        )
);

SELECT app.assert_table_exists('catalog', 'accessories');

\echo '[PASS] 0310_catalog_accessories.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0310_catalog_accessories.sql');
