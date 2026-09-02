/*
===============================================================================
 File:           5000_function/5200_api/5290_api_visibility_reads.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Provide anonymous-safe and optionally authenticated reads for
                 public/unlisted MOCs, canonical/custom minifigs and public
                 wishlists without weakening authenticated mutation dispatchers.
 Depends On:     identity.current_user_id_optional()
                 identity.can_view_owner()
                 identity.can_view_family_shared_owner()
                 catalog.items
                 catalog.minifigures
                 definition.custom_minifigs
                 definition.inventory_definitions
                 definition.inventory_versions
                 definition.minifig_compositions
                 definition.minifig_structural_components
                 definition.minifig_accessories
                 api.inventory_graph_json()
                 moc.mocs
                 moc.revisions
                 moc.assets
                 moc.licenses
                 moc.subassemblies
                 moc.forks
                 wanted.wishlists
                 wanted.wishlist_entries
                 marketplace.market_price_observations
 Creates:        api.visibility_read_operation()
 Key Rules:      Anonymous callers see only PUBLIC/UNLISTED authored catalog
                 state and PUBLIC wishlists. Authenticated callers may additionally
                 see resources permitted by owner/family visibility helpers.
                 This routine performs no mutations.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5290_api_visibility_reads.sql',
    ARRAY[
        'identity.current_user_id_optional()',
        'identity.can_view_owner()',
        'identity.can_view_family_shared_owner()',
        'catalog.items',
        'catalog.minifigures',
        'definition.custom_minifigs',
        'definition.inventory_definitions',
        'definition.inventory_versions',
        'definition.minifig_compositions',
        'definition.minifig_structural_components',
        'definition.minifig_accessories',
        'api.inventory_graph_json()',
        'moc.mocs',
        'moc.revisions',
        'moc.assets',
        'moc.licenses',
        'moc.subassemblies',
        'moc.forks',
        'wanted.wishlists',
        'wanted.wishlist_entries',
        'marketplace.market_price_observations'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.visibility_read_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, identity, catalog, definition, moc, wanted, marketplace, api
AS $$
DECLARE
    v_user uuid := identity.current_user_id_optional();
    v_item_num text := NULLIF(p_params->>'item_num','');
    v_moc_id uuid;
    v_catalog_id uuid;
    v_owner uuid;
    v_custom_id uuid;
    v_def_id uuid;
    v_version_id uuid;
    v_revision_id uuid;
    v_wishlist_id uuid;
    v_limit integer := LEAST(GREATEST(COALESCE((p_params->>'limit')::integer,50),1),200);
    v_cursor uuid := NULLIF(p_params->>'cursor','')::uuid;
    v_result jsonb;
BEGIN
    IF p_operation IN (
        'get_moc','get_moc_by_internal_id','get_moc_manifest','list_moc_manifest_versions',
        'get_moc_manifest_version','list_moc_revisions','list_moc_assets','list_moc_licenses',
        'list_moc_subassemblies','list_moc_forks'
    ) THEN
        IF p_operation='get_moc_by_internal_id' THEN
            v_moc_id:=(p_params->>'moc_id')::uuid;
            SELECT i.catalog_item_id,m.owner_id
              INTO v_catalog_id,v_owner
              FROM moc.mocs m JOIN catalog.items i USING(catalog_item_id)
             WHERE m.moc_id=v_moc_id
               AND m.archived_at IS NULL
               AND (
                    m.visibility IN('PUBLIC','UNLISTED')
                    OR (v_user IS NOT NULL AND identity.can_view_owner(v_user,m.owner_id,'MOCS'))
                    OR (v_user IS NOT NULL AND m.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,m.owner_id,'MOCS'))
               );
        ELSE
            SELECT i.catalog_item_id,m.moc_id,m.owner_id
              INTO v_catalog_id,v_moc_id,v_owner
              FROM catalog.items i JOIN moc.mocs m USING(catalog_item_id)
             WHERE i.item_num=v_item_num
               AND i.item_kind='MOC'
               AND m.archived_at IS NULL
               AND (
                    m.visibility IN('PUBLIC','UNLISTED')
                    OR (v_user IS NOT NULL AND identity.can_view_owner(v_user,m.owner_id,'MOCS'))
                    OR (v_user IS NOT NULL AND m.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,m.owner_id,'MOCS'))
               );
        END IF;
        IF v_moc_id IS NULL THEN RAISE EXCEPTION 'MOC not found' USING ERRCODE='P0404'; END IF;

        CASE p_operation
        WHEN 'get_moc','get_moc_by_internal_id' THEN
            SELECT jsonb_strip_nulls(jsonb_build_object(
                'item_num',i.item_num,'name',m.title,'revision',m.edit_revision,'_etag',api.etag_for_revision(m.edit_revision),
                'data',jsonb_build_object('moc_id',m.moc_id,'description',m.description,'visibility',m.visibility::text,
                    'forks_allowed',m.forks_allowed,'created_at',m.created_at,'updated_at',m.updated_at,'archived_at',m.archived_at)
            )) INTO v_result
            FROM moc.mocs m JOIN catalog.items i USING(catalog_item_id) WHERE m.moc_id=v_moc_id;

        WHEN 'get_moc_manifest' THEN
            SELECT d.inventory_definition_id INTO v_def_id
              FROM definition.inventory_definitions d
             WHERE d.catalog_item_id=v_catalog_id AND d.definition_kind='MOC_MANIFEST';
            IF v_user IS NOT NULL AND identity.can_view_owner(v_user,v_owner,'MOCS') THEN
                SELECT inventory_version_id INTO v_version_id
                  FROM definition.inventory_versions
                 WHERE inventory_definition_id=v_def_id
                 ORDER BY (status='DRAFT') DESC,semantic_version DESC LIMIT 1;
            ELSE
                SELECT inventory_version_id INTO v_version_id
                  FROM definition.inventory_versions
                 WHERE inventory_definition_id=v_def_id AND status='FINALIZED'
                 ORDER BY semantic_version DESC LIMIT 1;
            END IF;
            IF v_version_id IS NULL THEN RAISE EXCEPTION 'MOC manifest not found' USING ERRCODE='P0404'; END IF;
            v_result:=jsonb_build_object(
                'item_num',(SELECT item_num FROM catalog.items WHERE catalog_item_id=v_catalog_id),
                'name',(SELECT title FROM moc.mocs WHERE moc_id=v_moc_id)||' manifest',
                'revision',(SELECT edit_revision FROM moc.mocs WHERE moc_id=v_moc_id),
                '_etag',api.etag_for_revision((SELECT edit_revision FROM moc.mocs WHERE moc_id=v_moc_id)),
                'data',api.inventory_graph_json(v_version_id)
            );

        WHEN 'list_moc_manifest_versions' THEN
            SELECT d.inventory_definition_id INTO v_def_id FROM definition.inventory_definitions d
             WHERE d.catalog_item_id=v_catalog_id AND d.definition_kind='MOC_MANIFEST';
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'version',v.semantic_version,'etag',api.etag_for_revision(v.semantic_version),
                'data',api.inventory_graph_json(v.inventory_version_id)
            ) ORDER BY v.semantic_version DESC),'[]'::jsonb)
            INTO v_result FROM definition.inventory_versions v
            WHERE v.inventory_definition_id=v_def_id AND v.status='FINALIZED';

        WHEN 'get_moc_manifest_version' THEN
            SELECT v.inventory_version_id INTO v_version_id
              FROM definition.inventory_definitions d JOIN definition.inventory_versions v USING(inventory_definition_id)
             WHERE d.catalog_item_id=v_catalog_id AND d.definition_kind='MOC_MANIFEST'
               AND v.status='FINALIZED' AND v.semantic_version=(p_params->>'version')::integer;
            IF v_version_id IS NULL THEN RAISE EXCEPTION 'MOC manifest version not found' USING ERRCODE='P0404'; END IF;
            v_result:=jsonb_build_object('version',(p_params->>'version')::integer,'etag',api.etag_for_revision((p_params->>'version')::bigint),'data',api.inventory_graph_json(v_version_id));

        WHEN 'list_moc_revisions' THEN
            SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.revision_number DESC),'[]'::jsonb)
              INTO v_result FROM moc.revisions r
             WHERE r.moc_id=v_moc_id
               AND ((v_user IS NOT NULL AND identity.can_view_owner(v_user,v_owner,'MOCS')) OR r.status='PUBLISHED');

        WHEN 'list_moc_assets' THEN
            v_revision_id:=(p_params->>'revision_id')::uuid;
            IF NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND ((v_user IS NOT NULL AND identity.can_view_owner(v_user,v_owner,'MOCS')) OR r.status='PUBLISHED')) THEN
                RAISE EXCEPTION 'MOC revision not found' USING ERRCODE='P0404';
            END IF;
            SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.created_at),'[]'::jsonb) INTO v_result FROM moc.assets a WHERE a.moc_revision_id=v_revision_id;

        WHEN 'list_moc_licenses' THEN
            v_revision_id:=(p_params->>'revision_id')::uuid;
            IF NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND ((v_user IS NOT NULL AND identity.can_view_owner(v_user,v_owner,'MOCS')) OR r.status='PUBLISHED')) THEN
                RAISE EXCEPTION 'MOC revision not found' USING ERRCODE='P0404';
            END IF;
            SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.created_at),'[]'::jsonb) INTO v_result FROM moc.licenses l WHERE l.moc_revision_id=v_revision_id;

        WHEN 'list_moc_subassemblies' THEN
            v_revision_id:=(p_params->>'revision_id')::uuid;
            IF NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND ((v_user IS NOT NULL AND identity.can_view_owner(v_user,v_owner,'MOCS')) OR r.status='PUBLISHED')) THEN
                RAISE EXCEPTION 'MOC revision not found' USING ERRCODE='P0404';
            END IF;
            SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.sort_order NULLS LAST,s.subassembly_id),'[]'::jsonb) INTO v_result FROM moc.subassemblies s WHERE s.moc_revision_id=v_revision_id;

        WHEN 'list_moc_forks' THEN
            SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.forked_at),'[]'::jsonb) INTO v_result FROM moc.forks f WHERE f.source_moc_id=v_moc_id;
        END CASE;
        RETURN COALESCE(v_result,'null'::jsonb);
    END IF;

    IF p_operation IN ('get_minifig','get_minifig_composition','list_minifig_composition_versions','get_minifig_composition_version','get_minifig_market') THEN
        SELECT i.catalog_item_id,cm.custom_minifig_id,cm.owner_id
          INTO v_catalog_id,v_custom_id,v_owner
          FROM catalog.items i LEFT JOIN definition.custom_minifigs cm USING(catalog_item_id)
         WHERE i.item_num=v_item_num
           AND i.item_kind='MINIFIGURE'
           AND i.status NOT IN('ARCHIVED','UNRESOLVED_CUSTOM')
           AND (
                cm.custom_minifig_id IS NULL
                OR (
                    cm.archived_at IS NULL AND (
                        cm.visibility IN('PUBLIC','UNLISTED')
                        OR (v_user IS NOT NULL AND identity.can_view_owner(v_user,cm.owner_id,'COLLECTION'))
                        OR (v_user IS NOT NULL AND cm.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,cm.owner_id,'COLLECTION'))
                    )
                )
           );
        IF v_catalog_id IS NULL THEN RAISE EXCEPTION 'Minifigure not found' USING ERRCODE='P0404'; END IF;

        CASE p_operation
        WHEN 'get_minifig' THEN
            SELECT jsonb_strip_nulls(jsonb_build_object(
                'item_num',i.item_num,'name',i.canonical_name,'revision',COALESCE(cm.edit_revision,1),
                '_etag',api.etag_for_revision(COALESCE(cm.edit_revision,1)),
                'data',jsonb_build_object('lego_minifig_id',mf.lego_minifig_id,'theme_id',mf.theme_id,
                    'custom',cm.custom_minifig_id IS NOT NULL,'visibility',cm.visibility::text,'description',cm.description)
            )) INTO v_result
            FROM catalog.items i JOIN catalog.minifigures mf USING(catalog_item_id)
            LEFT JOIN definition.custom_minifigs cm USING(catalog_item_id)
            WHERE i.catalog_item_id=v_catalog_id;

        WHEN 'get_minifig_composition','list_minifig_composition_versions','get_minifig_composition_version' THEN
            SELECT inventory_definition_id INTO v_def_id FROM definition.inventory_definitions
            WHERE catalog_item_id=v_catalog_id AND definition_kind='MINIFIG_COMPOSITION';
            IF v_def_id IS NULL THEN RAISE EXCEPTION 'Minifigure composition definition not found' USING ERRCODE='P0404'; END IF;

            IF p_operation='list_minifig_composition_versions' THEN
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'version',v.semantic_version,'status',v.status::text,
                    'semantic_hash',CASE WHEN v.semantic_hash IS NULL THEN NULL ELSE encode(v.semantic_hash,'hex') END
                ) ORDER BY v.semantic_version DESC),'[]'::jsonb)
                INTO v_result FROM definition.inventory_versions v
                WHERE v.inventory_definition_id=v_def_id AND v.status='FINALIZED';
            ELSE
                IF p_operation='get_minifig_composition_version' THEN
                    SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions
                    WHERE inventory_definition_id=v_def_id AND semantic_version=(p_params->>'version')::integer AND status='FINALIZED';
                ELSIF v_custom_id IS NOT NULL AND v_user IS NOT NULL AND identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN
                    SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions
                    WHERE inventory_definition_id=v_def_id ORDER BY (status='DRAFT') DESC,semantic_version DESC LIMIT 1;
                ELSE
                    SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions
                    WHERE inventory_definition_id=v_def_id AND status='FINALIZED' ORDER BY semantic_version DESC LIMIT 1;
                END IF;
                IF v_version_id IS NULL THEN RAISE EXCEPTION 'Minifigure composition not found' USING ERRCODE='P0404'; END IF;
                SELECT jsonb_build_object(
                    'item_num',v_item_num,'version',v.semantic_version,'status',v.status::text,
                    'revision',COALESCE(cm.edit_revision,1),'_etag',api.etag_for_revision(COALESCE(cm.edit_revision,1)),
                    'components',COALESCE((SELECT jsonb_agg(x ORDER BY (x->>'position_index')::integer) FROM (
                        SELECT jsonb_strip_nulls(jsonb_build_object('kind','STRUCTURAL','role',s.semantic_role,'minifig_role_id',s.minifig_role_id,'side',s.side,'position_index',s.position_index,'part_variant_id',s.part_variant_id,'decorated_variant_id',s.decorated_variant_id,'quantity',s.quantity)) x
                        FROM definition.minifig_structural_components s JOIN definition.minifig_compositions c USING(minifig_composition_id) WHERE c.inventory_version_id=v.inventory_version_id
                        UNION ALL
                        SELECT jsonb_build_object('kind','ACCESSORY','role','ACCESSORY','position_index',a.position_index,'part_variant_id',a.part_variant_id,'quantity',a.quantity)
                        FROM definition.minifig_accessories a JOIN definition.minifig_compositions c USING(minifig_composition_id) WHERE c.inventory_version_id=v.inventory_version_id
                    ) q),'[]'::jsonb)
                ) INTO v_result
                FROM definition.inventory_versions v LEFT JOIN definition.custom_minifigs cm ON cm.catalog_item_id=v_catalog_id
                WHERE v.inventory_version_id=v_version_id;
            END IF;

        WHEN 'get_minifig_market' THEN
            SELECT jsonb_build_object('item_num',v_item_num,'data',jsonb_build_object(
                'observations',COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.observed_at DESC),'[]'::jsonb)
            )) INTO v_result
            FROM marketplace.market_price_observations m
            WHERE m.catalog_item_id=v_catalog_id
              AND (NULLIF(p_params->>'condition','') IS NULL OR m.condition::text=upper(p_params->>'condition'));
        END CASE;
        RETURN COALESCE(v_result,'null'::jsonb);
    END IF;

    IF p_operation IN ('list_public_wishlists','get_public_wishlist','list_public_wishlist_entries') THEN
        IF p_operation='list_public_wishlists' THEN
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'wishlist_id',w.wishlist_id,'owner_id',w.owner_id,'name',w.wishlist_name,'description',w.description,
                'visibility',w.visibility::text,'is_default',w.is_default,'revision',w.edit_revision,
                'etag',api.etag_for_revision(w.edit_revision),'created_at',w.created_at,'updated_at',w.updated_at
            )) ORDER BY w.wishlist_id),'[]'::jsonb) INTO v_result
            FROM (SELECT * FROM wanted.wishlists w WHERE w.archived_at IS NULL AND w.visibility='PUBLIC' AND (v_cursor IS NULL OR w.wishlist_id>v_cursor) ORDER BY w.wishlist_id LIMIT v_limit) w;
            RETURN v_result;
        END IF;

        v_wishlist_id:=(p_params->>'wishlist_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM wanted.wishlists WHERE wishlist_id=v_wishlist_id AND archived_at IS NULL AND visibility='PUBLIC') THEN
            RAISE EXCEPTION 'Wishlist not found' USING ERRCODE='P0404';
        END IF;
        IF p_operation='get_public_wishlist' THEN
            SELECT jsonb_strip_nulls(jsonb_build_object(
                'wishlist_id',w.wishlist_id,'owner_id',w.owner_id,'name',w.wishlist_name,'description',w.description,
                'visibility',w.visibility::text,'is_default',w.is_default,'revision',w.edit_revision,
                '_etag',api.etag_for_revision(w.edit_revision),'created_at',w.created_at,'updated_at',w.updated_at
            )) INTO v_result FROM wanted.wishlists w WHERE w.wishlist_id=v_wishlist_id;
        ELSE
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'wishlist_entry_id',e.wishlist_entry_id,'wishlist_id',e.wishlist_id,'item_num',i.item_num,
                'part_variant_id',e.part_variant_id,'desired_quantity',e.desired_quantity,'satisfied_quantity',e.satisfied_quantity,
                'priority',e.priority,'target_unit_price',e.target_unit_price,'currency',e.currency,'status',e.status::text,
                'notes',e.notes,'revision',e.edit_revision,'etag',api.etag_for_revision(e.edit_revision),'created_at',e.created_at
            )) ORDER BY e.wishlist_entry_id),'[]'::jsonb) INTO v_result
            FROM wanted.wishlist_entries e LEFT JOIN catalog.items i ON i.catalog_item_id=e.catalog_item_id
            WHERE e.wishlist_id=v_wishlist_id AND e.archived_at IS NULL;
        END IF;
        RETURN COALESCE(v_result,'null'::jsonb);
    END IF;

    RAISE EXCEPTION 'Unknown visibility-read API operation: %',p_operation USING ERRCODE='22023';
END;
$$;

REVOKE ALL ON FUNCTION api.visibility_read_operation(text,jsonb) FROM PUBLIC;

\echo '[PASS] 5290_api_visibility_reads.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5290_api_visibility_reads.sql');
