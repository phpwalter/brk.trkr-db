/*
===============================================================================
 File:           0300_catalog/0313_catalog_publications.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store magazine, catalog, periodical and other PUBLICATION
                 metadata.
 Depends On:     catalog.items
 Creates:        catalog.publications
 Key Rules:      PUBLICATION covers periodicals/catalogs and remains distinct
                 from conventional BOOK items.
                 Publication issue/volume metadata is optional and extensible.
 Validation:     Enforces non-empty publication title when supplied and catalog
                 runtime logic verifies item_kind = PUBLICATION.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0313_catalog_publications.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.publications (
    catalog_item_id uuid NOT NULL,

    publication_title text,
    issue_number text,
    volume_number text,
    issn text,

    publisher text,
    publication_date date,
    language_code varchar(10),

    CONSTRAINT pk_catalog_publications
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_publications_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_publications_title
        CHECK (
            publication_title IS NULL
            OR btrim(publication_title) <> ''
        )
);

CREATE INDEX ix_catalog_publications_issn
    ON catalog.publications(issn);

SELECT app.assert_table_exists('catalog', 'publications');

\echo '[PASS] 0313_catalog_publications.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0313_catalog_publications.sql');
