/*
===============================================================================
 File:           0300_catalog/0309_catalog_gear.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store LEGO merchandise/GEAR-specific metadata.
 Depends On:     catalog.items
                 reference.categories
 Creates:        catalog.gear
 Key Rules:      Gear is a first-class collectible category distinct from sets
                 and building parts.
                 Classification remains extensible through reference.categories.
 Validation:     Foreign keys enforce canonical category/item references and
                 catalog runtime logic verifies item_kind = GEAR.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0309_catalog_gear.sql', ARRAY['catalog.items', 'reference.categories']::text[]);



CREATE TABLE catalog.gear (
    catalog_item_id uuid NOT NULL,

    category_id integer,
    product_code text,

    CONSTRAINT pk_catalog_gear
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_gear_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_catalog_gear_category
        FOREIGN KEY (category_id)
        REFERENCES reference.categories(category_id),

    CONSTRAINT ck_catalog_gear_product_code
        CHECK (
            product_code IS NULL
            OR btrim(product_code) <> ''
        )
);

SELECT app.assert_table_exists('catalog', 'gear');

\echo '[PASS] 0309_catalog_gear.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0309_catalog_gear.sql');
