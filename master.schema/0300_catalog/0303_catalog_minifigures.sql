/*
===============================================================================
 File:           0300_catalog/0303_catalog_minifigures.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store MINIFIGURE-specific canonical metadata.
 Depends On:     catalog.items
                 reference.themes
 Creates:        catalog.minifigures
 Key Rules:      Complete minifigure identity is separate from component parts.
                 Minifigure composition is modeled by the versioned definition
                 engine rather than fixed anatomy columns.
 Validation:     Enforces positive optional LEGO minifigure IDs and subtype
                 consistency through catalog runtime validation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0303_catalog_minifigures.sql', ARRAY['catalog.items', 'reference.themes']::text[]);



CREATE TABLE catalog.minifigures (
    catalog_item_id uuid NOT NULL,

    lego_minifig_id integer,
    theme_id integer,

    CONSTRAINT pk_catalog_minifigures
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_minifigures_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_catalog_minifigures_theme
        FOREIGN KEY (theme_id)
        REFERENCES reference.themes(theme_id),

    CONSTRAINT ck_catalog_minifigures_lego_id
        CHECK (
            lego_minifig_id IS NULL
            OR lego_minifig_id > 0
        )
);

CREATE INDEX ix_catalog_minifigures_lego_id
    ON catalog.minifigures(lego_minifig_id);

CREATE INDEX ix_catalog_minifigures_theme
    ON catalog.minifigures(theme_id);

SELECT app.assert_table_exists('catalog', 'minifigures');

\echo '[PASS] 0303_catalog_minifigures.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0303_catalog_minifigures.sql');
