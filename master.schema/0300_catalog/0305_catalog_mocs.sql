/*
===============================================================================
 File:           0300_catalog/0305_catalog_mocs.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Provide the canonical catalog subtype for native MOC identities.
 Depends On:     catalog.items
 Creates:        catalog.mocs
 Key Rules:      catalog.mocs represents catalog identity only.
                 MOC ownership, authorship, visibility, revisions and forks live
                 in the separate moc schema.
                 Rebrickable MOC catalog data is not imported.
 Validation:     Primary/FK constraints enforce one subtype row per catalog item;
                 catalog runtime logic verifies item_kind = MOC.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0305_catalog_mocs.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.mocs (
    catalog_item_id uuid NOT NULL,

    discovery_summary text,

    CONSTRAINT pk_catalog_mocs
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_mocs_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id)
);

SELECT app.assert_table_exists('catalog', 'mocs');

\echo '[PASS] 0305_catalog_mocs.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0305_catalog_mocs.sql');
