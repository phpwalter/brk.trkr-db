/*
===============================================================================
 File:           1100_security/1108_rls_catalog_definition.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Prevent owner-private UNRESOLVED_CUSTOM catalog records and
                 their subtype/definition graph from leaking through direct
                 application SELECT access.
 Depends On:     Complete 0300_catalog domain
                 Complete 0400_definitions domain
                 identity.current_user_id()
                 identity.can_view_owner()
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1108_rls_catalog_definition.sql', ARRAY['Complete 0300_catalog domain', 'Complete 0400_definitions domain', 'identity.current_user_id()', 'identity.can_view_owner()']::text[]);



/* Catalog */
ALTER TABLE catalog.items ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.parts ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.minifigures ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.books ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.mocs ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.sticker_sheets ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.instructions ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.packaging ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.gear ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.accessories ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.polybags ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.promotional_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.publications ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.other_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.part_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.lego_elements ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.external_identifiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.source_values ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.source_value_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.admin_overrides ENABLE ROW LEVEL SECURITY;

/* Definition graph */
ALTER TABLE definition.inventory_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.inventory_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.requirement_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.requirement_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.definition_authority ENABLE ROW LEVEL SECURITY;


/* Root catalog visibility. */
CREATE POLICY pol_catalog_items_select
ON catalog.items
FOR SELECT
USING (
    status <> 'UNRESOLVED_CUSTOM'
    OR identity.can_view_owner(
        identity.current_user_id(),
        unresolved_owner_id,
        'COLLECTION'
    )
);


/* Simple subtype tables: their catalog_item_id must be visible in catalog.items. */
CREATE POLICY pol_catalog_sets_select ON catalog.sets
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.sets.catalog_item_id
    )
);

CREATE POLICY pol_catalog_parts_select ON catalog.parts
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.parts.catalog_item_id
    )
);

CREATE POLICY pol_catalog_minifigures_select ON catalog.minifigures
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.minifigures.catalog_item_id
    )
);

CREATE POLICY pol_catalog_books_select ON catalog.books
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.books.catalog_item_id
    )
);

CREATE POLICY pol_catalog_moc_subtype_select ON catalog.mocs
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.mocs.catalog_item_id
    )
);

CREATE POLICY pol_catalog_sticker_sheets_select ON catalog.sticker_sheets
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.sticker_sheets.catalog_item_id
    )
);

CREATE POLICY pol_catalog_instructions_select ON catalog.instructions
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.instructions.catalog_item_id
    )
);

CREATE POLICY pol_catalog_packaging_select ON catalog.packaging
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.packaging.catalog_item_id
    )
);

CREATE POLICY pol_catalog_gear_select ON catalog.gear
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.gear.catalog_item_id
    )
);

CREATE POLICY pol_catalog_accessories_select ON catalog.accessories
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.accessories.catalog_item_id
    )
);

CREATE POLICY pol_catalog_polybags_select ON catalog.polybags
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.polybags.catalog_item_id
    )
);

CREATE POLICY pol_catalog_promotional_items_select ON catalog.promotional_items
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.promotional_items.catalog_item_id
    )
);

CREATE POLICY pol_catalog_publications_select ON catalog.publications
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.publications.catalog_item_id
    )
);

CREATE POLICY pol_catalog_other_items_select ON catalog.other_items
FOR SELECT USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.other_items.catalog_item_id
    )
);


/* Part-derived records. */
CREATE POLICY pol_part_variants_select
ON catalog.part_variants
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM catalog.parts p
        WHERE p.catalog_item_id =
              catalog.part_variants.part_catalog_item_id
    )
);

CREATE POLICY pol_lego_elements_select
ON catalog.lego_elements
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM catalog.part_variants pv
        WHERE pv.part_variant_id =
              catalog.lego_elements.part_variant_id
    )
);


/* External identifiers may target either a catalog item or a part variant. */
CREATE POLICY pol_external_identifiers_select
ON catalog.external_identifiers
FOR SELECT
USING (
    (
        catalog_item_id IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM catalog.items i
            WHERE i.catalog_item_id =
                  catalog.external_identifiers.catalog_item_id
        )
    )
    OR
    (
        part_variant_id IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM catalog.part_variants pv
            WHERE pv.part_variant_id =
                  catalog.external_identifiers.part_variant_id
        )
    )
);


/* Catalog authority metadata inherits its catalog item. */
CREATE POLICY pol_source_values_select
ON catalog.source_values
FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.source_values.catalog_item_id
    )
);

CREATE POLICY pol_source_value_history_select
ON catalog.source_value_history
FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.source_value_history.catalog_item_id
    )
);

CREATE POLICY pol_admin_overrides_select
ON catalog.admin_overrides
FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM catalog.items i
        WHERE i.catalog_item_id = catalog.admin_overrides.catalog_item_id
    )
);


/* Definition graph inherits catalog visibility. */
CREATE POLICY pol_inventory_definitions_select
ON definition.inventory_definitions
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM catalog.items i
        WHERE i.catalog_item_id =
              definition.inventory_definitions.catalog_item_id
    )
);

CREATE POLICY pol_inventory_versions_select
ON definition.inventory_versions
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM definition.inventory_definitions d
        WHERE d.inventory_definition_id =
              definition.inventory_versions.inventory_definition_id
    )
);

CREATE POLICY pol_requirement_groups_select
ON definition.requirement_groups
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM definition.inventory_versions v
        WHERE v.inventory_version_id =
              definition.requirement_groups.inventory_version_id
    )
);

