/*
===============================================================================
 File:           5000_function/5200_api/5240_api_wanted.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Implement complete Wishlist and Build Goal lifecycle API
                 operations, including gift reservations, satisfaction,
                 archive/restore and inventory allocation.
 Depends On:     api.current_user_owner_id()
                 api.assert_if_match()
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
                 identity.can_view_family_shared_owner()
                 wanted.wishlists
                 wanted.wishlist_entries
                 wanted.wishlist_reservations
                 wanted.build_goals
                 wanted.build_allocations
                 collection.entries
                 catalog.items
                 catalog.part_variants
                 definition.inventory_versions
                 definition.requirement_groups
                 definition.requirement_options
 Creates:        api.wanted_operation()
 Key Rules:      Wishlist intent remains separate from Build Goal shortages.
                 Surprise reservations remain hidden from the wishlist owner.
                 Only the reserver can release their reservation. Satisfaction
                 is retained as lifecycle state. Build allocations reserve but
                 do not transfer ownership.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5240_api_wanted.sql',
    ARRAY[
        'api.current_user_owner_id()',
        'api.assert_if_match()',
        'identity.current_user_id()',
        'identity.can_view_owner()',
        'identity.can_manage_owner()',
        'identity.can_view_family_shared_owner()',
        'wanted.wishlists',
        'wanted.wishlist_entries',
        'wanted.wishlist_reservations',
        'wanted.build_goals',
        'wanted.build_allocations',
        'collection.entries',
        'catalog.items',
        'catalog.part_variants',
        'definition.inventory_versions',
        'definition.requirement_groups',
        'definition.requirement_options'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.wanted_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb,
    p_body jsonb DEFAULT '{}'::jsonb,
    p_if_match text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, identity, wanted, collection, catalog, definition
AS $$
DECLARE
    v_user uuid := identity.current_user_id();
    v_personal_owner uuid := api.current_user_owner_id();
    v_owner uuid;
    v_wishlist_id uuid;
    v_entry_id uuid;
    v_goal_id uuid;
    v_catalog_item_id uuid;
    v_part_variant_id uuid;
    v_version_id uuid;
    v_revision bigint;
    v_quantity integer;
    v_current integer;
    v_result jsonb;
    v_limit integer := LEAST(GREATEST(COALESCE((p_params->>'limit')::integer, 50),1),200);
    v_cursor uuid := NULLIF(p_params->>'cursor','')::uuid;
    v_allocation_id bigint;
BEGIN
    CASE p_operation
    /* ---------------------------------------------------------------------
     * Wishlists
     * ------------------------------------------------------------------ */
    WHEN 'list_wishlists' THEN
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'wishlist_id',w.wishlist_id,'owner_id',w.owner_id,'name',w.wishlist_name,'description',w.description,
            'visibility',w.visibility::text,'is_default',w.is_default,'revision',w.edit_revision,
            'etag',api.etag_for_revision(w.edit_revision),'created_at',w.created_at,'updated_at',w.updated_at,'archived_at',w.archived_at
        )) ORDER BY w.wishlist_id),'[]'::jsonb) INTO v_result
        FROM (
            SELECT * FROM wanted.wishlists w
            WHERE w.archived_at IS NULL
              AND (v_cursor IS NULL OR w.wishlist_id>v_cursor)
              AND (
                    w.visibility='PUBLIC'
                    OR identity.can_view_owner(v_user,w.owner_id,'WISHLIST')
                    OR (w.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,w.owner_id,'WISHLIST'))
              )
            ORDER BY w.wishlist_id LIMIT v_limit
        ) w;

    WHEN 'create_wishlist' THEN
        v_owner:=COALESCE(NULLIF(p_body->>'owner_id','')::uuid,v_personal_owner);
        IF NOT identity.can_manage_owner(v_user,v_owner,'WISHLIST') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        INSERT INTO wanted.wishlists(owner_id,wishlist_name,description,visibility,is_default)
        VALUES(v_owner,p_body->>'name',p_body->>'description',COALESCE(upper(NULLIF(p_body->>'visibility',''))::wanted.visibility,'PRIVATE'),COALESCE((p_body->>'is_default')::boolean,false))
        RETURNING wishlist_id,edit_revision INTO v_wishlist_id,v_revision;
        v_result:=jsonb_build_object('wishlist_id',v_wishlist_id,'name',p_body->>'name','revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'get_wishlist' THEN
        v_wishlist_id:=(p_params->>'wishlist_id')::uuid;
        SELECT owner_id INTO v_owner FROM wanted.wishlists WHERE wishlist_id=v_wishlist_id;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Wishlist not found' USING ERRCODE='P0404'; END IF;
        IF NOT EXISTS(SELECT 1 FROM wanted.wishlists w WHERE w.wishlist_id=v_wishlist_id AND (w.visibility='PUBLIC' OR identity.can_view_owner(v_user,w.owner_id,'WISHLIST') OR (w.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,w.owner_id,'WISHLIST')))) THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT jsonb_strip_nulls(jsonb_build_object('wishlist_id',w.wishlist_id,'owner_id',w.owner_id,'name',w.wishlist_name,'description',w.description,'visibility',w.visibility::text,
            'is_default',w.is_default,'revision',w.edit_revision,'_etag',api.etag_for_revision(w.edit_revision),'created_at',w.created_at,'updated_at',w.updated_at,'archived_at',w.archived_at))
        INTO v_result FROM wanted.wishlists w WHERE w.wishlist_id=v_wishlist_id;

    WHEN 'patch_wishlist' THEN
        v_wishlist_id:=(p_params->>'wishlist_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM wanted.wishlists WHERE wishlist_id=v_wishlist_id AND archived_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Wishlist not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'WISHLIST') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE wanted.wishlists SET
            wishlist_name=CASE WHEN p_body?'name' THEN p_body->>'name' ELSE wishlist_name END,
            description=CASE WHEN p_body?'description' THEN p_body->>'description' ELSE description END,
            visibility=CASE WHEN p_body?'visibility' THEN upper(p_body->>'visibility')::wanted.visibility ELSE visibility END,
            is_default=CASE WHEN p_body?'is_default' THEN (p_body->>'is_default')::boolean ELSE is_default END,
            edit_revision=edit_revision+1,updated_at=now()
        WHERE wishlist_id=v_wishlist_id;
        SELECT api.wanted_operation('get_wishlist',jsonb_build_object('wishlist_id',v_wishlist_id),'{}',NULL) INTO v_result;

    WHEN 'archive_wishlist' THEN
        v_wishlist_id:=(p_params->>'wishlist_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM wanted.wishlists WHERE wishlist_id=v_wishlist_id AND archived_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Wishlist not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'WISHLIST') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE wanted.wishlists SET archived_at=now(),is_default=false,edit_revision=edit_revision+1,updated_at=now() WHERE wishlist_id=v_wishlist_id;
        v_result:=jsonb_build_object('archived',true,'wishlist_id',v_wishlist_id);

    WHEN 'restore_wishlist' THEN
        v_wishlist_id:=(p_params->>'wishlist_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM wanted.wishlists WHERE wishlist_id=v_wishlist_id AND archived_at IS NOT NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Archived wishlist not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'WISHLIST') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE wanted.wishlists SET archived_at=NULL,edit_revision=edit_revision+1,updated_at=now() WHERE wishlist_id=v_wishlist_id;
        SELECT api.wanted_operation('get_wishlist',jsonb_build_object('wishlist_id',v_wishlist_id),'{}',NULL) INTO v_result;

    WHEN 'list_wishlist_entries' THEN
        v_wishlist_id:=(p_params->>'wishlist_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM wanted.wishlists w WHERE w.wishlist_id=v_wishlist_id AND w.archived_at IS NULL AND (w.visibility='PUBLIC' OR identity.can_view_owner(v_user,w.owner_id,'WISHLIST') OR (w.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,w.owner_id,'WISHLIST')))) THEN RAISE EXCEPTION 'Wishlist not found or forbidden' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'wishlist_entry_id',e.wishlist_entry_id,'wishlist_id',e.wishlist_id,'item_num',i.item_num,'part_variant_id',e.part_variant_id,
            'preferred_inventory_version_id',e.preferred_inventory_version_id,'desired_quantity',e.desired_quantity,'satisfied_quantity',e.satisfied_quantity,
            'priority',e.priority,'target_unit_price',e.target_unit_price,'currency',e.currency,'status',e.status::text,'notes',e.notes,
            'revision',e.edit_revision,'etag',api.etag_for_revision(e.edit_revision),'created_at',e.created_at,'updated_at',e.updated_at,'satisfied_at',e.satisfied_at,'archived_at',e.archived_at
        )) ORDER BY e.wishlist_entry_id),'[]'::jsonb) INTO v_result
        FROM wanted.wishlist_entries e LEFT JOIN catalog.items i ON i.catalog_item_id=e.catalog_item_id
        WHERE e.wishlist_id=v_wishlist_id AND (v_cursor IS NULL OR e.wishlist_entry_id>v_cursor)
        LIMIT v_limit;

    WHEN 'create_wishlist_entry' THEN
        v_wishlist_id:=(p_params->>'wishlist_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM wanted.wishlists WHERE wishlist_id=v_wishlist_id AND archived_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Wishlist not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'WISHLIST') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        IF NULLIF(p_body->>'item_num','') IS NOT NULL THEN SELECT catalog_item_id INTO v_catalog_item_id FROM catalog.items WHERE item_num=p_body->>'item_num' AND status<>'ARCHIVED'; END IF;
        v_part_variant_id:=NULLIF(p_body->>'part_variant_id','')::uuid;
        IF num_nonnulls(v_catalog_item_id,v_part_variant_id)<>1 THEN RAISE EXCEPTION 'Exactly one target is required' USING ERRCODE='22023'; END IF;
        IF NULLIF(p_body->>'preferred_inventory_version','') IS NOT NULL THEN
            SELECT inventory_version_id INTO v_version_id FROM definition.inventory_versions WHERE semantic_version=(p_body->>'preferred_inventory_version')::integer AND status='FINALIZED' ORDER BY created_at DESC LIMIT 1;
        ELSE v_version_id:=NULLIF(p_body->>'preferred_inventory_version_id','')::uuid; END IF;
        INSERT INTO wanted.wishlist_entries(wishlist_id,catalog_item_id,part_variant_id,preferred_inventory_version_id,desired_quantity,priority,target_unit_price,currency,notes)
        VALUES(v_wishlist_id,v_catalog_item_id,v_part_variant_id,v_version_id,COALESCE((p_body->>'desired_quantity')::integer,1),COALESCE((p_body->>'priority')::smallint,3),NULLIF(p_body->>'target_price','')::app.money_amount,NULLIF(p_body->>'currency','')::app.currency_code,p_body->>'notes')
        RETURNING wishlist_entry_id,edit_revision INTO v_entry_id,v_revision;
        UPDATE wanted.wishlists SET edit_revision=edit_revision+1,updated_at=now() WHERE wishlist_id=v_wishlist_id;
        v_result:=jsonb_build_object('wishlist_entry_id',v_entry_id,'wishlist_id',v_wishlist_id,'revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'patch_wishlist_entry' THEN
        v_entry_id:=(p_params->>'wishlist_entry_id')::uuid;
        SELECT w.owner_id,e.edit_revision INTO v_owner,v_revision FROM wanted.wishlist_entries e JOIN wanted.wishlists w USING(wishlist_id) WHERE e.wishlist_entry_id=v_entry_id FOR UPDATE OF e;
        IF NOT FOUND THEN RAISE EXCEPTION 'Wishlist entry not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'WISHLIST') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE wanted.wishlist_entries SET
            desired_quantity=CASE WHEN p_body?'desired_quantity' THEN (p_body->>'desired_quantity')::integer ELSE desired_quantity END,
            priority=CASE WHEN p_body?'priority' THEN (p_body->>'priority')::smallint ELSE priority END,
            target_unit_price=CASE WHEN p_body?'target_price' THEN NULLIF(p_body->>'target_price','')::app.money_amount ELSE target_unit_price END,
            currency=CASE WHEN p_body?'currency' THEN NULLIF(p_body->>'currency','')::app.currency_code ELSE currency END,
            notes=CASE WHEN p_body?'notes' THEN p_body->>'notes' ELSE notes END,
            edit_revision=edit_revision+1,updated_at=now()
        WHERE wishlist_entry_id=v_entry_id;
        SELECT edit_revision INTO v_revision FROM wanted.wishlist_entries WHERE wishlist_entry_id=v_entry_id;
        v_result:=jsonb_build_object('wishlist_entry_id',v_entry_id,'revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'archive_wishlist_entry' THEN
        v_entry_id:=(p_params->>'wishlist_entry_id')::uuid;
        SELECT w.owner_id,e.edit_revision INTO v_owner,v_revision FROM wanted.wishlist_entries e JOIN wanted.wishlists w USING(wishlist_id) WHERE e.wishlist_entry_id=v_entry_id FOR UPDATE OF e;
        IF NOT FOUND THEN RAISE EXCEPTION 'Wishlist entry not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'WISHLIST') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE wanted.wishlist_entries SET status='ARCHIVED',archived_at=now(),edit_revision=edit_revision+1,updated_at=now() WHERE wishlist_entry_id=v_entry_id;
        v_result:=jsonb_build_object('archived',true,'wishlist_entry_id',v_entry_id);

    WHEN 'list_wishlist_reservations' THEN
        v_entry_id:=(p_params->>'wishlist_entry_id')::uuid;
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'reservation_id',r.wishlist_reservation_id,'wishlist_entry_id',r.wishlist_entry_id,'quantity',r.quantity,
            'is_surprise',r.hidden_from_owner,'reserved_at',r.reserved_at,'expires_at',r.expires_at,'released_at',r.released_at
        ) ORDER BY r.reserved_at),'[]'::jsonb) INTO v_result
        FROM wanted.wishlist_reservations r
        JOIN wanted.wishlist_entries e USING(wishlist_entry_id)
        JOIN wanted.wishlists w USING(wishlist_id)
        WHERE r.wishlist_entry_id=v_entry_id
          AND (r.reserved_by_user_id=v_user OR (NOT r.hidden_from_owner AND identity.can_view_owner(v_user,w.owner_id,'WISHLIST')));

    WHEN 'reserve_wishlist_entry' THEN
        v_entry_id:=(p_params->>'wishlist_entry_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM wanted.wishlist_entries e JOIN wanted.wishlists w USING(wishlist_id) WHERE e.wishlist_entry_id=v_entry_id AND e.status IN('ACTIVE','PARTIALLY_SATISFIED') AND w.archived_at IS NULL AND (w.visibility='PUBLIC' OR identity.can_view_owner(v_user,w.owner_id,'WISHLIST') OR (w.visibility='FAMILY' AND identity.can_view_family_shared_owner(v_user,w.owner_id,'WISHLIST')))) THEN RAISE EXCEPTION 'Wishlist entry not found or not reservable' USING ERRCODE='P0404'; END IF;
        INSERT INTO wanted.wishlist_reservations(wishlist_entry_id,reserved_by_user_id,quantity,hidden_from_owner,expires_at)
        VALUES(v_entry_id,v_user,COALESCE((p_body->>'quantity')::integer,1),COALESCE((p_body->>'is_surprise')::boolean,true),NULLIF(p_body->>'expires_at','')::timestamptz)
        RETURNING jsonb_build_object('reservation_id',wishlist_reservation_id,'wishlist_entry_id',wishlist_entry_id,'quantity',quantity,'is_surprise',hidden_from_owner,'reserved_at',reserved_at,'expires_at',expires_at) INTO v_result;

    WHEN 'release_wishlist_reservation' THEN
        UPDATE wanted.wishlist_reservations SET released_at=COALESCE(released_at,now())
        WHERE wishlist_reservation_id=(p_params->>'reservation_id')::uuid AND reserved_by_user_id=v_user AND released_at IS NULL;
        IF NOT FOUND THEN RAISE EXCEPTION 'Active reservation not found for current user' USING ERRCODE='P0404'; END IF;
        v_result:=jsonb_build_object('released',true,'reservation_id',p_params->>'reservation_id');

    WHEN 'satisfy_wishlist_entry' THEN
        v_entry_id:=(p_params->>'wishlist_entry_id')::uuid;
        SELECT w.owner_id,e.edit_revision,e.desired_quantity,e.satisfied_quantity INTO v_owner,v_revision,v_quantity,v_current
        FROM wanted.wishlist_entries e JOIN wanted.wishlists w USING(wishlist_id) WHERE e.wishlist_entry_id=v_entry_id FOR UPDATE OF e;
        IF NOT FOUND THEN RAISE EXCEPTION 'Wishlist entry not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'WISHLIST') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        v_current:=LEAST(v_quantity,v_current+COALESCE((p_body->>'quantity')::integer,v_quantity-v_current));
        UPDATE wanted.wishlist_entries SET satisfied_quantity=v_current,
            status=CASE WHEN v_current>=desired_quantity THEN 'SATISFIED'::wanted.entry_status ELSE 'PARTIALLY_SATISFIED'::wanted.entry_status END,
            satisfied_at=CASE WHEN v_current>=desired_quantity THEN COALESCE(satisfied_at,now()) ELSE satisfied_at END,
            edit_revision=edit_revision+1,updated_at=now() WHERE wishlist_entry_id=v_entry_id;
        SELECT edit_revision INTO v_revision FROM wanted.wishlist_entries WHERE wishlist_entry_id=v_entry_id;
        v_result:=jsonb_build_object('wishlist_entry_id',v_entry_id,'satisfied_quantity',v_current,'revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    /* ---------------------------------------------------------------------
     * Build goals
     * ------------------------------------------------------------------ */
    WHEN 'list_build_goals' THEN
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'build_goal_id',g.build_goal_id,'owner_id',g.owner_id,'name',g.goal_name,'notes',g.notes,'build_goal_type',g.build_goal_type::text,
            'target_item_num',i.item_num,'inventory_version_id',g.inventory_version_id,'collection_instance_id',g.collection_instance_id,
            'target_quantity',g.target_quantity,'status',g.status::text,'include_family_inventory',g.include_family_inventory,
            'include_contained_parts',g.include_contained_parts,'include_allocated_parts',g.include_allocated_parts,'minifig_matching_mode',g.minifig_matching_mode::text,
            'revision',g.edit_revision,'etag',api.etag_for_revision(g.edit_revision),'created_at',g.created_at,'updated_at',g.updated_at,'completed_at',g.completed_at
        )) ORDER BY g.build_goal_id),'[]'::jsonb) INTO v_result
        FROM wanted.build_goals g JOIN catalog.items i ON i.catalog_item_id=g.target_catalog_item_id
        WHERE g.status<>'ARCHIVED' AND identity.can_view_owner(v_user,g.owner_id,'COLLECTION') AND (v_cursor IS NULL OR g.build_goal_id>v_cursor)
        LIMIT v_limit;

    WHEN 'create_build_goal' THEN
        v_owner:=COALESCE(NULLIF(p_body->>'owner_id','')::uuid,v_personal_owner);
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT catalog_item_id INTO v_catalog_item_id FROM catalog.items WHERE item_num=p_body->>'target_item_num' AND status<>'ARCHIVED';
        IF v_catalog_item_id IS NULL THEN RAISE EXCEPTION 'Target catalog item not found' USING ERRCODE='P0404'; END IF;
        v_version_id:=NULLIF(p_body->>'inventory_version_id','')::uuid;
        IF v_version_id IS NULL AND NULLIF(p_body->>'target_inventory_version','') IS NOT NULL THEN
            SELECT v.inventory_version_id INTO v_version_id FROM definition.inventory_versions v JOIN definition.inventory_definitions d USING(inventory_definition_id)
            WHERE d.catalog_item_id=v_catalog_item_id AND v.semantic_version=(p_body->>'target_inventory_version')::integer AND v.status='FINALIZED' ORDER BY v.created_at DESC LIMIT 1;
        END IF;
        IF v_version_id IS NULL THEN RAISE EXCEPTION 'Exact target inventory version is required' USING ERRCODE='22023'; END IF;
        INSERT INTO wanted.build_goals(owner_id,build_goal_type,target_catalog_item_id,inventory_version_id,collection_instance_id,target_quantity,status,include_family_inventory,include_contained_parts,include_allocated_parts,minifig_matching_mode,goal_name,notes)
        VALUES(v_owner,COALESCE(upper(NULLIF(p_body->>'build_goal_type',''))::wanted.build_goal_type,'BUILD_FROM_INVENTORY'),v_catalog_item_id,v_version_id,NULLIF(p_body->>'collection_instance_id','')::uuid,
            COALESCE((p_body->>'target_quantity')::integer,1),'PLANNED',COALESCE((p_body->>'include_family_inventory')::boolean,true),COALESCE((p_body->>'include_contained_parts')::boolean,true),COALESCE((p_body->>'include_allocated_parts')::boolean,false),
            COALESCE(upper(NULLIF(p_body->>'minifig_matching_mode',''))::wanted.minifig_matching_mode,'COMPLETE_ONLY'),p_body->>'name',p_body->>'notes')
        RETURNING build_goal_id,edit_revision INTO v_goal_id,v_revision;
        v_result:=jsonb_build_object('build_goal_id',v_goal_id,'revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'get_build_goal' THEN
        v_goal_id:=(p_params->>'build_goal_id')::uuid;
        SELECT owner_id INTO v_owner FROM wanted.build_goals WHERE build_goal_id=v_goal_id;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Build goal not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT jsonb_strip_nulls(jsonb_build_object('build_goal_id',g.build_goal_id,'owner_id',g.owner_id,'name',g.goal_name,'notes',g.notes,'build_goal_type',g.build_goal_type::text,'target_item_num',i.item_num,
            'inventory_version_id',g.inventory_version_id,'collection_instance_id',g.collection_instance_id,'target_quantity',g.target_quantity,'status',g.status::text,'revision',g.edit_revision,'_etag',api.etag_for_revision(g.edit_revision),
            'created_at',g.created_at,'updated_at',g.updated_at,'completed_at',g.completed_at)) INTO v_result
        FROM wanted.build_goals g JOIN catalog.items i ON i.catalog_item_id=g.target_catalog_item_id WHERE g.build_goal_id=v_goal_id;

    WHEN 'patch_build_goal' THEN
        v_goal_id:=(p_params->>'build_goal_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM wanted.build_goals WHERE build_goal_id=v_goal_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Build goal not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE wanted.build_goals SET goal_name=CASE WHEN p_body?'name' THEN p_body->>'name' ELSE goal_name END,
            notes=CASE WHEN p_body?'notes' THEN p_body->>'notes' ELSE notes END,
            target_quantity=CASE WHEN p_body?'target_quantity' THEN (p_body->>'target_quantity')::integer ELSE target_quantity END,
            status=CASE WHEN p_body?'status' THEN upper(p_body->>'status')::wanted.build_goal_status ELSE status END,
            include_family_inventory=CASE WHEN p_body?'include_family_inventory' THEN (p_body->>'include_family_inventory')::boolean ELSE include_family_inventory END,
            include_contained_parts=CASE WHEN p_body?'include_contained_parts' THEN (p_body->>'include_contained_parts')::boolean ELSE include_contained_parts END,
            include_allocated_parts=CASE WHEN p_body?'include_allocated_parts' THEN (p_body->>'include_allocated_parts')::boolean ELSE include_allocated_parts END,
            completed_at=CASE WHEN upper(COALESCE(p_body->>'status',status::text))='COMPLETE' THEN COALESCE(completed_at,now()) ELSE completed_at END,
            edit_revision=edit_revision+1,updated_at=now() WHERE build_goal_id=v_goal_id;
        SELECT api.wanted_operation('get_build_goal',jsonb_build_object('build_goal_id',v_goal_id),'{}',NULL) INTO v_result;

    WHEN 'archive_build_goal' THEN
        v_goal_id:=(p_params->>'build_goal_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM wanted.build_goals WHERE build_goal_id=v_goal_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Build goal not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE wanted.build_goals SET status='ARCHIVED',edit_revision=edit_revision+1,updated_at=now() WHERE build_goal_id=v_goal_id;
        v_result:=jsonb_build_object('archived',true,'build_goal_id',v_goal_id);

    WHEN 'get_build_goal_shortages' THEN
        v_goal_id:=(p_params->>'build_goal_id')::uuid;
        SELECT owner_id INTO v_owner FROM wanted.build_goals WHERE build_goal_id=v_goal_id;
        IF v_owner IS NULL OR NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Build goal not found or forbidden' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'requirement_group_id',g.requirement_group_id,'requirement_key',g.requirement_key,'required_quantity',g.required_quantity,
            'allocated_quantity',COALESCE(a.allocated_quantity,0),'shortage_quantity',GREATEST(g.required_quantity-COALESCE(a.allocated_quantity,0),0)
        ) ORDER BY g.sort_order NULLS LAST,g.requirement_group_id),'[]'::jsonb) INTO v_result
        FROM wanted.build_goals bg JOIN definition.requirement_groups g ON g.inventory_version_id=bg.inventory_version_id
        LEFT JOIN LATERAL (SELECT sum(ba.quantity)::integer allocated_quantity FROM wanted.build_allocations ba WHERE ba.build_goal_id=bg.build_goal_id AND ba.requirement_group_id=g.requirement_group_id AND ba.released_at IS NULL) a ON true
        WHERE bg.build_goal_id=v_goal_id AND GREATEST(g.required_quantity-COALESCE(a.allocated_quantity,0),0)>0;

    WHEN 'list_build_allocations' THEN
        v_goal_id:=(p_params->>'build_goal_id')::uuid;
        SELECT owner_id INTO v_owner FROM wanted.build_goals WHERE build_goal_id=v_goal_id;
        IF v_owner IS NULL OR NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Build goal not found or forbidden' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.allocated_at),'[]'::jsonb) INTO v_result FROM wanted.build_allocations a WHERE a.build_goal_id=v_goal_id;

    WHEN 'create_build_allocation' THEN
        v_goal_id:=(p_params->>'build_goal_id')::uuid;
        SELECT owner_id INTO v_owner FROM wanted.build_goals WHERE build_goal_id=v_goal_id AND status<>'ARCHIVED';
        IF v_owner IS NULL OR NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Build goal not found or forbidden' USING ERRCODE='P0404'; END IF;
        v_entry_id:=(p_body->>'inventory_item_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM collection.entries e WHERE e.collection_entry_id=v_entry_id AND identity.can_view_owner(v_user,e.owner_id,'COLLECTION') AND e.status='ACTIVE') THEN RAISE EXCEPTION 'Inventory item not available' USING ERRCODE='P0404'; END IF;
        INSERT INTO wanted.build_allocations(build_goal_id,collection_entry_id,requirement_group_id,quantity)
        VALUES(v_goal_id,v_entry_id,NULLIF(p_body->>'requirement_group_id','')::bigint,(p_body->>'quantity')::integer)
        RETURNING build_allocation_id INTO v_allocation_id;
        UPDATE wanted.build_goals SET status=CASE WHEN status='PLANNED' THEN 'RESERVING' ELSE status END,edit_revision=edit_revision+1,updated_at=now() WHERE build_goal_id=v_goal_id;
        v_result:=jsonb_build_object('build_allocation_id',v_allocation_id,'build_goal_id',v_goal_id,'inventory_item_id',v_entry_id);

    WHEN 'release_build_allocation' THEN
        v_goal_id:=(p_params->>'build_goal_id')::uuid;
        SELECT owner_id INTO v_owner FROM wanted.build_goals WHERE build_goal_id=v_goal_id;
        IF v_owner IS NULL OR NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Build goal not found or forbidden' USING ERRCODE='P0404'; END IF;
        UPDATE wanted.build_allocations SET released_at=COALESCE(released_at,now()) WHERE build_goal_id=v_goal_id AND build_allocation_id=(p_params->>'build_allocation_id')::bigint AND released_at IS NULL;
        IF NOT FOUND THEN RAISE EXCEPTION 'Active allocation not found' USING ERRCODE='P0404'; END IF;
        UPDATE wanted.build_goals SET edit_revision=edit_revision+1,updated_at=now() WHERE build_goal_id=v_goal_id;
        v_result:=jsonb_build_object('released',true,'build_allocation_id',p_params->>'build_allocation_id');

    ELSE
        RAISE EXCEPTION 'Unknown wanted API operation: %',p_operation USING ERRCODE='22023';
    END CASE;

    RETURN COALESCE(v_result,'null'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.wanted_operation(text,jsonb,jsonb,text) FROM PUBLIC;

\echo '[PASS] 5240_api_wanted.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5240_api_wanted.sql');
