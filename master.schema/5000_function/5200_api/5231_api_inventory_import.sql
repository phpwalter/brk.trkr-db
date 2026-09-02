/*
===============================================================================
 File:           5000_function/5200_api/5231_api_inventory_import.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Import API-normalized inventory rows transactionally while
                 resolving part_num/color_id inputs to one exact base part
                 variant before collection ownership is created.
 Depends On:     5000_function/5200_api/5230_api_collection_inventory.sql
                 identity.current_user_id()
                 catalog.items
                 catalog.parts
                 catalog.part_variants
 Creates:        api.import_inventory_normalized(jsonb)
 Key Rules:      Each input row identifies exactly one catalog item, explicit
                 part_variant_id, or part_num. part_num inputs resolve only to
                 non-decorated/non-mold-specific base variants. color_id narrows
                 the resolution when supplied. Zero or multiple candidate
                 variants fail closed; import never guesses. All rows execute in
                 the caller's single PostgreSQL transaction and owner/RLS checks
                 are delegated to the canonical collection dispatcher.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5231_api_inventory_import.sql',
    ARRAY[
        '5000_function/5200_api/5230_api_collection_inventory.sql',
        'identity.current_user_id()',
        'catalog.items',
        'catalog.parts',
        'catalog.part_variants'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.import_inventory_normalized(
    p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, identity, catalog
AS $$
DECLARE
    v_user_id uuid := identity.current_user_id();
    v_row record;
    v_body jsonb;
    v_part_catalog_item_id uuid;
    v_part_variant_id uuid;
    v_candidate_count integer;
    v_imported integer := 0;
    v_results jsonb := '[]'::jsonb;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authenticated user context is required'
            USING ERRCODE='42501';
    END IF;

    IF p_payload IS NULL
       OR jsonb_typeof(p_payload) <> 'object'
       OR jsonb_typeof(p_payload->'items') <> 'array' THEN
        RAISE EXCEPTION 'Normalized inventory payload must contain an items array'
            USING ERRCODE='22023';
    END IF;

    IF jsonb_array_length(p_payload->'items') = 0 THEN
        RAISE EXCEPTION 'Normalized inventory payload contains no items'
            USING ERRCODE='22023';
    END IF;

    IF jsonb_array_length(p_payload->'items') > 100000 THEN
        RAISE EXCEPTION 'Normalized inventory payload exceeds 100000 items'
            USING ERRCODE='22023';
    END IF;

    FOR v_row IN
        SELECT value, ordinality
        FROM jsonb_array_elements(p_payload->'items') WITH ORDINALITY
    LOOP
        v_body := v_row.value;

        IF jsonb_typeof(v_body) <> 'object' THEN
            RAISE EXCEPTION 'Normalized inventory item % must be an object', v_row.ordinality
                USING ERRCODE='22023';
        END IF;

        IF NULLIF(v_body->>'part_num','') IS NOT NULL THEN
            IF NULLIF(v_body->>'item_num','') IS NOT NULL
               OR NULLIF(v_body->>'part_variant_id','') IS NOT NULL THEN
                RAISE EXCEPTION
                    'Normalized inventory item % contains conflicting target identifiers',
                    v_row.ordinality
                    USING ERRCODE='22023';
            END IF;

            SELECT i.catalog_item_id
              INTO v_part_catalog_item_id
              FROM catalog.items i
              JOIN catalog.parts p
                ON p.catalog_item_id = i.catalog_item_id
             WHERE i.item_num = v_body->>'part_num'
               AND i.item_kind = 'PART'
               AND i.status <> 'ARCHIVED';

            IF v_part_catalog_item_id IS NULL THEN
                RAISE EXCEPTION
                    'Part % from normalized inventory item % was not found',
                    v_body->>'part_num',
                    v_row.ordinality
                    USING ERRCODE='P0404';
            END IF;

            SELECT count(*), min(pv.part_variant_id)
              INTO v_candidate_count, v_part_variant_id
              FROM catalog.part_variants pv
             WHERE pv.part_catalog_item_id = v_part_catalog_item_id
               AND pv.decoration_code IS NULL
               AND pv.mold_code IS NULL
               AND NOT pv.is_printed
               AND NOT pv.is_stickered
               AND (
                    NULLIF(v_body->>'color_id','') IS NULL
                    OR pv.color_id = (v_body->>'color_id')::integer
               );

            IF v_candidate_count = 0 THEN
                RAISE EXCEPTION
                    'No base part variant resolves part % color % for normalized inventory item %',
                    v_body->>'part_num',
                    COALESCE(v_body->>'color_id','<unspecified>'),
                    v_row.ordinality
                    USING ERRCODE='P0404';
            END IF;

            IF v_candidate_count > 1 THEN
                RAISE EXCEPTION
                    'Part % color % resolves to % base variants for normalized inventory item %; exact variant is required',
                    v_body->>'part_num',
                    COALESCE(v_body->>'color_id','<unspecified>'),
                    v_candidate_count,
                    v_row.ordinality
                    USING ERRCODE='P0409';
            END IF;

            v_body := (v_body - 'part_num' - 'color_id')
                || jsonb_build_object('part_variant_id', v_part_variant_id);
        END IF;

        v_results := v_results || jsonb_build_array(
            api.collection_inventory_operation(
                'create_inventory_item',
                '{}'::jsonb,
                v_body,
                NULL
            )
        );
        v_imported := v_imported + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'imported', v_imported,
        'format', p_payload->>'format',
        'items', v_results
    );
END;
$$;

REVOKE ALL
ON FUNCTION api.import_inventory_normalized(jsonb)
FROM PUBLIC;

COMMENT ON FUNCTION api.import_inventory_normalized(jsonb)
IS
'Imports API-normalized inventory atomically. part_num/color_id inputs resolve to exactly one non-decorated/non-mold-specific base part variant; missing or ambiguous mappings fail closed rather than guessing.';

SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5231_api_inventory_import.sql');
\echo '[PASS] 5231_api_inventory_import.sql'
