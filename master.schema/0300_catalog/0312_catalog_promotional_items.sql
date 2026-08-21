/*
===============================================================================
 File:           0300_catalog/0312_catalog_promotional_items.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store PROMOTIONAL_ITEM-specific campaign/event metadata.
 Depends On:     catalog.items
 Creates:        catalog.promotional_items
 Key Rules:      Promotional items remain canonical collectible identities.
                 Promotion timing describes provenance/availability and does not
                 define ownership state.
 Validation:     Enforces promotion date chronology and catalog runtime logic
                 verifies item_kind = PROMOTIONAL_ITEM.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0312_catalog_promotional_items.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.promotional_items (
    catalog_item_id uuid NOT NULL,

    campaign_name text,
    event_name text,

    promotion_start_date date,
    promotion_end_date date,

    CONSTRAINT pk_catalog_promotional_items
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_promotional_items_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_promotional_items_dates
        CHECK (
            promotion_end_date IS NULL
            OR promotion_start_date IS NULL
            OR promotion_end_date >= promotion_start_date
        )
);

SELECT app.assert_table_exists('catalog', 'promotional_items');

\echo '[PASS] 0312_catalog_promotional_items.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0312_catalog_promotional_items.sql');
