/*
===============================================================================
 File:           0300_catalog/0306_catalog_sticker_sheets.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store STICKER_SHEET-specific collectible metadata.
 Depends On:     catalog.items
 Creates:        catalog.sticker_sheets
 Key Rules:      Sticker sheets are collectible objects in their own right.
                 Sticker sheets are distinct from printed part decoration.
                 Applied sticker state may be represented by collection/item
                 condition rather than changing canonical part identity.
 Validation:     Enforces non-empty sheet codes when provided and subtype
                 consistency through catalog runtime validation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0306_catalog_sticker_sheets.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.sticker_sheets (
    catalog_item_id uuid NOT NULL,

    sheet_code text,
    description text,

    CONSTRAINT pk_catalog_sticker_sheets
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_sticker_sheets_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_sticker_sheets_code
        CHECK (
            sheet_code IS NULL
            OR btrim(sheet_code) <> ''
        )
);

SELECT app.assert_table_exists('catalog', 'sticker_sheets');

\echo '[PASS] 0306_catalog_sticker_sheets.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0306_catalog_sticker_sheets.sql');
