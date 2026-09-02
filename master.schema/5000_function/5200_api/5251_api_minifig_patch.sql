/*
===============================================================================
 File:           5000_function/5200_api/5251_api_minifig_patch.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Preserve RFC 7396 omission semantics for custom-minifigure
                 composition PATCH without destabilizing the shared MOC/minifig
                 mutation dispatcher.
 Depends On:     5000_function/5200_api/5250_api_moc_minifig.sql
                 5000_function/5200_api/5290_api_visibility_reads.sql
                 api.assert_if_match()
                 identity.current_user_id()
                 identity.can_manage_owner()
                 catalog.items
                 definition.custom_minifigs
 Creates:        api.patch_minifig_composition_safe(text,jsonb,text)
 Key Rules:      Omitting "components" is a no-op after authorization and ETag
                 validation. Supplying "components": [] intentionally clears the
                 draft composition. Any supplied components value delegates to
                 the canonical mutation dispatcher. Canonical imported minifigs
                 remain immutable.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5251_api_minifig_patch.sql',
    ARRAY[
        '5000_function/5200_api/5250_api_moc_minifig.sql',
        '5000_function/5200_api/5290_api_visibility_reads.sql',
        'api.assert_if_match()',
        'identity.current_user_id()',
        'identity.can_manage_owner()',
        'catalog.items',
        'definition.custom_minifigs'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.patch_minifig_composition_safe(
    p_item_num text,
    p_patch jsonb,
    p_if_match text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, identity, catalog, definition
AS $$
DECLARE
    v_user_id uuid := identity.current_user_id();
    v_owner_id uuid;
    v_edit_revision bigint;
BEGIN
    IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
        RAISE EXCEPTION 'Minifigure composition patch must be a JSON object'
            USING ERRCODE='22023';
    END IF;

    SELECT cm.owner_id, cm.edit_revision
      INTO v_owner_id, v_edit_revision
      FROM catalog.items i
      JOIN definition.custom_minifigs cm
        ON cm.catalog_item_id = i.catalog_item_id
     WHERE i.item_num = p_item_num
       AND i.item_kind = 'MINIFIGURE'
     FOR UPDATE OF cm;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Custom minifigure not found'
            USING ERRCODE='P0404';
    END IF;

    IF NOT identity.can_manage_owner(v_user_id, v_owner_id, 'MOC') THEN
        RAISE EXCEPTION 'Forbidden'
            USING ERRCODE='P0403';
    END IF;

    PERFORM api.assert_if_match(p_if_match, v_edit_revision);

    IF NOT (p_patch ? 'components') THEN
        RETURN api.visibility_read_operation(
            'get_minifig_composition',
            jsonb_build_object('item_num', p_item_num)
        );
    END IF;

    RETURN api.moc_minifig_operation(
        'patch_minifig_composition',
        jsonb_build_object('item_num', p_item_num),
        p_patch,
        p_if_match
    );
END;
$$;

REVOKE ALL
ON FUNCTION api.patch_minifig_composition_safe(text,jsonb,text)
FROM PUBLIC;

COMMENT ON FUNCTION api.patch_minifig_composition_safe(text,jsonb,text)
IS
'RFC 7396-safe custom-minifigure composition patch. Missing components is an authorized/ETag-validated no-op; explicit components, including an empty array, delegate to the canonical mutation dispatcher.';

SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5251_api_minifig_patch.sql');
\echo '[PASS] 5251_api_minifig_patch.sql'
