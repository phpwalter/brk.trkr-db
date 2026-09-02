/*
===============================================================================
 File:           5000_function/5200_api/5221_api_catalog_reference.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Complete public/reference catalog read surface not covered by
                 the original operational API routines.
 Depends On:     reference.colors
                 reference.themes
                 reference.part_categories
                 reference.minifig_roles
                 catalog.items
                 catalog.item_images
                 catalog.external_identifiers
                 catalog.part_variants
                 catalog.lego_elements
                 catalog.part_molds
                 catalog.part_mold_revisions
                 catalog.part_mold_substitutions
                 definition.inventory_definitions
                 definition.inventory_versions
                 definition.requirement_groups
                 definition.requirement_options
                 definition.minifig_compositions
                 definition.minifig_structural_components
                 definition.minifig_accessories
 Creates:        api.catalog_reference_operation()
 Key Rules:      Only public, non-archived catalog identities are enumerable.
                 Source identifiers remain provenance, never public primary keys.
                 The operation selector is controlled by application code and
                 rejects unknown operations.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5221_api_catalog_reference.sql',
    ARRAY[
        'reference.colors',
        'reference.themes',
        'reference.part_categories',
        'reference.minifig_roles',
        'catalog.items',
        'catalog.item_images',
        'catalog.external_identifiers',
        'catalog.part_variants',
        'catalog.lego_elements',
        'catalog.part_molds',
        'catalog.part_mold_revisions',
        'catalog.part_mold_substitutions',
        'definition.inventory_definitions',
        'definition.inventory_versions',
        'definition.requirement_groups',
        'definition.requirement_options',
        'definition.minifig_compositions',
        'definition.minifig_structural_components',
        'definition.minifig_accessories'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.catalog_reference_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, reference, catalog, definition
AS $$
DECLARE
    v_limit integer := LEAST(GREATEST(COALESCE((p_params->>'limit')::integer, 50), 1), 200);
    v_cursor text := NULLIF(p_params->>'cursor', '');
    v_item_num text := NULLIF(p_params->>'item_num', '');
    v_part_num text := NULLIF(p_params->>'part_num', '');
    v_result jsonb;
BEGIN
    CASE p_operation
    WHEN 'list_colors' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.color_id), '[]'::jsonb)
          INTO v_result
          FROM (SELECT * FROM reference.colors ORDER BY color_id LIMIT v_limit) x;

    WHEN 'list_themes' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.theme_id), '[]'::jsonb)
          INTO v_result
          FROM (SELECT * FROM reference.themes ORDER BY theme_id LIMIT v_limit) x;

    WHEN 'list_categories' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
          INTO v_result
          FROM (SELECT * FROM reference.part_categories LIMIT v_limit) x;

    WHEN 'list_minifig_roles' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.minifig_role_id), '[]'::jsonb)
          INTO v_result
          FROM (SELECT * FROM reference.minifig_roles ORDER BY minifig_role_id LIMIT v_limit) x;

    WHEN 'list_catalog_items' THEN
        SELECT jsonb_build_object(
            'items', COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'item_num', i.item_num,
                'name', i.canonical_name,
                'item_kind', i.item_kind::text,
                'status', i.status::text,
                'created_at', i.created_at
            )) ORDER BY i.item_num), '[]'::jsonb),
            'next_cursor', max(i.item_num)
        )
          INTO v_result
          FROM (
              SELECT *
                FROM catalog.items
               WHERE item_num IS NOT NULL
                 AND status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED')
                 AND (v_cursor IS NULL OR item_num > v_cursor)
                 AND (NULLIF(p_params->>'kind','') IS NULL OR item_kind::text = upper(p_params->>'kind'))
                 AND (NULLIF(p_params->>'status','') IS NULL OR status::text = upper(p_params->>'status'))
               ORDER BY item_num
               LIMIT v_limit
          ) i;

    WHEN 'list_catalog_images' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(img) ORDER BY img.is_primary DESC, img.sort_order, img.created_at), '[]'::jsonb)
          INTO v_result
          FROM catalog.items i
          JOIN catalog.item_images img USING (catalog_item_id)
         WHERE i.item_num = v_item_num
           AND i.status <> 'ARCHIVED';

    WHEN 'list_catalog_sources' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'source_id', ei.source_id,
            'external_id', ei.external_id,
            'external_version', ei.external_version,
            'source_present', ei.source_present,
            'first_seen_at', ei.first_seen_at,
            'last_seen_at', ei.last_seen_at
        ) ORDER BY ei.source_id, ei.external_id), '[]'::jsonb)
          INTO v_result
          FROM catalog.items i
          JOIN catalog.external_identifiers ei USING (catalog_item_id)
         WHERE i.item_num = v_item_num;

    WHEN 'list_part_variants' THEN
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'part_variant_id', pv.part_variant_id,
            'color_id', pv.color_id,
            'decoration_code', pv.decoration_code,
            'mold_code', pv.mold_code,
            'part_mold_revision_id', pv.part_mold_revision_id,
            'is_printed', pv.is_printed,
            'is_stickered', pv.is_stickered
        )) ORDER BY pv.color_id NULLS LAST, pv.part_variant_id), '[]'::jsonb)
          INTO v_result
          FROM catalog.items i
          JOIN catalog.part_variants pv ON pv.part_catalog_item_id = i.catalog_item_id
         WHERE i.item_num = v_part_num
           AND i.item_kind = 'PART';

    WHEN 'list_part_elements' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'lego_element_id', le.lego_element_id,
            'part_variant_id', le.part_variant_id,
            'valid_from', le.valid_from,
            'valid_to', le.valid_to,
            'notes', le.notes
        ) ORDER BY le.lego_element_id), '[]'::jsonb)
          INTO v_result
          FROM catalog.items i
          JOIN catalog.part_variants pv ON pv.part_catalog_item_id = i.catalog_item_id
          JOIN catalog.lego_elements le USING (part_variant_id)
         WHERE i.item_num = v_part_num
           AND i.item_kind = 'PART';

    WHEN 'list_part_relationships' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'substitution_id', s.substitution_id,
            'from_mold_revision_id', s.from_mold_revision_id,
            'to_mold_revision_id', s.to_mold_revision_id,
            'is_bidirectional', s.is_bidirectional,
            'notes', s.notes
        ) ORDER BY s.substitution_id), '[]'::jsonb)
          INTO v_result
          FROM catalog.items i
          JOIN catalog.part_molds pm ON pm.part_catalog_item_id = i.catalog_item_id
          JOIN catalog.part_mold_revisions mr ON mr.part_mold_id = pm.part_mold_id
          JOIN catalog.part_mold_substitutions s
            ON s.from_mold_revision_id = mr.part_mold_revision_id
            OR s.to_mold_revision_id = mr.part_mold_revision_id
         WHERE i.item_num = v_part_num
           AND i.item_kind = 'PART';

    WHEN 'list_minifig_sets' THEN
        SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
            'item_num', si.item_num,
            'name', si.canonical_name,
            'item_kind', 'SET'
        )), '[]'::jsonb)
          INTO v_result
          FROM catalog.items mi
          JOIN definition.requirement_options o ON o.catalog_item_id = mi.catalog_item_id
          JOIN definition.requirement_groups g USING (requirement_group_id)
          JOIN definition.inventory_versions iv USING (inventory_version_id)
          JOIN definition.inventory_definitions d USING (inventory_definition_id)
          JOIN catalog.items si ON si.catalog_item_id = d.catalog_item_id
         WHERE mi.item_num = v_item_num
           AND mi.item_kind = 'MINIFIGURE'
           AND si.item_kind = 'SET'
           AND iv.status = 'FINALIZED';

    WHEN 'list_minifig_parts' THEN
        WITH target AS (
            SELECT d.inventory_definition_id
              FROM catalog.items i
              JOIN definition.inventory_definitions d USING (catalog_item_id)
             WHERE i.item_num = v_item_num
               AND i.item_kind = 'MINIFIGURE'
               AND d.definition_kind = 'MINIFIG_COMPOSITION'
        ), chosen AS (
            SELECT COALESCE(
                definition.effective_inventory_version(t.inventory_definition_id),
                (SELECT v.inventory_version_id FROM definition.inventory_versions v
                  WHERE v.inventory_definition_id = t.inventory_definition_id
                    AND v.status = 'FINALIZED'
                  ORDER BY v.semantic_version DESC LIMIT 1)
            ) inventory_version_id
            FROM target t
        ), composition AS (
            SELECT mc.minifig_composition_id
              FROM chosen c
              JOIN definition.minifig_compositions mc USING (inventory_version_id)
        ), rows AS (
            SELECT 'STRUCTURAL'::text kind, sc.semantic_role role, sc.side,
                   sc.position_index, sc.part_variant_id, sc.decorated_variant_id,
                   sc.quantity
              FROM composition c
              JOIN definition.minifig_structural_components sc USING (minifig_composition_id)
            UNION ALL
            SELECT 'ACCESSORY', 'ACCESSORY', NULL, a.position_index,
                   a.part_variant_id, NULL, a.quantity
              FROM composition c
              JOIN definition.minifig_accessories a USING (minifig_composition_id)
        )
        SELECT COALESCE(jsonb_agg(to_jsonb(rows) ORDER BY kind, position_index), '[]'::jsonb)
          INTO v_result FROM rows;

    ELSE
        RAISE EXCEPTION 'Unknown catalog/reference API operation: %', p_operation
            USING ERRCODE = '22023';
    END CASE;

    RETURN COALESCE(v_result, 'null'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.catalog_reference_operation(text,jsonb) FROM PUBLIC;

\echo '[PASS] 5221_api_catalog_reference.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5221_api_catalog_reference.sql');
