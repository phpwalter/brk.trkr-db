/*
===============================================================================
 File:           0300_catalog/0315_part_variants.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define color, decoration and mold variants of canonical PART
                 designs.
 Depends On:     catalog.parts
                 reference.colors
 Creates:        catalog.part_variants
 Key Rules:      The part hierarchy is catalog.parts -> part_variants ->
                 lego_elements.
                 Printed/decorated parts are variants of the base design.
                 Stickered state remains distinguishable from printed decoration.
                 NULL color may represent an unresolved/unspecified variant.
 Validation:     Printed variants require decoration metadata; foreign keys
                 enforce valid part/color references.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0315_part_variants.sql', ARRAY['catalog.parts', 'reference.colors']::text[]);



CREATE TABLE catalog.part_variants (
    part_variant_id uuid NOT NULL DEFAULT app.uuid_v7(),

    part_catalog_item_id uuid NOT NULL,
    color_id integer,

    decoration_code text,
    mold_code text,

    is_printed boolean NOT NULL DEFAULT false,
    is_stickered boolean NOT NULL DEFAULT false,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_part_variants
        PRIMARY KEY (part_variant_id),

    CONSTRAINT fk_part_variants_part
        FOREIGN KEY (part_catalog_item_id)
        REFERENCES catalog.parts(catalog_item_id),

    CONSTRAINT fk_part_variants_color
        FOREIGN KEY (color_id)
        REFERENCES reference.colors(color_id),

    CONSTRAINT ck_part_variants_print
        CHECK (
            NOT is_printed
            OR (
                decoration_code IS NOT NULL
                AND btrim(decoration_code) <> ''
            )
        )
);

CREATE INDEX ix_part_variants_part
    ON catalog.part_variants(part_catalog_item_id);

CREATE INDEX ix_part_variants_color
    ON catalog.part_variants(color_id);

SELECT app.assert_table_exists('catalog', 'part_variants');

\echo '[PASS] 0315_part_variants.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0315_part_variants.sql');
