/*
===============================================================================
 File:           0300_catalog/0311_catalog_polybags.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store collectible POLYBAG/package identities.
 Depends On:     catalog.items
 Creates:        catalog.polybags
 Key Rules:      A normal LEGO set distributed in a polybag remains item_kind
                 SET.
                 POLYBAG is reserved for a separately collectible bag/package
                 identity.
 Validation:     Enforces non-empty bag code when supplied and catalog runtime
                 logic verifies item_kind = POLYBAG.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0311_catalog_polybags.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.polybags (
    catalog_item_id uuid NOT NULL,

    bag_code text,
    package_description text,

    CONSTRAINT pk_catalog_polybags
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_polybags_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_polybags_code
        CHECK (
            bag_code IS NULL
            OR btrim(bag_code) <> ''
        )
);

SELECT app.assert_table_exists('catalog', 'polybags');

\echo '[PASS] 0311_catalog_polybags.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0311_catalog_polybags.sql');
