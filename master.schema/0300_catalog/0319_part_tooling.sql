/*
===============================================================================
 File:           0300_catalog/0319_part_tooling.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Model physical mold/tooling revisions independently from color
                 and decoration variants while preserving existing part variants.
 Depends On:     catalog.parts
                 catalog.part_variants
                 reference.external_sources
 Creates:        catalog.part_molds
                 catalog.part_mold_revisions
                 catalog.part_mold_substitutions
                 catalog.decorated_variants
 Key Rules:      Mold identity and mold revision are distinct.
                 A part variant may optionally resolve to one mold revision.
                 Decoration is modeled separately from physical tooling.
                 Substitution edges cannot self-reference.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0319_part_tooling.sql', ARRAY['catalog.parts', 'catalog.part_variants', 'reference.external_sources']::text[]);



CREATE TABLE catalog.part_molds (
    part_mold_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    part_catalog_item_id uuid NOT NULL
        REFERENCES catalog.parts(catalog_item_id) ON DELETE RESTRICT,
    mold_code text NOT NULL,
    canonical_name text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_part_molds_code CHECK (btrim(mold_code) <> ''),
    CONSTRAINT uq_part_molds_part_code UNIQUE (part_catalog_item_id, mold_code),
    CONSTRAINT uq_part_molds_pair UNIQUE (part_mold_id, part_catalog_item_id)
);

CREATE TABLE catalog.part_mold_revisions (
    part_mold_revision_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    part_mold_id uuid NOT NULL
        REFERENCES catalog.part_molds(part_mold_id) ON DELETE RESTRICT,
    revision_code text NOT NULL,
    source_id smallint
        REFERENCES reference.external_sources(source_id) ON DELETE RESTRICT,
    valid_from date,
    valid_to date,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_part_mold_revisions_code CHECK (btrim(revision_code) <> ''),
    CONSTRAINT ck_part_mold_revisions_dates CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
    CONSTRAINT uq_part_mold_revision_code UNIQUE (part_mold_id, revision_code),
    CONSTRAINT uq_part_mold_revision_pair UNIQUE (part_mold_revision_id, part_mold_id)
);

ALTER TABLE catalog.part_variants
    ADD COLUMN part_mold_revision_id uuid,
    ADD CONSTRAINT fk_part_variants_mold_revision
        FOREIGN KEY (part_mold_revision_id)
        REFERENCES catalog.part_mold_revisions(part_mold_revision_id);

CREATE INDEX ix_part_variants_mold_revision
    ON catalog.part_variants(part_mold_revision_id)
    WHERE part_mold_revision_id IS NOT NULL;

CREATE TABLE catalog.decorated_variants (
    decorated_variant_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    part_variant_id uuid NOT NULL
        REFERENCES catalog.part_variants(part_variant_id) ON DELETE RESTRICT,
    decoration_code text NOT NULL,
    decoration_description text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_decorated_variants_code CHECK (btrim(decoration_code) <> ''),
    CONSTRAINT uq_decorated_variant_code UNIQUE (part_variant_id, decoration_code),
    CONSTRAINT uq_decorated_variant_pair UNIQUE (decorated_variant_id, part_variant_id)
);

CREATE TABLE catalog.part_mold_substitutions (
    substitution_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    from_mold_revision_id uuid NOT NULL
        REFERENCES catalog.part_mold_revisions(part_mold_revision_id) ON DELETE RESTRICT,
    to_mold_revision_id uuid NOT NULL
        REFERENCES catalog.part_mold_revisions(part_mold_revision_id) ON DELETE RESTRICT,
    is_bidirectional boolean NOT NULL DEFAULT false,
    notes text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_part_mold_substitution_self CHECK (from_mold_revision_id <> to_mold_revision_id),
    CONSTRAINT uq_part_mold_substitution UNIQUE (from_mold_revision_id, to_mold_revision_id)
);

CREATE INDEX ix_part_mold_revisions_mold
    ON catalog.part_mold_revisions(part_mold_id);
CREATE INDEX ix_part_mold_substitutions_to
    ON catalog.part_mold_substitutions(to_mold_revision_id);

COMMENT ON TABLE catalog.part_molds IS
    'Physical mold/tool identity for a canonical PART design.';
COMMENT ON TABLE catalog.part_mold_revisions IS
    'Revision history for physical tooling/molds.';
COMMENT ON TABLE catalog.decorated_variants IS
    'Decoration identity separated from physical/color part variants.';
SELECT pg_temp.bt_mark_completed('0300_catalog/0319_part_tooling.sql');
