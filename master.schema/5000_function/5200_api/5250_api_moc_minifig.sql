/*
===============================================================================
 File:           5000_function/5200_api/5250_api_moc_minifig.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Implement owner-managed MOC and custom-minifigure lifecycle
                 operations while preserving read-only canonical minifigures.
 Depends On:     api.current_user_owner_id()
                 api.assert_if_match()
                 api.inventory_graph_json()
                 api.replace_inventory_graph()
                 api.copy_inventory_graph()
                 api.finalize_inventory_version()
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
                 identity.can_view_family_shared_owner()
                 catalog.items
                 catalog.mocs
                 catalog.minifigures
                 definition.custom_minifigs
                 definition.inventory_definitions
                 definition.inventory_versions
                 definition.minifig_compositions
                 definition.minifig_structural_components
                 definition.minifig_accessories
                 moc.mocs
                 moc.revisions
                 moc.forks
                 moc.subassemblies
                 moc.licenses
                 moc.assets
                 marketplace.market_price_observations
 Creates:        api.moc_minifig_operation()
 Key Rules:      Canonical minifigures are source controlled and cannot be
                 mutated by normal users. MOCs and custom minifigures are owned,
                 visibility-aware, versioned, concurrency protected and soft
                 archived. Finalized semantic definition versions are immutable.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5250_api_moc_minifig.sql',
    ARRAY[
        'api.current_user_owner_id()',
        'api.assert_if_match()',
        'api.inventory_graph_json()',
        'api.replace_inventory_graph()',
        'api.copy_inventory_graph()',
        'api.finalize_inventory_version()',
        'identity.current_user_id()',
        'identity.can_view_owner()',
        'identity.can_manage_owner()',
        'identity.can_view_family_shared_owner()',
        'catalog.items',
        'catalog.mocs',
        'catalog.minifigures',
        'definition.custom_minifigs',
        'definition.inventory_definitions',
        'definition.inventory_versions',
        'definition.minifig_compositions',
        'definition.minifig_structural_components',
        'definition.minifig_accessories',
        'moc.mocs',
        'moc.revisions',
        'moc.forks',
        'moc.subassemblies',
        'moc.licenses',
        'moc.assets',
        'marketplace.market_price_observations'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.moc_minifig_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb,
    p_body jsonb DEFAULT '{}'::jsonb,
    p_if_match text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, identity, catalog, definition, moc, marketplace, reference, public
AS $$
DECLARE
    v_user uuid := identity.current_user_id();
    v_owner uuid := api.current_user_owner_id();
    v_item_num text := NULLIF(p_params->>'item_num','');
    v_catalog_id uuid;
    v_moc_id uuid;
    v_custom_id uuid;
    v_def_id uuid;
    v_version_id uuid;
    v_new_version_id uuid;
    v_revision_id uuid;
    v_new_revision_id uuid;
    v_revision bigint;
    v_semantic integer;
    v_hash bytea;
    v_visible boolean;
    v_result jsonb;
    v_component jsonb;
    v_kind text;
    v_source_moc uuid;
    v_source_revision uuid;
    v_created_item_num text;
BEGIN
    /* ---------------------------------------------------------------------
     * MOC identity lifecycle
     * ------------------------------------------------------------------ */
    IF p_operation='create_moc' THEN
        v_item_num:='MOC-' || upper(substr(replace(app.uuid_v7()::text,'-',''),1,12));
        INSERT INTO catalog.items(item_kind,item_num,canonical_name,status)
        VALUES('MOC',v_item_num,p_body->>'name','ACTIVE') RETURNING catalog_item_id INTO v_catalog_id;
        INSERT INTO catalog.mocs(catalog_item_id,discovery_summary) VALUES(v_catalog_id,p_body->>'description');
        INSERT INTO moc.mocs(catalog_item_id,owner_id,title,description,visibility,forks_allowed,created_by_user_id)
        VALUES(v_catalog_id,v_owner,p_body->>'name',p_body->>'description',COALESCE(upper(NULLIF(p_body->>'visibility',''))::moc.visibility,'PRIVATE'),COALESCE((p_body->>'forks_allowed')::boolean,true),v_user)
        RETURNING moc_id,edit_revision INTO v_moc_id,v_revision;
        INSERT INTO definition.inventory_definitions(catalog_item_id,definition_kind) VALUES(v_catalog_id,'MOC_MANIFEST') RETURNING inventory_definition_id INTO v_def_id;
        INSERT INTO definition.inventory_versions(inventory_definition_id,semantic_version,status,created_by_user_id)
        VALUES(v_def_id,1,'DRAFT',v_user) RETURNING inventory_version_id INTO v_version_id;
        INSERT INTO moc.revisions(moc_id,revision_number,inventory_version_id,status,created_by_user_id)
        VALUES(v_moc_id,1,v_version_id,'DRAFT',v_user) RETURNING moc_revision_id INTO v_revision_id;
        RETURN jsonb_build_object('item_num',v_item_num,'name',p_body->>'name','revision',v_revision,'_etag',api.etag_for_revision(v_revision),'data',jsonb_build_object('moc_id',v_moc_id,'visibility',COALESCE(upper(NULLIF(p_body->>'visibility','')),'PRIVATE')));
    END IF;

    IF p_operation IN ('get_moc','replace_moc','patch_moc','delete_moc','restore_moc','get_moc_manifest','replace_moc_manifest','patch_moc_manifest','create_moc_manifest_version','list_moc_manifest_versions','get_moc_manifest_version','list_moc_revisions','list_moc_assets','create_moc_asset','delete_moc_asset','list_moc_licenses','create_moc_license','list_moc_subassemblies','create_moc_subassembly','list_moc_forks','fork_moc') THEN
        SELECT i.catalog_item_id,m.moc_id,m.owner_id,m.edit_revision,
               (m.archived_at IS NULL AND (
                    m.visibility IN ('PUBLIC','UNLISTED')
                    OR identity.can_view_owner(v_user,m.owner_id,'MOCS')
                    OR (m.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,m.owner_id,'MOCS'))
               ))
          INTO v_catalog_id,v_moc_id,v_owner,v_revision,v_visible
          FROM catalog.items i JOIN moc.mocs m USING(catalog_item_id)
         WHERE i.item_num=v_item_num AND i.item_kind='MOC';
        IF v_moc_id IS NULL THEN RAISE EXCEPTION 'MOC not found' USING ERRCODE='P0404'; END IF;
        IF p_operation NOT IN ('restore_moc') AND NOT v_visible THEN RAISE EXCEPTION 'MOC not found' USING ERRCODE='P0404'; END IF;
    END IF;

    CASE p_operation
    WHEN 'get_moc' THEN
        SELECT jsonb_strip_nulls(jsonb_build_object(
            'item_num',i.item_num,'name',m.title,'revision',m.edit_revision,'_etag',api.etag_for_revision(m.edit_revision),
            'data',jsonb_build_object('moc_id',m.moc_id,'description',m.description,'visibility',m.visibility::text,'forks_allowed',m.forks_allowed,
                'created_at',m.created_at,'updated_at',m.updated_at,'archived_at',m.archived_at)
        )) INTO v_result FROM catalog.items i JOIN moc.mocs m USING(catalog_item_id) WHERE m.moc_id=v_moc_id;

    WHEN 'replace_moc','patch_moc' THEN
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE moc.mocs SET
            title=CASE WHEN p_operation='replace_moc' OR p_body?'name' THEN COALESCE(p_body->>'name',title) ELSE title END,
            description=CASE WHEN p_operation='replace_moc' OR p_body?'description' THEN p_body->>'description' ELSE description END,
            visibility=CASE WHEN p_operation='replace_moc' OR p_body?'visibility' THEN COALESCE(upper(NULLIF(p_body->>'visibility',''))::moc.visibility,visibility) ELSE visibility END,
            forks_allowed=CASE WHEN p_body?'forks_allowed' THEN (p_body->>'forks_allowed')::boolean ELSE forks_allowed END,
            edit_revision=edit_revision+1,updated_at=now()
        WHERE moc_id=v_moc_id;
        UPDATE catalog.items SET canonical_name=COALESCE(p_body->>'name',canonical_name) WHERE catalog_item_id=v_catalog_id;
        SELECT api.moc_minifig_operation('get_moc',jsonb_build_object('item_num',v_item_num),'{}',NULL) INTO v_result;

    WHEN 'delete_moc' THEN
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE moc.mocs SET archived_at=COALESCE(archived_at,now()),edit_revision=edit_revision+1,updated_at=now() WHERE moc_id=v_moc_id;
        v_result:=jsonb_build_object('archived',true,'item_num',v_item_num);

    WHEN 'restore_moc' THEN
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE moc.mocs SET archived_at=NULL,edit_revision=edit_revision+1,updated_at=now() WHERE moc_id=v_moc_id;
        SELECT api.moc_minifig_operation('get_moc',jsonb_build_object('item_num',v_item_num),'{}',NULL) INTO v_result;

    WHEN 'get_moc_manifest' THEN
        SELECT d.inventory_definition_id INTO v_def_id FROM definition.inventory_definitions d WHERE d.catalog_item_id=v_catalog_id AND d.definition_kind='MOC_MANIFEST';
        IF identity.can_view_owner(v_user,v_owner,'MOCS') THEN
            SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions WHERE inventory_definition_id=v_def_id ORDER BY (status='DRAFT') DESC,semantic_version DESC LIMIT 1;
        ELSE
            SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions WHERE inventory_definition_id=v_def_id AND status='FINALIZED' ORDER BY semantic_version DESC LIMIT 1;
        END IF;
        IF v_version_id IS NULL THEN RAISE EXCEPTION 'MOC manifest not found' USING ERRCODE='P0404'; END IF;
        v_result:=jsonb_build_object('item_num',v_item_num,'name',(SELECT title FROM moc.mocs WHERE moc_id=v_moc_id)||' manifest','revision',v_revision,'_etag',api.etag_for_revision(v_revision),'data',api.inventory_graph_json(v_version_id));

    WHEN 'replace_moc_manifest','patch_moc_manifest' THEN
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        SELECT d.inventory_definition_id INTO v_def_id FROM definition.inventory_definitions d WHERE d.catalog_item_id=v_catalog_id AND d.definition_kind='MOC_MANIFEST';
        SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions WHERE inventory_definition_id=v_def_id AND status='DRAFT' ORDER BY semantic_version DESC LIMIT 1 FOR UPDATE;
        IF v_version_id IS NULL THEN RAISE EXCEPTION 'No editable MOC manifest draft exists' USING ERRCODE='P0409'; END IF;
        IF p_operation='patch_moc_manifest' THEN
            PERFORM api.replace_inventory_graph(v_version_id,api.inventory_graph_json(v_version_id) || COALESCE(p_body->'data',p_body));
        ELSE
            PERFORM api.replace_inventory_graph(v_version_id,COALESCE(p_body->'data',p_body));
        END IF;
        UPDATE moc.mocs SET edit_revision=edit_revision+1,updated_at=now() WHERE moc_id=v_moc_id RETURNING edit_revision INTO v_revision;
        v_result:=jsonb_build_object('item_num',v_item_num,'revision',v_revision,'_etag',api.etag_for_revision(v_revision),'data',api.inventory_graph_json(v_version_id));

    WHEN 'create_moc_manifest_version' THEN
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        SELECT d.inventory_definition_id INTO v_def_id FROM definition.inventory_definitions d WHERE d.catalog_item_id=v_catalog_id AND d.definition_kind='MOC_MANIFEST';
        SELECT inventory_version_id,semantic_version INTO v_version_id,v_semantic FROM definition.inventory_versions WHERE inventory_definition_id=v_def_id AND status='DRAFT' ORDER BY semantic_version DESC LIMIT 1 FOR UPDATE;
        IF v_version_id IS NULL THEN RAISE EXCEPTION 'No editable MOC manifest draft exists' USING ERRCODE='P0409'; END IF;
        v_hash:=api.finalize_inventory_version(v_version_id);
        SELECT moc_revision_id INTO v_revision_id FROM moc.revisions WHERE moc_id=v_moc_id AND status='DRAFT' ORDER BY revision_number DESC LIMIT 1 FOR UPDATE;
        UPDATE moc.revisions SET inventory_version_id=v_version_id,status='PUBLISHED',semantic_hash=v_hash,published_at=now(),updated_at=now(),edit_revision=edit_revision+1 WHERE moc_revision_id=v_revision_id;
        INSERT INTO definition.inventory_versions(inventory_definition_id,semantic_version,status,created_by_user_id)
        VALUES(v_def_id,v_semantic+1,'DRAFT',v_user) RETURNING inventory_version_id INTO v_new_version_id;
        PERFORM api.copy_inventory_graph(v_version_id,v_new_version_id);
        INSERT INTO moc.revisions(moc_id,revision_number,parent_revision_id,inventory_version_id,status,created_by_user_id)
        SELECT v_moc_id,COALESCE(max(revision_number),0)+1,v_revision_id,v_new_version_id,'DRAFT',v_user FROM moc.revisions WHERE moc_id=v_moc_id RETURNING moc_revision_id INTO v_new_revision_id;
        UPDATE moc.mocs SET edit_revision=edit_revision+1,updated_at=now() WHERE moc_id=v_moc_id RETURNING edit_revision INTO v_revision;
        v_result:=jsonb_build_object('version',v_semantic,'etag',api.etag_for_revision(v_revision),'data',api.inventory_graph_json(v_version_id));

    WHEN 'list_moc_manifest_versions' THEN
        SELECT d.inventory_definition_id INTO v_def_id FROM definition.inventory_definitions d WHERE d.catalog_item_id=v_catalog_id AND d.definition_kind='MOC_MANIFEST';
        SELECT COALESCE(jsonb_agg(jsonb_build_object('version',v.semantic_version,'etag',api.etag_for_revision(v.semantic_version),'data',api.inventory_graph_json(v.inventory_version_id)) ORDER BY v.semantic_version DESC),'[]'::jsonb)
        INTO v_result FROM definition.inventory_versions v WHERE v.inventory_definition_id=v_def_id AND v.status='FINALIZED';

    WHEN 'get_moc_manifest_version' THEN
        SELECT v.inventory_version_id INTO v_version_id FROM definition.inventory_definitions d JOIN definition.inventory_versions v USING(inventory_definition_id)
        WHERE d.catalog_item_id=v_catalog_id AND d.definition_kind='MOC_MANIFEST' AND v.status='FINALIZED' AND v.semantic_version=(p_params->>'version')::integer;
        IF v_version_id IS NULL THEN RAISE EXCEPTION 'MOC manifest version not found' USING ERRCODE='P0404'; END IF;
        v_result:=jsonb_build_object('version',(p_params->>'version')::integer,'etag',api.etag_for_revision((p_params->>'version')::bigint),'data',api.inventory_graph_json(v_version_id));

    WHEN 'list_moc_revisions' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.revision_number DESC),'[]'::jsonb) INTO v_result FROM moc.revisions r
        WHERE r.moc_id=v_moc_id AND (identity.can_view_owner(v_user,v_owner,'MOCS') OR r.status='PUBLISHED');

    WHEN 'list_moc_assets' THEN
        v_revision_id:=(p_params->>'revision_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND (identity.can_view_owner(v_user,v_owner,'MOCS') OR r.status='PUBLISHED')) THEN RAISE EXCEPTION 'MOC revision not found' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.created_at),'[]'::jsonb) INTO v_result FROM moc.assets a WHERE a.moc_revision_id=v_revision_id;

    WHEN 'create_moc_asset' THEN
        v_revision_id:=(p_params->>'revision_id')::uuid;
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') OR NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND r.status='DRAFT') THEN RAISE EXCEPTION 'Editable MOC revision not found or forbidden' USING ERRCODE='P0404'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        INSERT INTO moc.assets(moc_revision_id,asset_type,storage_key,original_filename,mime_type,size_bytes,checksum_sha256)
        VALUES(v_revision_id,p_body->>'asset_type',p_body->>'storage_key',COALESCE(p_body->>'original_filename',p_body->>'storage_key'),p_body->>'mime_type',NULLIF(p_body->>'size_bytes','')::bigint,CASE WHEN NULLIF(p_body->>'checksum_sha256','') IS NULL THEN NULL ELSE decode(p_body->>'checksum_sha256','hex') END)
        RETURNING to_jsonb(moc.assets) INTO v_result;
        UPDATE moc.mocs SET edit_revision=edit_revision+1,updated_at=now() WHERE moc_id=v_moc_id;

    WHEN 'delete_moc_asset' THEN
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        DELETE FROM moc.assets a USING moc.revisions r WHERE a.moc_asset_id=(p_params->>'asset_id')::uuid AND a.moc_revision_id=r.moc_revision_id AND r.moc_id=v_moc_id AND r.status='DRAFT';
        IF NOT FOUND THEN RAISE EXCEPTION 'Editable MOC asset not found' USING ERRCODE='P0404'; END IF;
        UPDATE moc.mocs SET edit_revision=edit_revision+1,updated_at=now() WHERE moc_id=v_moc_id;
        v_result:=jsonb_build_object('deleted',true,'asset_id',p_params->>'asset_id');

    WHEN 'list_moc_licenses' THEN
        v_revision_id:=(p_params->>'revision_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND (identity.can_view_owner(v_user,v_owner,'MOCS') OR r.status='PUBLISHED')) THEN RAISE EXCEPTION 'MOC revision not found' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.created_at),'[]'::jsonb) INTO v_result FROM moc.licenses l WHERE l.moc_revision_id=v_revision_id;

    WHEN 'create_moc_license' THEN
        v_revision_id:=(p_params->>'revision_id')::uuid;
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') OR NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND r.status='DRAFT') THEN RAISE EXCEPTION 'Editable MOC revision not found or forbidden' USING ERRCODE='P0404'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        INSERT INTO moc.licenses(moc_revision_id,applies_to_design,applies_to_instructions,license_type,license_url,license_text,commercial_use_allowed,redistribution_allowed,modification_allowed,attribution_required)
        VALUES(v_revision_id,COALESCE((p_body->>'applies_to_design')::boolean,true),COALESCE((p_body->>'applies_to_instructions')::boolean,false),upper(p_body->>'license_type')::moc.license_type,p_body->>'license_url',p_body->>'license_text',
            NULLIF(p_body->>'commercial_use_allowed','')::boolean,NULLIF(p_body->>'redistribution_allowed','')::boolean,NULLIF(p_body->>'modification_allowed','')::boolean,NULLIF(p_body->>'attribution_required','')::boolean)
        RETURNING to_jsonb(moc.licenses) INTO v_result;
        UPDATE moc.mocs SET edit_revision=edit_revision+1,updated_at=now() WHERE moc_id=v_moc_id;

    WHEN 'list_moc_subassemblies' THEN
        v_revision_id:=(p_params->>'revision_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND (identity.can_view_owner(v_user,v_owner,'MOCS') OR r.status='PUBLISHED')) THEN RAISE EXCEPTION 'MOC revision not found' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.sort_order NULLS LAST,s.subassembly_id),'[]'::jsonb) INTO v_result FROM moc.subassemblies s WHERE s.moc_revision_id=v_revision_id;

    WHEN 'create_moc_subassembly' THEN
        v_revision_id:=(p_params->>'revision_id')::uuid;
        IF NOT identity.can_manage_owner(v_user,v_owner,'MOCS') OR NOT EXISTS(SELECT 1 FROM moc.revisions r WHERE r.moc_revision_id=v_revision_id AND r.moc_id=v_moc_id AND r.status='DRAFT') THEN RAISE EXCEPTION 'Editable MOC revision not found or forbidden' USING ERRCODE='P0404'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        INSERT INTO moc.subassemblies(moc_revision_id,parent_subassembly_id,subassembly_name,sort_order)
        VALUES(v_revision_id,NULLIF(p_body->>'parent_subassembly_id','')::uuid,p_body->>'name',NULLIF(p_body->>'sort_order','')::integer)
        RETURNING to_jsonb(moc.subassemblies) INTO v_result;
        UPDATE moc.mocs SET edit_revision=edit_revision+1,updated_at=now() WHERE moc_id=v_moc_id;

    WHEN 'list_moc_forks' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.forked_at),'[]'::jsonb) INTO v_result FROM moc.forks f WHERE f.source_moc_id=v_moc_id;

    WHEN 'fork_moc' THEN
        IF NOT EXISTS(SELECT 1 FROM moc.mocs WHERE moc_id=v_moc_id AND forks_allowed AND visibility IN('PUBLIC','UNLISTED')) THEN RAISE EXCEPTION 'MOC cannot be forked' USING ERRCODE='P0403'; END IF;
        SELECT moc_revision_id INTO v_source_revision FROM moc.revisions WHERE moc_id=v_moc_id AND status='PUBLISHED' ORDER BY revision_number DESC LIMIT 1;
        IF v_source_revision IS NULL THEN RAISE EXCEPTION 'MOC has no published revision to fork' USING ERRCODE='P0409'; END IF;
        v_result:=api.moc_minifig_operation('create_moc','{}',jsonb_build_object('name',COALESCE(p_body->>'name',(SELECT title||' Fork' FROM moc.mocs WHERE moc_id=v_moc_id)),'description',p_body->>'description','visibility','PRIVATE'),NULL);
        v_created_item_num:=v_result->>'item_num';
        SELECT m.moc_id INTO v_source_moc FROM catalog.items i JOIN moc.mocs m USING(catalog_item_id) WHERE i.item_num=v_created_item_num;
        INSERT INTO moc.forks(source_moc_id,source_revision_id,forked_moc_id,forked_by_user_id) VALUES(v_moc_id,v_source_revision,v_source_moc,v_user);
        v_result:=v_result || jsonb_build_object('forked_from_item_num',v_item_num,'source_revision_id',v_source_revision);

    /* ---------------------------------------------------------------------
     * Custom/canonical minifig lifecycle
     * ------------------------------------------------------------------ */
    WHEN 'create_custom_minifig' THEN
        v_item_num:='CMF-' || upper(substr(replace(app.uuid_v7()::text,'-',''),1,12));
        INSERT INTO catalog.items(item_kind,item_num,canonical_name,status) VALUES('MINIFIGURE',v_item_num,p_body->>'name','ACTIVE') RETURNING catalog_item_id INTO v_catalog_id;
        INSERT INTO catalog.minifigures(catalog_item_id) VALUES(v_catalog_id);
        INSERT INTO definition.custom_minifigs(catalog_item_id,owner_id,created_by_user_id,visibility,description)
        VALUES(v_catalog_id,v_owner,v_user,COALESCE(upper(NULLIF(p_body->>'visibility',''))::definition.custom_visibility,'PRIVATE'),p_body->>'description')
        RETURNING custom_minifig_id,edit_revision INTO v_custom_id,v_revision;
        INSERT INTO definition.inventory_definitions(catalog_item_id,definition_kind) VALUES(v_catalog_id,'MINIFIG_COMPOSITION') RETURNING inventory_definition_id INTO v_def_id;
        INSERT INTO definition.inventory_versions(inventory_definition_id,semantic_version,status,created_by_user_id) VALUES(v_def_id,1,'DRAFT',v_user) RETURNING inventory_version_id INTO v_version_id;
        INSERT INTO definition.minifig_compositions(inventory_version_id) VALUES(v_version_id);
        RETURN jsonb_build_object('item_num',v_item_num,'name',p_body->>'name','revision',v_revision,'_etag',api.etag_for_revision(v_revision),'data',jsonb_build_object('custom',true,'visibility',COALESCE(upper(NULLIF(p_body->>'visibility','')),'PRIVATE')));

    WHEN 'get_minifig','get_minifig_composition','patch_minifig_composition','create_minifig_composition_version','list_minifig_composition_versions','get_minifig_composition_version','delete_custom_minifig','restore_custom_minifig','get_minifig_market' THEN
        v_item_num:=NULLIF(p_params->>'item_num','');
        SELECT i.catalog_item_id,cm.custom_minifig_id,cm.owner_id,cm.edit_revision,
               CASE WHEN cm.custom_minifig_id IS NULL THEN (i.status NOT IN('ARCHIVED','UNRESOLVED_CUSTOM'))
                    ELSE (cm.archived_at IS NULL AND (cm.visibility IN('PUBLIC','UNLISTED') OR identity.can_view_owner(v_user,cm.owner_id,'COLLECTION') OR (cm.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,cm.owner_id,'COLLECTION')))) END
        INTO v_catalog_id,v_custom_id,v_owner,v_revision,v_visible
        FROM catalog.items i LEFT JOIN definition.custom_minifigs cm USING(catalog_item_id)
        WHERE i.item_num=v_item_num AND i.item_kind='MINIFIGURE';
        IF v_catalog_id IS NULL THEN RAISE EXCEPTION 'Minifigure not found' USING ERRCODE='P0404'; END IF;
        IF p_operation<>'restore_custom_minifig' AND NOT v_visible THEN RAISE EXCEPTION 'Minifigure not found' USING ERRCODE='P0404'; END IF;
    END CASE;

    IF p_operation='get_minifig' THEN
        SELECT jsonb_strip_nulls(jsonb_build_object('item_num',i.item_num,'name',i.canonical_name,'revision',COALESCE(cm.edit_revision,1),'_etag',api.etag_for_revision(COALESCE(cm.edit_revision,1)),
            'data',jsonb_build_object('lego_minifig_id',mf.lego_minifig_id,'theme_id',mf.theme_id,'custom',cm.custom_minifig_id IS NOT NULL,'visibility',cm.visibility::text,'description',cm.description,'archived_at',cm.archived_at)))
        INTO v_result FROM catalog.items i JOIN catalog.minifigures mf USING(catalog_item_id) LEFT JOIN definition.custom_minifigs cm USING(catalog_item_id) WHERE i.catalog_item_id=v_catalog_id;
        RETURN v_result;
    ELSIF p_operation IN ('delete_custom_minifig','restore_custom_minifig') THEN
        IF v_custom_id IS NULL THEN RAISE EXCEPTION 'Canonical minifigures cannot be retired/restored by normal users' USING ERRCODE='P0403'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE definition.custom_minifigs SET archived_at=CASE WHEN p_operation='delete_custom_minifig' THEN COALESCE(archived_at,now()) ELSE NULL END,edit_revision=edit_revision+1,updated_at=now() WHERE custom_minifig_id=v_custom_id;
        RETURN jsonb_build_object('item_num',v_item_num,CASE WHEN p_operation='delete_custom_minifig' THEN 'archived' ELSE 'restored' END,true);
    ELSIF p_operation IN ('get_minifig_composition','patch_minifig_composition','create_minifig_composition_version','list_minifig_composition_versions','get_minifig_composition_version') THEN
        SELECT inventory_definition_id INTO v_def_id FROM definition.inventory_definitions WHERE catalog_item_id=v_catalog_id AND definition_kind='MINIFIG_COMPOSITION';
        IF v_def_id IS NULL THEN RAISE EXCEPTION 'Minifigure composition definition not found' USING ERRCODE='P0404'; END IF;

        IF p_operation='list_minifig_composition_versions' THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object('version',v.semantic_version,'status',v.status::text,'semantic_hash',CASE WHEN v.semantic_hash IS NULL THEN NULL ELSE encode(v.semantic_hash,'hex') END) ORDER BY v.semantic_version DESC),'[]'::jsonb)
            INTO v_result FROM definition.inventory_versions v WHERE v.inventory_definition_id=v_def_id AND v.status='FINALIZED'; RETURN v_result;
        ELSIF p_operation='get_minifig_composition_version' THEN
            SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions WHERE inventory_definition_id=v_def_id AND semantic_version=(p_params->>'version')::integer AND status='FINALIZED';
        ELSE
            IF v_custom_id IS NOT NULL AND identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN
                SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions WHERE inventory_definition_id=v_def_id ORDER BY (status='DRAFT') DESC,semantic_version DESC LIMIT 1;
            ELSE
                SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions WHERE inventory_definition_id=v_def_id AND status='FINALIZED' ORDER BY semantic_version DESC LIMIT 1;
            END IF;
        END IF;
        IF v_version_id IS NULL THEN RAISE EXCEPTION 'Minifigure composition not found' USING ERRCODE='P0404'; END IF;

        IF p_operation='patch_minifig_composition' THEN
            IF v_custom_id IS NULL OR NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Canonical minifigure composition is read-only' USING ERRCODE='P0403'; END IF;
            PERFORM api.assert_if_match(p_if_match,v_revision);
            IF (SELECT status FROM definition.inventory_versions WHERE inventory_version_id=v_version_id)<>'DRAFT' THEN RAISE EXCEPTION 'No editable composition draft exists' USING ERRCODE='P0409'; END IF;
            SELECT minifig_composition_id INTO v_custom_id FROM definition.minifig_compositions WHERE inventory_version_id=v_version_id;
            DELETE FROM definition.minifig_structural_components WHERE minifig_composition_id=v_custom_id;
            DELETE FROM definition.minifig_accessories WHERE minifig_composition_id=v_custom_id;
            FOR v_component IN SELECT value FROM jsonb_array_elements(COALESCE(p_body->'components','[]'::jsonb)) LOOP
                v_kind:=upper(COALESCE(v_component->>'kind','STRUCTURAL'));
                IF v_kind='ACCESSORY' THEN
                    INSERT INTO definition.minifig_accessories(minifig_composition_id,part_variant_id,quantity,position_index)
                    VALUES(v_custom_id,(v_component->>'part_variant_id')::uuid,COALESCE((v_component->>'quantity')::integer,1),COALESCE((v_component->>'position_index')::integer,0));
                ELSE
                    INSERT INTO definition.minifig_structural_components(minifig_composition_id,minifig_role_id,semantic_role,side,position_index,part_variant_id,decorated_variant_id,quantity)
                    VALUES(v_custom_id,NULLIF(v_component->>'minifig_role_id','')::integer,COALESCE(v_component->>'role',v_component->>'semantic_role'),upper(NULLIF(v_component->>'side','')),COALESCE((v_component->>'position_index')::integer,0),(v_component->>'part_variant_id')::uuid,NULLIF(v_component->>'decorated_variant_id','')::uuid,COALESCE((v_component->>'quantity')::integer,1));
                END IF;
            END LOOP;
            UPDATE definition.custom_minifigs SET edit_revision=edit_revision+1,updated_at=now() WHERE custom_minifig_id=(SELECT custom_minifig_id FROM definition.custom_minifigs WHERE catalog_item_id=v_catalog_id) RETURNING edit_revision INTO v_revision;
        ELSIF p_operation='create_minifig_composition_version' THEN
            IF v_custom_id IS NULL OR NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Canonical minifigure composition is read-only' USING ERRCODE='P0403'; END IF;
            PERFORM api.assert_if_match(p_if_match,v_revision);
            SELECT inventory_version_id,semantic_version INTO v_version_id,v_semantic FROM definition.inventory_versions WHERE inventory_definition_id=v_def_id AND status='DRAFT' ORDER BY semantic_version DESC LIMIT 1 FOR UPDATE;
            IF v_version_id IS NULL THEN RAISE EXCEPTION 'No editable composition draft exists' USING ERRCODE='P0409'; END IF;
            SELECT digest(convert_to(jsonb_build_object(
                'structural',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.position_index,s.minifig_component_id) FROM definition.minifig_structural_components s JOIN definition.minifig_compositions c USING(minifig_composition_id) WHERE c.inventory_version_id=v_version_id),'[]'::jsonb),
                'accessories',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.position_index,a.minifig_accessory_id) FROM definition.minifig_accessories a JOIN definition.minifig_compositions c USING(minifig_composition_id) WHERE c.inventory_version_id=v_version_id),'[]'::jsonb)
            )::text,'UTF8'),'sha256') INTO v_hash;
            UPDATE definition.inventory_versions SET semantic_hash=v_hash,status='FINALIZED',finalized_at=now(),last_seen_at=now() WHERE inventory_version_id=v_version_id;
            INSERT INTO definition.inventory_versions(inventory_definition_id,semantic_version,status,created_by_user_id) VALUES(v_def_id,v_semantic+1,'DRAFT',v_user) RETURNING inventory_version_id INTO v_new_version_id;
            INSERT INTO definition.minifig_compositions(inventory_version_id) VALUES(v_new_version_id) RETURNING minifig_composition_id INTO v_new_revision_id;
            INSERT INTO definition.minifig_structural_components(minifig_composition_id,minifig_role_id,semantic_role,side,position_index,part_variant_id,decorated_variant_id,quantity)
            SELECT v_new_revision_id,s.minifig_role_id,s.semantic_role,s.side,s.position_index,s.part_variant_id,s.decorated_variant_id,s.quantity FROM definition.minifig_structural_components s JOIN definition.minifig_compositions c USING(minifig_composition_id) WHERE c.inventory_version_id=v_version_id;
            INSERT INTO definition.minifig_accessories(minifig_composition_id,part_variant_id,quantity,position_index)
            SELECT v_new_revision_id,a.part_variant_id,a.quantity,a.position_index FROM definition.minifig_accessories a JOIN definition.minifig_compositions c USING(minifig_composition_id) WHERE c.inventory_version_id=v_version_id;
            UPDATE definition.custom_minifigs SET edit_revision=edit_revision+1,updated_at=now() WHERE custom_minifig_id=v_custom_id RETURNING edit_revision INTO v_revision;
            RETURN jsonb_build_object('version',v_semantic,'etag',api.etag_for_revision(v_revision),'semantic_hash',encode(v_hash,'hex'));
        END IF;

        SELECT jsonb_build_object('item_num',v_item_num,'version',v.semantic_version,'status',v.status::text,'revision',COALESCE(cm.edit_revision,1),'_etag',api.etag_for_revision(COALESCE(cm.edit_revision,1)),
            'components',COALESCE((SELECT jsonb_agg(x ORDER BY (x->>'position_index')::integer) FROM (
                SELECT jsonb_strip_nulls(jsonb_build_object('kind','STRUCTURAL','role',s.semantic_role,'minifig_role_id',s.minifig_role_id,'side',s.side,'position_index',s.position_index,'part_variant_id',s.part_variant_id,'decorated_variant_id',s.decorated_variant_id,'quantity',s.quantity)) x
                FROM definition.minifig_structural_components s JOIN definition.minifig_compositions c USING(minifig_composition_id) WHERE c.inventory_version_id=v.inventory_version_id
                UNION ALL
                SELECT jsonb_build_object('kind','ACCESSORY','role','ACCESSORY','position_index',a.position_index,'part_variant_id',a.part_variant_id,'quantity',a.quantity)
                FROM definition.minifig_accessories a JOIN definition.minifig_compositions c USING(minifig_composition_id) WHERE c.inventory_version_id=v.inventory_version_id
            ) q),'[]'::jsonb)) INTO v_result
        FROM definition.inventory_versions v LEFT JOIN definition.custom_minifigs cm ON cm.catalog_item_id=v_catalog_id WHERE v.inventory_version_id=v_version_id;
        RETURN v_result;
    ELSIF p_operation='get_minifig_market' THEN
        SELECT jsonb_build_object('item_num',v_item_num,'data',jsonb_build_object('observations',COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.observed_at DESC),'[]'::jsonb))) INTO v_result
        FROM marketplace.market_price_observations m WHERE m.catalog_item_id=v_catalog_id AND (NULLIF(p_params->>'condition','') IS NULL OR m.condition::text=upper(p_params->>'condition'));
        RETURN v_result;
    END IF;

    RETURN COALESCE(v_result,'null'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.moc_minifig_operation(text,jsonb,jsonb,text) FROM PUBLIC;

\echo '[PASS] 5250_api_moc_minifig.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5250_api_moc_minifig.sql');
