/*
===============================================================================
 File:           0300_catalog/0304_catalog_books.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store BOOK-specific bibliographic metadata.
 Depends On:     catalog.items
 Creates:        catalog.books
 Key Rules:      Books are distinct from magazines/catalogs/periodicals.
                 Included LEGO pieces/minifigures are represented by inventory
                 manifests rather than embedded book columns.
 Validation:     Enforces non-empty ISBN/language values when supplied and
                 subtype consistency through catalog runtime validation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0304_catalog_books.sql', ARRAY['catalog.items']::text[]);



CREATE TABLE catalog.books (
    catalog_item_id uuid NOT NULL,

    isbn text,
    publisher text,
    publication_date date,
    edition text,
    language_code varchar(10),

    CONSTRAINT pk_catalog_books
        PRIMARY KEY (catalog_item_id),

    CONSTRAINT fk_catalog_books_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT ck_catalog_books_isbn
        CHECK (
            isbn IS NULL
            OR btrim(isbn) <> ''
        ),

    CONSTRAINT ck_catalog_books_language
        CHECK (
            language_code IS NULL
            OR btrim(language_code) <> ''
        )
);

CREATE INDEX ix_catalog_books_isbn
    ON catalog.books(isbn);

SELECT app.assert_table_exists('catalog', 'books');

\echo '[PASS] 0304_catalog_books.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0304_catalog_books.sql');
