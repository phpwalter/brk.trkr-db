/*
===============================================================================
 File:           0300_catalog/0301_catalog_sets.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store SET-specific canonical metadata.
 Depends On:     catalog.items
                 reference.themes
 Creates:        catalog.sets
 Key Rules:      LEGO set IDs are integer business identifiers.
                 Rebrickable suffixes such as -1/-2 are source inventory/version
                 identifiers and are not stored in lego_set_id.
                 LEGO numeric IDs are not assumed globally unique forever.
 Validation:     Enforces positive LEGO IDs, plausible release years and subtype
                 consistency through catalog runtime validation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0301_catalog_sets.sql', ARRAY['catalog.items', 'reference.themes']::text[]);



CREATE TABLE catalog.sets (
    catalog_item_id uuid NOT NULL,

    lego_set_id integer NOT NULL,
    theme_id integer,
    release_year smallint,

    CONSTRAINT pk_catalog_sets
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_sets_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_catalog_sets_theme
        FOREIGN KEY (theme_id)
        REFERENCES reference.themes(theme_id),

    CONSTRAINT ck_catalog_sets_lego_id
        CHECK (lego_set_id > 0),

    CONSTRAINT ck_catalog_sets_year
        CHECK (
            release_year IS NULL
            OR release_year BETWEEN 1930 AND 2200
        )
);

CREATE INDEX ix_catalog_sets_lego_id
    ON catalog.sets(lego_set_id);

CREATE INDEX ix_catalog_sets_theme
    ON catalog.sets(theme_id);

SELECT app.assert_table_exists('catalog', 'sets');

\echo '[PASS] 0301_catalog_sets.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0301_catalog_sets.sql');
