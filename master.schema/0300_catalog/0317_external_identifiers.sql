/*
===============================================================================
 File:           0300_catalog/0317_external_identifiers.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Cross-reference external source identities to canonical items
                 and precise part variants.
 Depends On:     reference.external_sources
                 catalog.items
                 catalog.part_variants
 Creates:        catalog.external_identifiers
 Key Rules:      Source IDs such as 1234-1 remain source-specific.
                 External identifiers are mappings/evidence, never primary keys.
                 A mapping targets exactly one catalog item or part variant.
                 Historical source-ID reuse must remain representable.
 Validation:     Enforces target exclusivity, valid chronology, valid source
                 identity structure and uniqueness of active source mappings.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0317_external_identifiers.sql', ARRAY['reference.external_sources', 'catalog.items', 'catalog.part_variants']::text[]);



CREATE TABLE catalog.external_identifiers (
    external_identifier_id uuid NOT NULL DEFAULT app.uuid_v7(),

    source_id smallint NOT NULL,
    entity_namespace text NOT NULL,

    external_id text NOT NULL,
    external_version integer,

    catalog_item_id uuid,
    part_variant_id uuid,

    source_present boolean NOT NULL DEFAULT true,

    valid_from date,
    valid_to date,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_external_identifiers
        PRIMARY KEY (external_identifier_id),

    CONSTRAINT fk_external_identifiers_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT fk_external_identifiers_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_external_identifiers_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT ck_external_identifiers_namespace
        CHECK (entity_namespace ~ '^[A-Z0-9_]+$'),

    CONSTRAINT ck_external_identifiers_id
        CHECK (btrim(external_id) <> ''),

    CONSTRAINT ck_external_identifiers_version
        CHECK (
            external_version IS NULL
            OR external_version > 0
        ),

    CONSTRAINT ck_external_identifiers_target
        CHECK (
            num_nonnulls(
                catalog_item_id,
                part_variant_id
            ) = 1
        ),

    CONSTRAINT ck_external_identifiers_seen
        CHECK (last_seen_at >= first_seen_at),

    CONSTRAINT ck_external_identifiers_validity
        CHECK (
            valid_to IS NULL
            OR valid_from IS NULL
            OR valid_to >= valid_from
        )
);

CREATE UNIQUE INDEX uq_external_identifier_active
    ON catalog.external_identifiers(
        source_id,
        entity_namespace,
        external_id,
        external_version
    )
    NULLS NOT DISTINCT
    WHERE source_present;

CREATE INDEX ix_external_identifiers_item
    ON catalog.external_identifiers(catalog_item_id);

CREATE INDEX ix_external_identifiers_variant
    ON catalog.external_identifiers(part_variant_id);

SELECT app.assert_table_exists('catalog', 'external_identifiers');
SELECT app.assert_index_exists('catalog', 'uq_external_identifier_active');

\echo '[PASS] 0317_external_identifiers.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0317_external_identifiers.sql');
