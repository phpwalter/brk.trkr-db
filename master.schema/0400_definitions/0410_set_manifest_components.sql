/*
===============================================================================
 File:           0400_definitions/0410_set_manifest_components.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Persist source-backed SET manifest components for stickers,
                 instructions and packaging.
 Depends On:     0300_catalog/0300_catalog_items.sql
                 0000_bootstrap/0003_uuid.sql
 Creates:        definition.set_manifest_components
 Key Rules:      Evidence is source-backed and linked to a canonical SET.
                 Importer receives no direct table DML.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0400_definitions/0410_set_manifest_components.sql', ARRAY['0300_catalog/0300_catalog_items.sql', '0000_bootstrap/0003_uuid.sql']::text[]);

CREATE TABLE IF NOT EXISTS definition.set_manifest_components (
    set_manifest_component_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),

    set_catalog_item_id uuid NOT NULL
        REFERENCES catalog.items(catalog_item_id)
        ON DELETE RESTRICT,

    component_kind catalog.item_kind NOT NULL,

    component_catalog_item_id uuid
        REFERENCES catalog.items(catalog_item_id)
        ON DELETE RESTRICT,

    source_code text NOT NULL,
    external_id text NOT NULL,
    display_name text,
    source_url text,

    quantity integer NOT NULL DEFAULT 1,
    source_present boolean NOT NULL DEFAULT true,
    source_payload jsonb NOT NULL DEFAULT '{}'::jsonb,

    first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT ck_set_manifest_components_kind
        CHECK (
            component_kind IN (
                'STICKER_SHEET'::catalog.item_kind,
                'INSTRUCTIONS'::catalog.item_kind,
                'PACKAGING'::catalog.item_kind
            )
        ),

    CONSTRAINT ck_set_manifest_components_source_code
        CHECK (btrim(source_code) <> ''),

    CONSTRAINT ck_set_manifest_components_external_id
        CHECK (btrim(external_id) <> ''),

    CONSTRAINT ck_set_manifest_components_quantity
        CHECK (quantity > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_set_manifest_components_source_identity
    ON definition.set_manifest_components (
        set_catalog_item_id,
        component_kind,
        source_code,
        external_id
    );

CREATE INDEX IF NOT EXISTS ix_set_manifest_components_set
    ON definition.set_manifest_components (
        set_catalog_item_id,
        component_kind
    );

REVOKE ALL ON TABLE definition.set_manifest_components FROM PUBLIC;
REVOKE ALL ON TABLE definition.set_manifest_components
    FROM lego_api, lego_app, lego_admin, lego_importer, lego_reporting;

COMMENT ON TABLE definition.set_manifest_components IS
    'Source-backed SET manifest evidence for STICKER_SHEET, INSTRUCTIONS, and PACKAGING. Canonical mutation is through importer routines only.';

REVOKE ALL ON TABLE definition.set_manifest_components FROM PUBLIC;

SELECT pg_temp.bt_mark_completed('0400_definitions/0410_set_manifest_components.sql');
