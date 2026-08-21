/*
===============================================================================
 File:           0300_catalog/0307_catalog_instructions.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store collectible instruction booklet/manual metadata.
 Depends On:     catalog.items
 Creates:        catalog.instructions
 Key Rules:      Instructions are collectible objects separate from their set.
                 Multiple booklets may exist for one build/set.
                 Instructions are distinct from general BOOK/PUBLICATION items.
 Validation:     Enforces positive booklet/page values and subtype consistency
                 through catalog runtime validation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0307_catalog_instructions.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.instructions (
    catalog_item_id uuid NOT NULL,

    booklet_number smallint,
    language_code varchar(10),
    page_count integer,
    document_code text,

    CONSTRAINT pk_catalog_instructions
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_instructions_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_instructions_booklet
        CHECK (
            booklet_number IS NULL
            OR booklet_number > 0
        ),

    CONSTRAINT ck_catalog_instructions_pages
        CHECK (
            page_count IS NULL
            OR page_count > 0
        ),

    CONSTRAINT ck_catalog_instructions_language
        CHECK (
            language_code IS NULL
            OR btrim(language_code) <> ''
        )
);

SELECT app.assert_table_exists('catalog', 'instructions');

\echo '[PASS] 0307_catalog_instructions.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0307_catalog_instructions.sql');
