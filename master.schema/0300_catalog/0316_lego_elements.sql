/*
===============================================================================
 File:           0300_catalog/0316_lego_elements.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Track historical LEGO element identifiers mapped to part
                 variants.
 Depends On:     catalog.part_variants
 Creates:        catalog.lego_elements
 Key Rules:      LEGO element IDs are business/source identities, not primary
                 keys.
                 An element ID is not assumed globally unique for all history.
                 Historical mappings remain queryable.
 Validation:     Enforces positive element IDs and valid optional date ranges.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0316_lego_elements.sql', ARRAY['catalog.part_variants']::text[]);



CREATE TABLE catalog.lego_elements (
    lego_element_row_id uuid NOT NULL DEFAULT app.uuid_v7(),

    lego_element_id BIGINT NOT NULL,
    part_variant_id uuid NOT NULL,

    valid_from date,
    valid_to date,

    notes text,

    CONSTRAINT pk_lego_elements
        PRIMARY KEY (lego_element_row_id),

    CONSTRAINT fk_lego_elements_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT ck_lego_elements_id
        CHECK (lego_element_id > 0),

    CONSTRAINT ck_lego_elements_dates
        CHECK (
            valid_to IS NULL
            OR valid_from IS NULL
            OR valid_to >= valid_from
        )
);

CREATE INDEX ix_lego_elements_id
    ON catalog.lego_elements(lego_element_id);

CREATE INDEX ix_lego_elements_variant
    ON catalog.lego_elements(part_variant_id);

SELECT app.assert_table_exists('catalog', 'lego_elements');

\echo '[PASS] 0316_lego_elements.sql'

/* Phase 4: source replays may only reuse the same element/variant identity. */
CREATE UNIQUE INDEX IF NOT EXISTS uq_lego_elements_id_variant
    ON catalog.lego_elements(lego_element_id, part_variant_id);

SELECT pg_temp.bt_mark_completed('0300_catalog/0316_lego_elements.sql');
