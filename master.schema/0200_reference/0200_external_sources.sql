/*
===============================================================================
 File:           0200_reference/0200_external_sources.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define known external catalog, collection and marketplace
                 systems.
 Depends On:     reference schema
 Creates:        reference.external_sources
 Seed Data:      LEGO
                 REBRICKABLE
                 BRICKLINK
                 BRICKOWL
                 STUDIO
 Key Rules:      External source identifiers are mappings/evidence and are never
                 internal primary keys.
                 Source authority is modeled at the relevant dataset/field level
                 rather than with one global authoritative-source boolean.
 Validation:     Enforces unique source codes and seeds the five baseline
                 external systems.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0200_reference/0200_external_sources.sql', ARRAY['reference schema']::text[]);



CREATE TABLE reference.external_sources (
    source_id smallint GENERATED ALWAYS AS IDENTITY,

    source_code text NOT NULL,
    source_name text NOT NULL,
    website_url text,

    provides_catalog_data boolean NOT NULL DEFAULT false,
    provides_collection_import boolean NOT NULL DEFAULT false,
    provides_market_data boolean NOT NULL DEFAULT false,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_external_sources
        PRIMARY KEY (source_id),

    CONSTRAINT uq_external_sources_code
        UNIQUE (source_code),

    CONSTRAINT ck_external_sources_code
        CHECK (source_code ~ '^[A-Z0-9_]+$'),

    CONSTRAINT ck_external_sources_name
        CHECK (btrim(source_name) <> '')
);

INSERT INTO reference.external_sources (
    source_code,
    source_name,
    website_url,
    provides_catalog_data,
    provides_collection_import,
    provides_market_data
)
VALUES
(
    'LEGO',
    'LEGO',
    'https://www.lego.com/',
    true,
    false,
    false
),
(
    'REBRICKABLE',
    'Rebrickable',
    'https://rebrickable.com/',
    true,
    true,
    false
),
(
    'BRICKLINK',
    'BrickLink',
    'https://www.bricklink.com/',
    true,
    true,
    true
),
(
    'BRICKOWL',
    'Brick Owl',
    'https://www.brickowl.com/',
    true,
    true,
    true
),
(
    'STUDIO',
    'BrickLink Studio',
    'https://www.bricklink.com/v3/studio/download.page',
    false,
    true,
    false
);

SELECT app.assert_true(
    (
        SELECT count(*)
        FROM reference.external_sources
        WHERE source_code IN (
            'LEGO',
            'REBRICKABLE',
            'BRICKLINK',
            'BRICKOWL',
            'STUDIO'
        )
    ) = 5,
    'Required external sources were not completely seeded'
);

\echo '[PASS] 0200_external_sources.sql'
SELECT pg_temp.bt_mark_completed('0200_reference/0200_external_sources.sql');
