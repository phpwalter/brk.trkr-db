/*
===============================================================================
 File:           5000_function/5200_api/5222_api_definition_helpers.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Shared graph helpers for owner-managed versioned manifests.
 Depends On:     definition.inventory_versions
                 definition.requirement_groups
                 definition.requirement_options
                 catalog.items
                 catalog.part_variants
                 pgcrypto
 Creates:        api.inventory_graph_json()
                 api.replace_inventory_graph()
                 api.copy_inventory_graph()
                 api.finalize_inventory_version()
 Key Rules:      Only DRAFT versions may be replaced. FINALIZED versions are
                 immutable snapshots. Semantic hashes are calculated from a
                 deterministic normalized JSON representation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5222_api_definition_helpers.sql',
    ARRAY[
        'definition.inventory_versions',
        'definition.requirement_groups',
        'definition.requirement_options',
        'catalog.items',
        'catalog.part_variants',
        'pgcrypto'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.inventory_graph_json(p_inventory_version_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, definition, catalog
AS $$
    SELECT jsonb_build_object(
        'inventory_version_id', v.inventory_version_id,
        'version', v.semantic_version,
        'status', v.status::text,
        'semantic_hash', CASE WHEN v.semantic_hash IS NULL THEN NULL ELSE encode(v.semantic_hash,'hex') END,
        'requirements', COALESCE((
            SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'requirement_group_id', g.requirement_group_id,
                'requirement_key', g.requirement_key,
                'required_quantity', g.required_quantity,
                'fulfillment_rule', g.fulfillment_rule::text,
                'minimum_options', g.minimum_options,
                'is_required', g.is_required,
                'is_spare', g.is_spare,
                'sort_order', g.sort_order,
                'notes', g.notes,
                'options', COALESCE((
                    SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                        'requirement_option_id', o.requirement_option_id,
                        'item_num', ci.item_num,
                        'part_variant_id', o.part_variant_id,
                        'part_num', pi.item_num,
                        'option_quantity', o.option_quantity,
                        'is_primary', o.is_primary,
                        'minifig_role_id', o.minifig_role_id,
                        'side', o.side,
                        'position_index', o.position_index,
                        'notes', o.notes
                    )) ORDER BY o.requirement_option_id)
                    FROM definition.requirement_options o
                    LEFT JOIN catalog.items ci ON ci.catalog_item_id=o.catalog_item_id
                    LEFT JOIN catalog.part_variants pv ON pv.part_variant_id=o.part_variant_id
                    LEFT JOIN catalog.items pi ON pi.catalog_item_id=pv.part_catalog_item_id
                    WHERE o.requirement_group_id=g.requirement_group_id
                ),'[]'::jsonb)
            )) ORDER BY g.sort_order NULLS LAST,g.requirement_group_id)
            FROM definition.requirement_groups g
            WHERE g.inventory_version_id=v.inventory_version_id
        ),'[]'::jsonb)
    )
    FROM definition.inventory_versions v
    WHERE v.inventory_version_id=p_inventory_version_id;
$$;

CREATE OR REPLACE FUNCTION api.replace_inventory_graph(
    p_inventory_version_id uuid,
    p_graph jsonb
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, definition, catalog
AS $$
DECLARE
    v_status definition.inventory_version_status;
    v_group jsonb;
    v_option jsonb;
    v_group_id bigint;
    v_item_id uuid;
    v_variant_id uuid;
BEGIN
    SELECT status INTO v_status FROM definition.inventory_versions
    WHERE inventory_version_id=p_inventory_version_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Inventory version not found' USING ERRCODE='P0404'; END IF;
    IF v_status <> 'DRAFT' THEN RAISE EXCEPTION 'Finalized inventory versions are immutable' USING ERRCODE='P0409'; END IF;

    DELETE FROM definition.requirement_groups WHERE inventory_version_id=p_inventory_version_id;

    FOR v_group IN SELECT value FROM jsonb_array_elements(COALESCE(p_graph->'requirements','[]'::jsonb))
    LOOP
        INSERT INTO definition.requirement_groups(
            inventory_version_id,required_quantity,fulfillment_rule,minimum_options,is_required,is_spare,sort_order,notes,requirement_key
        ) VALUES (
            p_inventory_version_id,
            COALESCE((v_group->>'required_quantity')::integer,1),
            COALESCE(upper(NULLIF(v_group->>'fulfillment_rule',''))::definition.fulfillment_rule,'ANY'),
            NULLIF(v_group->>'minimum_options','')::smallint,
            COALESCE((v_group->>'is_required')::boolean,true),
            COALESCE((v_group->>'is_spare')::boolean,false),
            NULLIF(v_group->>'sort_order','')::integer,
            v_group->>'notes',
            NULLIF(v_group->>'requirement_key','')
        ) RETURNING requirement_group_id INTO v_group_id;

        FOR v_option IN SELECT value FROM jsonb_array_elements(COALESCE(v_group->'options','[]'::jsonb))
        LOOP
            v_item_id:=NULL;
            v_variant_id:=NULLIF(v_option->>'part_variant_id','')::uuid;
            IF v_variant_id IS NULL AND NULLIF(v_option->>'item_num','') IS NOT NULL THEN
                SELECT catalog_item_id INTO v_item_id FROM catalog.items WHERE item_num=v_option->>'item_num' AND status<>'ARCHIVED';
            END IF;
            IF v_variant_id IS NULL AND v_item_id IS NULL AND NULLIF(v_option->>'part_num','') IS NOT NULL THEN
                SELECT pv.part_variant_id INTO v_variant_id
                FROM catalog.items i JOIN catalog.part_variants pv ON pv.part_catalog_item_id=i.catalog_item_id
                WHERE i.item_num=v_option->>'part_num'
                  AND (NULLIF(v_option->>'color_id','') IS NULL OR pv.color_id=(v_option->>'color_id')::integer)
                ORDER BY pv.is_printed,pv.is_stickered,pv.part_variant_id LIMIT 1;
            END IF;
            IF num_nonnulls(v_item_id,v_variant_id)<>1 THEN
                RAISE EXCEPTION 'Each manifest option must resolve to exactly one catalog item or part variant' USING ERRCODE='22023';
            END IF;
            INSERT INTO definition.requirement_options(
                requirement_group_id,catalog_item_id,part_variant_id,option_quantity,is_primary,minifig_role_id,side,position_index,notes
            ) VALUES (
                v_group_id,v_item_id,v_variant_id,COALESCE((v_option->>'option_quantity')::integer,1),COALESCE((v_option->>'is_primary')::boolean,false),
                NULLIF(v_option->>'minifig_role_id','')::integer,upper(NULLIF(v_option->>'side','')),NULLIF(v_option->>'position_index','')::smallint,v_option->>'notes'
            );
        END LOOP;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION api.copy_inventory_graph(
    p_source_version_id uuid,
    p_target_version_id uuid
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api
AS $$
BEGIN
    PERFORM api.replace_inventory_graph(p_target_version_id,api.inventory_graph_json(p_source_version_id));
END;
$$;

CREATE OR REPLACE FUNCTION api.finalize_inventory_version(p_inventory_version_id uuid)
RETURNS bytea
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, definition, public
AS $$
DECLARE
    v_status definition.inventory_version_status;
    v_hash bytea;
BEGIN
    SELECT status INTO v_status FROM definition.inventory_versions WHERE inventory_version_id=p_inventory_version_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Inventory version not found' USING ERRCODE='P0404'; END IF;
    IF v_status='FINALIZED' THEN
        SELECT semantic_hash INTO v_hash FROM definition.inventory_versions WHERE inventory_version_id=p_inventory_version_id;
        RETURN v_hash;
    END IF;
    v_hash:=digest(convert_to(api.inventory_graph_json(p_inventory_version_id)::text,'UTF8'),'sha256');
    UPDATE definition.inventory_versions SET semantic_hash=v_hash,status='FINALIZED',finalized_at=now(),last_seen_at=now() WHERE inventory_version_id=p_inventory_version_id;
    RETURN v_hash;
END;
$$;

REVOKE ALL ON FUNCTION api.inventory_graph_json(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.replace_inventory_graph(uuid,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.copy_inventory_graph(uuid,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.finalize_inventory_version(uuid) FROM PUBLIC;

\echo '[PASS] 5222_api_definition_helpers.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5222_api_definition_helpers.sql');
