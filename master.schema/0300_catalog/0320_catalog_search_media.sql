/*
===============================================================================
 File:           0300_catalog/0320_catalog_search_media.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.2.0
 PostgreSQL:     16+
 Purpose:        Add first-class barcode/media/relationship records, stable
                 public-source identity assignment, and indexed PostgreSQL
                 text-search projections.
 Depends On:     catalog.items
                 reference.external_sources
                 pg_trgm
 Creates:        catalog.barcode_type
                 catalog.item_barcodes
                 catalog.item_images
                 catalog.item_relationships
                 catalog.instruction_assets
                 catalog.item_search
                 catalog.trg_assign_public_item_num()
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0320_catalog_search_media.sql', ARRAY['catalog.items', 'reference.external_sources', 'pg_trgm']::text[]);

CREATE TYPE catalog.barcode_type AS ENUM ('UPC_A', 'UPC_E', 'EAN_8', 'EAN_13', 'ISBN_10', 'ISBN_13', 'OTHER');
CREATE TYPE catalog.relationship_kind AS ENUM (
    'RELATED', 'REPLACEMENT', 'SUCCESSOR', 'PREDECESSOR', 'CONTAINS', 'ALTERNATE', 'BUNDLE'
);

CREATE TABLE catalog.item_barcodes (
    catalog_item_barcode_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    catalog_item_id uuid NOT NULL REFERENCES catalog.items(catalog_item_id) ON DELETE CASCADE,
    barcode_type catalog.barcode_type NOT NULL,
    barcode_value text NOT NULL,
    source_id smallint REFERENCES reference.external_sources(source_id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_item_barcodes_value CHECK (barcode_value ~ '^[0-9A-Za-z._:-]+$'),
    CONSTRAINT uq_item_barcodes_value UNIQUE (barcode_type, barcode_value)
);

CREATE TABLE catalog.item_images (
    catalog_item_image_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    catalog_item_id uuid NOT NULL REFERENCES catalog.items(catalog_item_id) ON DELETE CASCADE,
    storage_key text NOT NULL,
    alt_text text,
    is_primary boolean NOT NULL DEFAULT false,
    sort_order integer NOT NULL DEFAULT 0,
    sha256 app.sha256_digest,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_item_images_storage_key CHECK (btrim(storage_key) <> ''),
    CONSTRAINT ck_item_images_sort CHECK (sort_order >= 0),
    CONSTRAINT uq_item_images_storage_key UNIQUE (storage_key)
);
CREATE UNIQUE INDEX uq_item_images_one_primary
    ON catalog.item_images(catalog_item_id)
    WHERE is_primary;

CREATE TABLE catalog.instruction_assets (
    instruction_asset_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    instruction_catalog_item_id uuid NOT NULL
        REFERENCES catalog.instructions(catalog_item_id) ON DELETE CASCADE,
    storage_key text NOT NULL UNIQUE,
    language_code varchar(10),
    booklet_number smallint,
    sha256 app.sha256_digest,
    page_count integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_instruction_asset_language CHECK (
        language_code IS NULL OR btrim(language_code) <> ''
    ),
    CONSTRAINT ck_instruction_asset_booklet CHECK (
        booklet_number IS NULL OR booklet_number > 0
    ),
    CONSTRAINT ck_instruction_asset_pages CHECK (
        page_count IS NULL OR page_count > 0
    )
);
CREATE INDEX ix_instruction_assets_instruction
    ON catalog.instruction_assets(instruction_catalog_item_id);

CREATE TABLE catalog.item_relationships (
    catalog_item_relationship_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    from_catalog_item_id uuid NOT NULL REFERENCES catalog.items(catalog_item_id) ON DELETE CASCADE,
    to_catalog_item_id uuid NOT NULL REFERENCES catalog.items(catalog_item_id) ON DELETE CASCADE,
    relationship_kind catalog.relationship_kind NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_item_relationship_self CHECK (from_catalog_item_id <> to_catalog_item_id),
    CONSTRAINT uq_item_relationship UNIQUE (from_catalog_item_id, to_catalog_item_id, relationship_kind)
);
CREATE INDEX ix_item_relationships_to
    ON catalog.item_relationships(to_catalog_item_id, relationship_kind);

/*
 * Public catalog identity is independent from the UUID primary key. Canonical
 * imported SET/PART/MINIFIGURE rows adopt the stable Rebrickable external ID as
 * their initial BrickTrackr item_num. Once assigned, item_num is never changed
 * by later source remapping.
 */
