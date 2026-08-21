/*
===============================================================================
 File:           0300_catalog/0302_catalog_parts.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store canonical PART design identities and design-level metadata.
 Depends On:     catalog.items
                 reference.categories
 Creates:        catalog.parts
 Key Rules:      catalog.parts represents the base part/design level.
                 Color/decoration/mold variants are stored separately.
                 LEGO element IDs are stored separately from design IDs.
                 Retired/superseded designs remain searchable.
 Validation:     Enforces positive optional LEGO design IDs, non-empty design
                 names and prevents direct self-supersession.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0302_catalog_parts.sql', ARRAY['catalog.items', 'reference.categories']::text[]);



CREATE TABLE catalog.parts (
    catalog_item_id uuid NOT NULL,

    lego_design_id integer,
    category_id integer,

    design_name text NOT NULL,

    superseded_by_catalog_item_id uuid,

    CONSTRAINT pk_catalog_parts
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_parts_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_catalog_parts_category
        FOREIGN KEY (category_id)
        REFERENCES reference.categories(category_id),

    CONSTRAINT fk_catalog_parts_superseded_by
        FOREIGN KEY (superseded_by_catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_parts_design_id
        CHECK (
            lego_design_id IS NULL
            OR lego_design_id > 0
        ),

    CONSTRAINT ck_catalog_parts_name
        CHECK (btrim(design_name) <> ''),

    CONSTRAINT ck_catalog_parts_not_self_superseded
        CHECK (
            superseded_by_catalog_item_id IS NULL
            OR superseded_by_catalog_item_id <> catalog_item_id
        )
);

CREATE INDEX ix_catalog_parts_lego_design_id
    ON catalog.parts(lego_design_id);

CREATE INDEX ix_catalog_parts_category
    ON catalog.parts(category_id);

SELECT app.assert_table_exists('catalog', 'parts');

\echo '[PASS] 0302_catalog_parts.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0302_catalog_parts.sql');