CREATE POLICY pol_requirement_options_select
ON definition.requirement_options
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM definition.requirement_groups g
        WHERE g.requirement_group_id =
              definition.requirement_options.requirement_group_id
    )
);

CREATE POLICY pol_definition_authority_select
ON definition.definition_authority
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM definition.inventory_definitions d
        WHERE d.inventory_definition_id =
              definition.definition_authority.inventory_definition_id
    )
);

\echo '[PASS] 1108_rls_catalog_definition.sql'


/* Integrated catalog extensions */
ALTER TABLE catalog.part_molds ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.part_mold_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.part_mold_substitutions ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.decorated_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.item_barcodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.item_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.item_relationships ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.instruction_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.item_search ENABLE ROW LEVEL SECURITY;

CREATE POLICY pol_part_molds_select ON catalog.part_molds
FOR SELECT USING (
    EXISTS (SELECT 1 FROM catalog.parts p
            WHERE p.catalog_item_id = catalog.part_molds.part_catalog_item_id)
);

CREATE POLICY pol_part_mold_revisions_select ON catalog.part_mold_revisions
FOR SELECT USING (
    EXISTS (SELECT 1 FROM catalog.part_molds pm
            WHERE pm.part_mold_id = catalog.part_mold_revisions.part_mold_id)
);

CREATE POLICY pol_part_mold_substitutions_select ON catalog.part_mold_substitutions
FOR SELECT USING (
    EXISTS (SELECT 1 FROM catalog.part_mold_revisions r
            WHERE r.part_mold_revision_id = catalog.part_mold_substitutions.from_mold_revision_id)
    AND EXISTS (SELECT 1 FROM catalog.part_mold_revisions r
                WHERE r.part_mold_revision_id = catalog.part_mold_substitutions.to_mold_revision_id)
);

CREATE POLICY pol_decorated_variants_select ON catalog.decorated_variants
FOR SELECT USING (
    EXISTS (SELECT 1 FROM catalog.part_variants pv
            WHERE pv.part_variant_id = catalog.decorated_variants.part_variant_id)
);

CREATE POLICY pol_item_barcodes_select ON catalog.item_barcodes
FOR SELECT USING (
    EXISTS (SELECT 1 FROM catalog.items i
            WHERE i.catalog_item_id = catalog.item_barcodes.catalog_item_id)
);

CREATE POLICY pol_item_images_select ON catalog.item_images
FOR SELECT USING (
    EXISTS (SELECT 1 FROM catalog.items i
            WHERE i.catalog_item_id = catalog.item_images.catalog_item_id)
);

CREATE POLICY pol_item_relationships_select ON catalog.item_relationships
FOR SELECT USING (
    EXISTS (SELECT 1 FROM catalog.items i
            WHERE i.catalog_item_id = catalog.item_relationships.from_catalog_item_id)
    AND EXISTS (SELECT 1 FROM catalog.items i
                WHERE i.catalog_item_id = catalog.item_relationships.to_catalog_item_id)
);


CREATE POLICY pol_instruction_assets_select ON catalog.instruction_assets
FOR SELECT USING (
    EXISTS (
        SELECT 1
        FROM catalog.instructions ci
        WHERE ci.catalog_item_id = catalog.instruction_assets.instruction_catalog_item_id
    )
);

CREATE POLICY pol_item_search_select ON catalog.item_search
FOR SELECT USING (
    EXISTS (SELECT 1 FROM catalog.items i
            WHERE i.catalog_item_id = catalog.item_search.catalog_item_id)
);

/* Integrated definition extensions inherit version visibility. */
ALTER TABLE definition.manifest_subassemblies ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.manifest_requirement_placements ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.minifig_compositions ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.minifig_structural_components ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.minifig_accessories ENABLE ROW LEVEL SECURITY;

CREATE POLICY pol_manifest_subassemblies_select ON definition.manifest_subassemblies
FOR SELECT USING (
    EXISTS (SELECT 1 FROM definition.inventory_versions v
            WHERE v.inventory_version_id = definition.manifest_subassemblies.inventory_version_id)
);

CREATE POLICY pol_manifest_requirement_placements_select ON definition.manifest_requirement_placements
FOR SELECT USING (
    EXISTS (SELECT 1 FROM definition.inventory_versions v
            WHERE v.inventory_version_id = definition.manifest_requirement_placements.inventory_version_id)
);

CREATE POLICY pol_minifig_compositions_select ON definition.minifig_compositions
FOR SELECT USING (
    EXISTS (SELECT 1 FROM definition.inventory_versions v
            WHERE v.inventory_version_id = definition.minifig_compositions.inventory_version_id)
);

CREATE POLICY pol_minifig_structural_components_select ON definition.minifig_structural_components
FOR SELECT USING (
    EXISTS (
        SELECT 1
        FROM definition.minifig_compositions c
        WHERE c.minifig_composition_id =
              definition.minifig_structural_components.minifig_composition_id
    )
);

CREATE POLICY pol_minifig_accessories_select ON definition.minifig_accessories
FOR SELECT USING (
    EXISTS (
        SELECT 1
        FROM definition.minifig_compositions c
        WHERE c.minifig_composition_id =
              definition.minifig_accessories.minifig_composition_id
    )
);
SELECT pg_temp.bt_mark_completed('1100_security/1108_rls_catalog_definition.sql');