CREATE OR REPLACE FUNCTION catalog.trg_assign_public_item_num()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog, reference
AS $$
DECLARE
    v_source_code text;
    v_kind catalog.item_kind;
BEGIN
    IF NEW.catalog_item_id IS NULL OR NOT NEW.source_present THEN
        RETURN NEW;
    END IF;

    SELECT source_code
      INTO v_source_code
      FROM reference.external_sources
     WHERE source_id = NEW.source_id;

    IF v_source_code <> 'REBRICKABLE'
       OR NEW.entity_namespace NOT IN ('SET', 'PART', 'MINIFIGURE')
    THEN
        RETURN NEW;
    END IF;

    SELECT item_kind
      INTO v_kind
      FROM catalog.items
     WHERE catalog_item_id = NEW.catalog_item_id;

    IF v_kind::text <> NEW.entity_namespace THEN
        RETURN NEW;
    END IF;

    UPDATE catalog.items
       SET item_num = NEW.external_id
     WHERE catalog_item_id = NEW.catalog_item_id
       AND item_num IS NULL;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_external_identifier_assign_public_item_num
AFTER INSERT OR UPDATE OF external_id, catalog_item_id, source_present
ON catalog.external_identifiers
FOR EACH ROW
EXECUTE FUNCTION catalog.trg_assign_public_item_num();

WITH preferred AS (
    SELECT
        ei.catalog_item_id,
        ei.external_id,
        row_number() OVER (
            PARTITION BY ei.catalog_item_id
            ORDER BY
                CASE es.source_code
                    WHEN 'REBRICKABLE' THEN 1
                    WHEN 'BRICKLINK' THEN 2
                    WHEN 'BRICKOWL' THEN 3
                    WHEN 'LEGO' THEN 4
                    ELSE 100
                END,
                ei.first_seen_at,
                ei.external_identifier_id
        ) AS rn
    FROM catalog.external_identifiers ei
    JOIN reference.external_sources es
      ON es.source_id = ei.source_id
    JOIN catalog.items i
      ON i.catalog_item_id = ei.catalog_item_id
    WHERE ei.source_present
      AND ei.catalog_item_id IS NOT NULL
      AND i.item_kind IN ('SET', 'PART', 'MINIFIGURE')
      AND ei.entity_namespace = i.item_kind::text
)
UPDATE catalog.items i
   SET item_num = p.external_id
  FROM preferred p
 WHERE p.catalog_item_id = i.catalog_item_id
   AND p.rn = 1
   AND i.item_num IS NULL;

CREATE TABLE catalog.item_search (
    catalog_item_id uuid PRIMARY KEY REFERENCES catalog.items(catalog_item_id) ON DELETE CASCADE,
    search_text text NOT NULL,
    search_document tsvector GENERATED ALWAYS AS (to_tsvector('simple', search_text)) STORED,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_item_search_text CHECK (btrim(search_text) <> '')
);
CREATE INDEX ix_item_search_document ON catalog.item_search USING GIN(search_document);
CREATE INDEX ix_item_search_trgm ON catalog.item_search USING GIN(search_text gin_trgm_ops);

CREATE OR REPLACE FUNCTION catalog.refresh_item_search(p_catalog_item_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
    INSERT INTO catalog.item_search(catalog_item_id, search_text, refreshed_at)
    SELECT i.catalog_item_id,
           concat_ws(' ', i.item_num, i.canonical_name, i.item_kind::text, i.status::text),
           now()
    FROM catalog.items i
    WHERE i.catalog_item_id = p_catalog_item_id
    ON CONFLICT (catalog_item_id)
    DO UPDATE SET search_text = EXCLUDED.search_text,
                  refreshed_at = EXCLUDED.refreshed_at;
$$;

CREATE OR REPLACE FUNCTION catalog.trg_refresh_item_search()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
BEGIN
    PERFORM catalog.refresh_item_search(NEW.catalog_item_id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_catalog_items_search
AFTER INSERT OR UPDATE OF item_num, canonical_name, item_kind, status
ON catalog.items
FOR EACH ROW
EXECUTE FUNCTION catalog.trg_refresh_item_search();

INSERT INTO catalog.item_search(catalog_item_id, search_text)
SELECT catalog_item_id, concat_ws(' ', item_num, canonical_name, item_kind::text, status::text)
FROM catalog.items
ON CONFLICT DO NOTHING;

SELECT pg_temp.bt_mark_completed('0300_catalog/0320_catalog_search_media.sql');
