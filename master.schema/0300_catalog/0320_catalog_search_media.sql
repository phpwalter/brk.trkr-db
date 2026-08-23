/*
===============================================================================
 File:           0300_catalog/0320_catalog_search_media.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Add first-class barcode/media/relationship records and indexed
                 PostgreSQL text-search projections.
 Depends On:     catalog.items
                 reference.external_sources
                 pg_trgm
 Creates:        catalog.barcode_type
                 catalog.item_barcodes
                 catalog.item_images
                 catalog.item_relationships
                 catalog.instruction_assets
                 catalog.item_search
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
           concat_ws(' ', i.canonical_name, i.item_kind::text, i.status::text),
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
AFTER INSERT OR UPDATE OF canonical_name, item_kind, status
ON catalog.items
FOR EACH ROW
EXECUTE FUNCTION catalog.trg_refresh_item_search();

INSERT INTO catalog.item_search(catalog_item_id, search_text)
SELECT catalog_item_id, concat_ws(' ', canonical_name, item_kind::text, status::text)
FROM catalog.items
ON CONFLICT DO NOTHING;

SELECT pg_temp.bt_mark_completed('0300_catalog/0320_catalog_search_media.sql');
