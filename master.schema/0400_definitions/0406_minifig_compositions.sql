/*
===============================================================================
 File:           0400_definitions/0406_minifig_compositions.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Provide versioned, topology-neutral structural composition for
                 minifigures and other character-like catalog objects.
 Depends On:     definition.inventory_versions
                 catalog.part_variants
                 catalog.decorated_variants
                 reference.minifig_roles
 Creates:        definition.minifig_compositions
                 definition.minifig_structural_components
                 definition.minifig_accessories
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0400_definitions/0406_minifig_compositions.sql', ARRAY['definition.inventory_versions', 'catalog.part_variants', 'catalog.decorated_variants', 'reference.minifig_roles']::text[]);



CREATE TABLE definition.minifig_compositions (
    minifig_composition_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    inventory_version_id uuid NOT NULL UNIQUE
        REFERENCES definition.inventory_versions(inventory_version_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE definition.minifig_structural_components (
    minifig_component_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    minifig_composition_id uuid NOT NULL
        REFERENCES definition.minifig_compositions(minifig_composition_id) ON DELETE CASCADE,
    minifig_role_id integer
        REFERENCES reference.minifig_roles(minifig_role_id) ON DELETE RESTRICT,
    semantic_role text NOT NULL,
    side text,
    position_index integer NOT NULL DEFAULT 0,
    part_variant_id uuid NOT NULL,
    decorated_variant_id uuid,
    quantity app.whole_quantity NOT NULL DEFAULT 1,
    CONSTRAINT ck_minifig_component_role CHECK (btrim(semantic_role) <> ''),
    CONSTRAINT ck_minifig_component_position CHECK (position_index >= 0),
    CONSTRAINT fk_minifig_component_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_minifig_component_decoration
        FOREIGN KEY (decorated_variant_id, part_variant_id)
        REFERENCES catalog.decorated_variants(decorated_variant_id, part_variant_id)
        ON DELETE RESTRICT
);
CREATE INDEX ix_minifig_components_composition
    ON definition.minifig_structural_components(minifig_composition_id);

CREATE TABLE definition.minifig_accessories (
    minifig_accessory_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    minifig_composition_id uuid NOT NULL
        REFERENCES definition.minifig_compositions(minifig_composition_id) ON DELETE CASCADE,
    part_variant_id uuid NOT NULL
        REFERENCES catalog.part_variants(part_variant_id) ON DELETE RESTRICT,
    quantity app.whole_quantity NOT NULL DEFAULT 1,
    position_index integer NOT NULL DEFAULT 0,
    CONSTRAINT ck_minifig_accessory_position CHECK (position_index >= 0)
);
CREATE INDEX ix_minifig_accessories_composition
    ON definition.minifig_accessories(minifig_composition_id);
SELECT pg_temp.bt_mark_completed('0400_definitions/0406_minifig_compositions.sql');
