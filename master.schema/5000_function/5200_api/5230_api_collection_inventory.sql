/*
===============================================================================
 File:           5000_function/5200_api/5230_api_collection_inventory.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Implement the user collection, inventory, physical-instance,
                 storage, acquisition, named-collection and assembly API surface.
 Depends On:     api.current_user_owner_id()
                 api.assert_if_match()
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
                 collection.collections
                 collection.collection_memberships
                 collection.entries
                 collection.instances
                 collection.instance_adjustments
                 collection.storage_locations
                 collection.storage_allocations
                 collection.acquisitions
                 collection.acquisition_items
                 catalog.items
                 catalog.part_variants
                 definition.inventory_versions
                 definition.requirement_groups
                 definition.requirement_options
 Creates:        api.collection_inventory_operation()
 Key Rules:      Catalog truth and owned state remain separate. Named collections
                 group owned entries but do not own them. All writes authorize
                 the actual persisted owner. Deletes are lifecycle archive/remove
                 operations, never canonical hard deletes. Version-sensitive
                 writes verify If-Match in the database.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5230_api_collection_inventory.sql',
    ARRAY[
        'api.current_user_owner_id()',
        'api.assert_if_match()',
        'identity.current_user_id()',
        'identity.can_view_owner()',
        'identity.can_manage_owner()',
        'collection.collections',
        'collection.collection_memberships',
        'collection.entries',
        'collection.instances',
        'collection.instance_adjustments',
        'collection.storage_locations',
        'collection.storage_allocations',
        'collection.acquisitions',
        'collection.acquisition_items',
        'catalog.items',
        'catalog.part_variants',
        'definition.inventory_versions',
        'definition.requirement_groups',
        'definition.requirement_options'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.collection_inventory_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb,
    p_body jsonb DEFAULT '{}'::jsonb,
    p_if_match text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, identity, collection, catalog, definition
AS $$
DECLARE
    v_user uuid := identity.current_user_id();
    v_personal_owner uuid := api.current_user_owner_id();
    v_owner uuid;
    v_entry_id uuid;
    v_instance_id uuid;
    v_collection_id uuid;
    v_storage_id uuid;
    v_catalog_item_id uuid;
    v_part_variant_id uuid;
    v_inventory_version_id uuid;
    v_revision bigint;
    v_quantity integer;
    v_limit integer := LEAST(GREATEST(COALESCE((p_params->>'limit')::integer, 50), 1), 200);
    v_cursor uuid := NULLIF(p_params->>'cursor','')::uuid;
    v_result jsonb;
    v_missing integer;
    rec record;
BEGIN
    CASE p_operation
    /* ---------------------------------------------------------------------
     * Inventory aggregate reads
     * ------------------------------------------------------------------ */
    WHEN 'list_inventory', 'list_inventory_sets', 'list_inventory_parts',
         'list_inventory_minifigs', 'list_inventory_mocs' THEN
        SELECT jsonb_build_object(
            'items', COALESCE(jsonb_agg(row_json ORDER BY collection_entry_id), '[]'::jsonb),
            'next_cursor', max(collection_entry_id)::text
        )
        INTO v_result
        FROM (
            SELECT e.collection_entry_id,
                   jsonb_strip_nulls(jsonb_build_object(
                       'inventory_item_id', e.collection_entry_id::text,
                       'owner_id', e.owner_id::text,
                       'item_num', i.item_num,
                       'part_variant_id', e.part_variant_id,
                       'item_kind', i.item_kind::text,
                       'name', i.canonical_name,
                       'quantity', e.quantity,
                       'status', e.status::text,
                       'revision', e.edit_revision,
                       'etag', api.etag_for_revision(e.edit_revision),
                       'created_at', e.created_at,
                       'updated_at', e.updated_at
                   )) AS row_json
              FROM collection.entries e
              LEFT JOIN catalog.items i ON i.catalog_item_id = e.catalog_item_id
             WHERE e.status = 'ACTIVE'
               AND identity.can_view_owner(v_user, e.owner_id, 'COLLECTION')
               AND (v_cursor IS NULL OR e.collection_entry_id > v_cursor)
               AND (
                    p_operation = 'list_inventory'
                    OR (p_operation = 'list_inventory_sets' AND i.item_kind = 'SET')
                    OR (p_operation = 'list_inventory_parts' AND (i.item_kind = 'PART' OR e.part_variant_id IS NOT NULL))
                    OR (p_operation = 'list_inventory_minifigs' AND i.item_kind = 'MINIFIGURE')
                    OR (p_operation = 'list_inventory_mocs' AND i.item_kind = 'MOC')
               )
             ORDER BY e.collection_entry_id
             LIMIT v_limit
        ) rows;

    WHEN 'create_inventory_item' THEN
        v_owner := COALESCE(NULLIF(p_body->>'owner_id','')::uuid, v_personal_owner);
        IF NOT identity.can_manage_owner(v_user, v_owner, 'COLLECTION') THEN
            RAISE EXCEPTION 'Collection owner is not manageable by the current user' USING ERRCODE='P0403';
        END IF;

        IF NULLIF(p_body->>'item_num','') IS NOT NULL THEN
            SELECT catalog_item_id INTO v_catalog_item_id
              FROM catalog.items
             WHERE item_num = p_body->>'item_num'
               AND status <> 'ARCHIVED';
            IF v_catalog_item_id IS NULL THEN
                RAISE EXCEPTION 'Catalog item not found' USING ERRCODE='P0404';
            END IF;
        END IF;
        v_part_variant_id := NULLIF(p_body->>'part_variant_id','')::uuid;
        IF num_nonnulls(v_catalog_item_id, v_part_variant_id) <> 1 THEN
            RAISE EXCEPTION 'Exactly one of item_num or part_variant_id is required' USING ERRCODE='22023';
        END IF;
        v_quantity := COALESCE((p_body->>'quantity')::integer, 1);
        IF v_quantity <= 0 THEN
            RAISE EXCEPTION 'quantity must be positive' USING ERRCODE='22023';
        END IF;

        INSERT INTO collection.entries(owner_id, catalog_item_id, part_variant_id, quantity)
        VALUES (v_owner, v_catalog_item_id, v_part_variant_id, v_quantity)
        RETURNING collection_entry_id, edit_revision INTO v_entry_id, v_revision;

        SELECT api.collection_inventory_operation(
            'get_inventory_item', jsonb_build_object('inventory_item_id', v_entry_id), '{}'::jsonb, NULL
        ) INTO v_result;

    WHEN 'get_inventory_item' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        SELECT e.owner_id INTO v_owner FROM collection.entries e WHERE e.collection_entry_id = v_entry_id;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_view_owner(v_user, v_owner, 'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT jsonb_strip_nulls(jsonb_build_object(
            'inventory_item_id', e.collection_entry_id::text,
            'owner_id', e.owner_id::text,
            'item_num', i.item_num,
            'part_variant_id', e.part_variant_id,
            'item_kind', i.item_kind::text,
            'name', i.canonical_name,
            'quantity', e.quantity,
            'status', e.status::text,
            'revision', e.edit_revision,
            '_etag', api.etag_for_revision(e.edit_revision),
            'created_at', e.created_at,
            'updated_at', e.updated_at,
            'archived_at', e.archived_at
        )) INTO v_result
        FROM collection.entries e
        LEFT JOIN catalog.items i ON i.catalog_item_id = e.catalog_item_id
        WHERE e.collection_entry_id = v_entry_id;

    WHEN 'patch_inventory_item' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        SELECT owner_id, edit_revision INTO v_owner, v_revision
          FROM collection.entries WHERE collection_entry_id = v_entry_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user, v_owner, 'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match, v_revision);
        UPDATE collection.entries
           SET quantity = CASE WHEN p_body ? 'quantity' THEN (p_body->>'quantity')::integer ELSE quantity END,
               status = CASE WHEN p_body ? 'status' THEN upper(p_body->>'status')::collection.entry_status ELSE status END,
               edit_revision = edit_revision + 1,
               updated_at = now(),
               archived_at = CASE WHEN upper(COALESCE(p_body->>'status', status::text)) = 'ARCHIVED' THEN COALESCE(archived_at, now()) ELSE archived_at END
         WHERE collection_entry_id = v_entry_id;
        SELECT api.collection_inventory_operation('get_inventory_item', jsonb_build_object('inventory_item_id',v_entry_id),'{}',NULL) INTO v_result;

    WHEN 'archive_inventory_item' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        SELECT owner_id, edit_revision INTO v_owner, v_revision FROM collection.entries WHERE collection_entry_id=v_entry_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE collection.entries SET status='ARCHIVED',archived_at=COALESCE(archived_at,now()),edit_revision=edit_revision+1,updated_at=now() WHERE collection_entry_id=v_entry_id;
        v_result := jsonb_build_object('archived',true,'inventory_item_id',v_entry_id);

    /* ---------------------------------------------------------------------
     * Physical instances
     * ------------------------------------------------------------------ */
    WHEN 'list_instances' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.entries WHERE collection_entry_id=v_entry_id;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'instance_id', ci.collection_instance_id,
            'inventory_item_id', ci.collection_entry_id,
            'inventory_version_id', ci.inventory_version_id,
            'item_condition', ci.item_condition::text,
            'package_condition', ci.package_condition::text,
            'assembly_state', ci.assembly_state::text,
            'completeness_state', ci.completeness_state::text,
            'notes', ci.notes,
            'revision', ci.edit_revision,
            'etag', api.etag_for_revision(ci.edit_revision),
            'created_at', ci.created_at,
            'updated_at', ci.updated_at,
            'archived_at', ci.archived_at
        )) ORDER BY ci.created_at,ci.collection_instance_id),'[]'::jsonb) INTO v_result
        FROM collection.instances ci WHERE ci.collection_entry_id=v_entry_id;

    WHEN 'create_instance' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.entries WHERE collection_entry_id=v_entry_id AND status='ACTIVE';
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Active inventory item not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        v_inventory_version_id := NULLIF(p_body->>'inventory_version_id','')::uuid;
        INSERT INTO collection.instances(
            collection_entry_id,inventory_version_id,item_condition,package_condition,assembly_state,completeness_state,notes
        ) VALUES (
            v_entry_id,v_inventory_version_id,
            COALESCE(upper(NULLIF(p_body->>'item_condition',''))::collection.item_condition,'UNKNOWN'),
            COALESCE(upper(NULLIF(p_body->>'package_condition',''))::collection.package_condition,'UNKNOWN'),
            COALESCE(upper(NULLIF(p_body->>'assembly_state',''))::collection.assembly_state,'NOT_APPLICABLE'),
            COALESCE(upper(NULLIF(p_body->>'completeness_state',''))::collection.completeness_state,'UNKNOWN'),
            p_body->>'notes'
        ) RETURNING collection_instance_id,edit_revision INTO v_instance_id,v_revision;
        v_result := jsonb_build_object('instance_id',v_instance_id,'inventory_item_id',v_entry_id,'revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'patch_instance' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        v_instance_id := (p_params->>'instance_id')::uuid;
        SELECT e.owner_id,ci.edit_revision INTO v_owner,v_revision
        FROM collection.instances ci JOIN collection.entries e USING(collection_entry_id)
        WHERE ci.collection_instance_id=v_instance_id AND ci.collection_entry_id=v_entry_id FOR UPDATE OF ci;
        IF NOT FOUND THEN RAISE EXCEPTION 'Physical instance not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE collection.instances SET
            inventory_version_id=CASE WHEN p_body ? 'inventory_version_id' THEN NULLIF(p_body->>'inventory_version_id','')::uuid ELSE inventory_version_id END,
            item_condition=CASE WHEN p_body ? 'item_condition' THEN upper(p_body->>'item_condition')::collection.item_condition ELSE item_condition END,
            package_condition=CASE WHEN p_body ? 'package_condition' THEN upper(p_body->>'package_condition')::collection.package_condition ELSE package_condition END,
            assembly_state=CASE WHEN p_body ? 'assembly_state' THEN upper(p_body->>'assembly_state')::collection.assembly_state ELSE assembly_state END,
            completeness_state=CASE WHEN p_body ? 'completeness_state' THEN upper(p_body->>'completeness_state')::collection.completeness_state ELSE completeness_state END,
            notes=CASE WHEN p_body ? 'notes' THEN p_body->>'notes' ELSE notes END,
            edit_revision=edit_revision+1,updated_at=now()
        WHERE collection_instance_id=v_instance_id;
        SELECT edit_revision INTO v_revision FROM collection.instances WHERE collection_instance_id=v_instance_id;
        v_result:=jsonb_build_object('instance_id',v_instance_id,'revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'archive_instance' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        v_instance_id := (p_params->>'instance_id')::uuid;
        SELECT e.owner_id,ci.edit_revision INTO v_owner,v_revision
        FROM collection.instances ci JOIN collection.entries e USING(collection_entry_id)
        WHERE ci.collection_instance_id=v_instance_id AND ci.collection_entry_id=v_entry_id FOR UPDATE OF ci;
        IF NOT FOUND THEN RAISE EXCEPTION 'Physical instance not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE collection.instances SET archived_at=COALESCE(archived_at,now()),edit_revision=edit_revision+1,updated_at=now() WHERE collection_instance_id=v_instance_id;
        v_result:=jsonb_build_object('archived',true,'instance_id',v_instance_id);

    WHEN 'get_missing_parts', 'get_completeness' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.entries WHERE collection_entry_id=v_entry_id;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        IF p_operation='get_missing_parts' THEN
            SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                'instance_id', ia.collection_instance_id,
                'requirement_group_id', ia.expected_requirement_group_id,
                'catalog_item_id', ia.catalog_item_id,
                'part_variant_id', ia.part_variant_id,
                'quantity', ia.quantity,
                'notes', ia.notes
            )) ORDER BY ia.collection_instance_id,ia.instance_adjustment_id),'[]'::jsonb)
            INTO v_result
            FROM collection.instance_adjustments ia
            JOIN collection.instances ci USING(collection_instance_id)
            WHERE ci.collection_entry_id=v_entry_id AND ia.adjustment_type='MISSING';
        ELSE
            SELECT COALESCE(sum(CASE WHEN ia.adjustment_type='MISSING' THEN ia.quantity ELSE 0 END),0)::integer
              INTO v_missing
              FROM collection.instances ci
              LEFT JOIN collection.instance_adjustments ia USING(collection_instance_id)
             WHERE ci.collection_entry_id=v_entry_id AND ci.archived_at IS NULL;
            v_result:=jsonb_build_object('inventory_item_id',v_entry_id,'missing_quantity',v_missing,'complete',v_missing=0);
        END IF;

    WHEN 'part_out' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        v_instance_id := NULLIF(p_body->>'instance_id','')::uuid;
        IF v_instance_id IS NULL THEN
            SELECT collection_instance_id INTO v_instance_id FROM collection.instances WHERE collection_entry_id=v_entry_id AND archived_at IS NULL ORDER BY created_at LIMIT 1;
        END IF;
        SELECT e.owner_id,ci.inventory_version_id,ci.edit_revision INTO v_owner,v_inventory_version_id,v_revision
        FROM collection.instances ci JOIN collection.entries e USING(collection_entry_id)
        WHERE ci.collection_instance_id=v_instance_id AND ci.collection_entry_id=v_entry_id FOR UPDATE OF ci;
        IF NOT FOUND THEN RAISE EXCEPTION 'Physical instance not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        IF v_inventory_version_id IS NULL THEN RAISE EXCEPTION 'Instance must pin an inventory version before part-out' USING ERRCODE='P0409'; END IF;
        FOR rec IN
            SELECT o.part_variant_id, sum(g.required_quantity * o.option_quantity)::integer AS qty
            FROM definition.requirement_groups g
            JOIN definition.requirement_options o USING(requirement_group_id)
            WHERE g.inventory_version_id=v_inventory_version_id
              AND o.part_variant_id IS NOT NULL
              AND (o.is_primary OR NOT EXISTS(SELECT 1 FROM definition.requirement_options ox WHERE ox.requirement_group_id=g.requirement_group_id AND ox.is_primary))
            GROUP BY o.part_variant_id
        LOOP
            INSERT INTO collection.entries(owner_id,part_variant_id,quantity) VALUES(v_owner,rec.part_variant_id,rec.qty);
        END LOOP;
        UPDATE collection.instances SET assembly_state='PARTED_OUT',completeness_state='UNKNOWN',edit_revision=edit_revision+1,updated_at=now() WHERE collection_instance_id=v_instance_id;
        v_result:=jsonb_build_object('inventory_item_id',v_entry_id,'instance_id',v_instance_id,'parted_out',true);

    WHEN 'assemble' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        SELECT e.owner_id,ci.collection_instance_id,ci.inventory_version_id,ci.edit_revision
          INTO v_owner,v_instance_id,v_inventory_version_id,v_revision
          FROM collection.entries e
          JOIN LATERAL (SELECT * FROM collection.instances x WHERE x.collection_entry_id=e.collection_entry_id AND x.archived_at IS NULL ORDER BY x.created_at LIMIT 1) ci ON true
         WHERE e.collection_entry_id=v_entry_id FOR UPDATE OF ci;
        IF NOT FOUND THEN RAISE EXCEPTION 'Owned physical instance not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        IF v_inventory_version_id IS NULL THEN RAISE EXCEPTION 'Instance must pin an inventory version before assembly' USING ERRCODE='P0409'; END IF;
        FOR rec IN
            SELECT o.part_variant_id, sum(g.required_quantity * o.option_quantity)::integer AS qty
            FROM definition.requirement_groups g
            JOIN definition.requirement_options o USING(requirement_group_id)
            WHERE g.inventory_version_id=v_inventory_version_id
              AND o.part_variant_id IS NOT NULL AND o.is_primary
            GROUP BY o.part_variant_id
        LOOP
            SELECT collection_entry_id INTO v_entry_id
              FROM collection.entries
             WHERE owner_id=v_owner AND part_variant_id=rec.part_variant_id AND status='ACTIVE' AND quantity>=rec.qty
             ORDER BY quantity DESC LIMIT 1 FOR UPDATE;
            IF v_entry_id IS NULL THEN
                RAISE EXCEPTION 'Insufficient loose inventory for required part variant %',rec.part_variant_id USING ERRCODE='P0409';
            END IF;
            UPDATE collection.entries
               SET quantity=quantity-rec.qty,edit_revision=edit_revision+1,updated_at=now(),
                   status=CASE WHEN quantity-rec.qty=0 THEN 'ARCHIVED'::collection.entry_status ELSE status END,
                   archived_at=CASE WHEN quantity-rec.qty=0 THEN now() ELSE archived_at END
             WHERE collection_entry_id=v_entry_id;
            v_entry_id := (p_params->>'inventory_item_id')::uuid;
        END LOOP;
        UPDATE collection.instances SET assembly_state='BUILT',completeness_state='COMPLETE',edit_revision=edit_revision+1,updated_at=now() WHERE collection_instance_id=v_instance_id;
        v_result:=jsonb_build_object('inventory_item_id',v_entry_id,'instance_id',v_instance_id,'assembled',true);

    WHEN 'transfer_inventory' THEN
        v_entry_id := (p_params->>'inventory_item_id')::uuid;
        CALL api.transfer_collection_quantity(v_entry_id,(p_body->>'to_owner_id')::uuid,(p_body->>'quantity')::integer,p_body->>'reason');
        v_result:=jsonb_build_object('inventory_item_id',v_entry_id,'transferred',true);

    WHEN 'import_inventory' THEN
        IF jsonb_typeof(p_body->'items') <> 'array' THEN RAISE EXCEPTION 'Normalized import items array is required' USING ERRCODE='22023'; END IF;
        v_quantity:=0;
        FOR rec IN SELECT value FROM jsonb_array_elements(p_body->'items')
        LOOP
            PERFORM api.collection_inventory_operation('create_inventory_item','{}',rec.value,NULL);
            v_quantity:=v_quantity+1;
        END LOOP;
        v_result:=jsonb_build_object('accepted',v_quantity,'created',v_quantity,'updated',0,'rejected',0);

    /* ---------------------------------------------------------------------
     * Storage
     * ------------------------------------------------------------------ */
    WHEN 'list_storage_locations' THEN
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'storage_location_id',s.storage_location_id,'owner_id',s.owner_id,'parent_storage_location_id',s.parent_storage_location_id,
            'name',s.location_name,'description',s.description,'revision',s.edit_revision,'etag',api.etag_for_revision(s.edit_revision),
            'created_at',s.created_at,'updated_at',s.updated_at,'archived_at',s.archived_at
        )) ORDER BY s.location_name),'[]'::jsonb) INTO v_result
        FROM collection.storage_locations s WHERE s.archived_at IS NULL AND identity.can_view_owner(v_user,s.owner_id,'STORAGE');

    WHEN 'create_storage_location' THEN
        v_owner:=COALESCE(NULLIF(p_body->>'owner_id','')::uuid,v_personal_owner);
        IF NOT identity.can_manage_owner(v_user,v_owner,'STORAGE') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        INSERT INTO collection.storage_locations(owner_id,parent_storage_location_id,location_name,description)
        VALUES(v_owner,NULLIF(p_body->>'parent_storage_location_id','')::uuid,p_body->>'name',p_body->>'description')
        RETURNING storage_location_id,edit_revision INTO v_storage_id,v_revision;
        v_result:=jsonb_build_object('storage_location_id',v_storage_id,'name',p_body->>'name','revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'get_storage_location' THEN
        v_storage_id:=(p_params->>'storage_location_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.storage_locations WHERE storage_location_id=v_storage_id;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Storage location not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_view_owner(v_user,v_owner,'STORAGE') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT jsonb_strip_nulls(jsonb_build_object('storage_location_id',s.storage_location_id,'owner_id',s.owner_id,'parent_storage_location_id',s.parent_storage_location_id,
            'name',s.location_name,'description',s.description,'revision',s.edit_revision,'_etag',api.etag_for_revision(s.edit_revision),'created_at',s.created_at,'updated_at',s.updated_at,'archived_at',s.archived_at))
        INTO v_result FROM collection.storage_locations s WHERE s.storage_location_id=v_storage_id;

    WHEN 'patch_storage_location' THEN
        v_storage_id:=(p_params->>'storage_location_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM collection.storage_locations WHERE storage_location_id=v_storage_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Storage location not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'STORAGE') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE collection.storage_locations SET
            parent_storage_location_id=CASE WHEN p_body ? 'parent_storage_location_id' THEN NULLIF(p_body->>'parent_storage_location_id','')::uuid ELSE parent_storage_location_id END,
            location_name=CASE WHEN p_body ? 'name' THEN p_body->>'name' ELSE location_name END,
            description=CASE WHEN p_body ? 'description' THEN p_body->>'description' ELSE description END,
            edit_revision=edit_revision+1,updated_at=now()
        WHERE storage_location_id=v_storage_id;
        SELECT api.collection_inventory_operation('get_storage_location',jsonb_build_object('storage_location_id',v_storage_id),'{}',NULL) INTO v_result;

    WHEN 'archive_storage_location' THEN
        v_storage_id:=(p_params->>'storage_location_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM collection.storage_locations WHERE storage_location_id=v_storage_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Storage location not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'STORAGE') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        IF EXISTS(SELECT 1 FROM collection.storage_allocations WHERE storage_location_id=v_storage_id) THEN RAISE EXCEPTION 'Storage location has active allocations' USING ERRCODE='P0409'; END IF;
        UPDATE collection.storage_locations SET archived_at=COALESCE(archived_at,now()),edit_revision=edit_revision+1,updated_at=now() WHERE storage_location_id=v_storage_id;
        v_result:=jsonb_build_object('archived',true,'storage_location_id',v_storage_id);

    WHEN 'list_storage_allocations' THEN
        v_entry_id:=(p_params->>'inventory_item_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.entries WHERE collection_entry_id=v_entry_id;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Inventory item not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT COALESCE(jsonb_agg(to_jsonb(sa) ORDER BY sa.storage_allocation_id),'[]'::jsonb) INTO v_result FROM collection.storage_allocations sa WHERE sa.collection_entry_id=v_entry_id;

    WHEN 'allocate_storage' THEN
        v_entry_id:=(p_params->>'inventory_item_id')::uuid;
        v_storage_id:=(p_body->>'storage_location_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.entries WHERE collection_entry_id=v_entry_id AND status='ACTIVE';
        IF v_owner IS NULL OR NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') OR NOT identity.can_manage_owner(v_user,v_owner,'STORAGE') THEN RAISE EXCEPTION 'Forbidden or inventory item not found' USING ERRCODE='P0403'; END IF;
        IF NOT EXISTS(SELECT 1 FROM collection.storage_locations s WHERE s.storage_location_id=v_storage_id AND s.owner_id=v_owner AND s.archived_at IS NULL) THEN RAISE EXCEPTION 'Storage location not found for owner' USING ERRCODE='P0404'; END IF;
        INSERT INTO collection.storage_allocations(collection_entry_id,collection_instance_id,storage_location_id,quantity)
        VALUES(v_entry_id,NULLIF(p_body->>'instance_id','')::uuid,v_storage_id,(p_body->>'quantity')::integer)
        RETURNING jsonb_build_object('storage_allocation_id',storage_allocation_id,'inventory_item_id',collection_entry_id,'storage_location_id',storage_location_id,'quantity',quantity) INTO v_result;

    /* ---------------------------------------------------------------------
     * Named collections
     * ------------------------------------------------------------------ */
    WHEN 'list_collections' THEN
        SELECT jsonb_build_object('items',COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'collection_id',c.collection_id,'owner_id',c.owner_id,'name',c.collection_name,'description',c.description,
            'visibility',c.visibility::text,'revision',c.edit_revision,'etag',api.etag_for_revision(c.edit_revision),'created_at',c.created_at,'updated_at',c.updated_at
        )) ORDER BY c.collection_id),'[]'::jsonb),'next_cursor',max(c.collection_id)::text) INTO v_result
        FROM (SELECT * FROM collection.collections c WHERE c.archived_at IS NULL AND identity.can_view_owner(v_user,c.owner_id,'COLLECTION') AND (v_cursor IS NULL OR c.collection_id>v_cursor) ORDER BY c.collection_id LIMIT v_limit) c;

    WHEN 'create_collection' THEN
        v_owner:=COALESCE(NULLIF(p_body->>'owner_id','')::uuid,v_personal_owner);
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        INSERT INTO collection.collections(owner_id,collection_name,description,visibility)
        VALUES(v_owner,p_body->>'name',p_body->>'description',COALESCE(upper(NULLIF(p_body->>'visibility',''))::collection.collection_visibility,'PRIVATE'))
        RETURNING collection_id,edit_revision INTO v_collection_id,v_revision;
        v_result:=jsonb_build_object('collection_id',v_collection_id,'name',p_body->>'name','revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'get_collection' THEN
        v_collection_id:=(p_params->>'collection_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.collections WHERE collection_id=v_collection_id AND archived_at IS NULL;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Collection not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT jsonb_strip_nulls(jsonb_build_object('collection_id',c.collection_id,'owner_id',c.owner_id,'name',c.collection_name,'description',c.description,'visibility',c.visibility::text,
            'revision',c.edit_revision,'_etag',api.etag_for_revision(c.edit_revision),'created_at',c.created_at,'updated_at',c.updated_at)) INTO v_result FROM collection.collections c WHERE c.collection_id=v_collection_id;

    WHEN 'patch_collection' THEN
        v_collection_id:=(p_params->>'collection_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM collection.collections WHERE collection_id=v_collection_id AND archived_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE collection.collections SET collection_name=CASE WHEN p_body?'name' THEN p_body->>'name' ELSE collection_name END,
            description=CASE WHEN p_body?'description' THEN p_body->>'description' ELSE description END,
            visibility=CASE WHEN p_body?'visibility' THEN upper(p_body->>'visibility')::collection.collection_visibility ELSE visibility END,
            edit_revision=edit_revision+1,updated_at=now() WHERE collection_id=v_collection_id;
        SELECT api.collection_inventory_operation('get_collection',jsonb_build_object('collection_id',v_collection_id),'{}',NULL) INTO v_result;

    WHEN 'archive_collection' THEN
        v_collection_id:=(p_params->>'collection_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM collection.collections WHERE collection_id=v_collection_id AND archived_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE collection.collections SET archived_at=now(),edit_revision=edit_revision+1,updated_at=now() WHERE collection_id=v_collection_id;
        v_result:=jsonb_build_object('archived',true,'collection_id',v_collection_id);

    WHEN 'list_collection_items' THEN
        v_collection_id:=(p_params->>'collection_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.collections WHERE collection_id=v_collection_id AND archived_at IS NULL;
        IF v_owner IS NULL THEN RAISE EXCEPTION 'Collection not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        SELECT jsonb_build_object('items',COALESCE(jsonb_agg(jsonb_build_object('inventory_item_id',m.collection_entry_id,'sort_order',m.sort_order,'notes',m.notes) ORDER BY m.sort_order NULLS LAST,m.collection_entry_id),'[]'::jsonb),'next_cursor',NULL) INTO v_result
        FROM collection.collection_memberships m JOIN collection.entries e USING(collection_entry_id) WHERE m.collection_id=v_collection_id AND e.status='ACTIVE';

    WHEN 'add_collection_item' THEN
        v_collection_id:=(p_params->>'collection_id')::uuid;
        v_entry_id:=(p_body->>'inventory_item_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM collection.collections WHERE collection_id=v_collection_id AND archived_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        IF NOT EXISTS(SELECT 1 FROM collection.entries e WHERE e.collection_entry_id=v_entry_id AND e.owner_id=v_owner AND e.status='ACTIVE') THEN RAISE EXCEPTION 'Inventory item does not belong to collection owner' USING ERRCODE='P0409'; END IF;
        INSERT INTO collection.collection_memberships(collection_id,collection_entry_id,sort_order,notes)
        VALUES(v_collection_id,v_entry_id,NULLIF(p_body->>'sort_order','')::integer,p_body->>'notes') ON CONFLICT DO NOTHING;
        UPDATE collection.collections SET edit_revision=edit_revision+1,updated_at=now() WHERE collection_id=v_collection_id;
        v_result:=jsonb_build_object('collection_id',v_collection_id,'inventory_item_id',v_entry_id,'added',true);

    WHEN 'remove_collection_item' THEN
        v_collection_id:=(p_params->>'collection_id')::uuid;
        v_entry_id:=(p_params->>'inventory_item_id')::uuid;
        SELECT owner_id,edit_revision INTO v_owner,v_revision FROM collection.collections WHERE collection_id=v_collection_id AND archived_at IS NULL FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found' USING ERRCODE='P0404'; END IF;
        IF NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        DELETE FROM collection.collection_memberships WHERE collection_id=v_collection_id AND collection_entry_id=v_entry_id;
        IF NOT FOUND THEN RAISE EXCEPTION 'Collection membership not found' USING ERRCODE='P0404'; END IF;
        UPDATE collection.collections SET edit_revision=edit_revision+1,updated_at=now() WHERE collection_id=v_collection_id;
        v_result:=jsonb_build_object('removed',true,'collection_id',v_collection_id,'inventory_item_id',v_entry_id);

    /* ---------------------------------------------------------------------
     * Acquisition provenance
     * ------------------------------------------------------------------ */
    WHEN 'list_acquisitions' THEN
        v_entry_id:=(p_params->>'inventory_item_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.entries WHERE collection_entry_id=v_entry_id;
        IF v_owner IS NULL OR NOT identity.can_view_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Inventory item not found or forbidden' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(jsonb_build_object('acquisition',to_jsonb(a),'item',to_jsonb(ai)) ORDER BY a.created_at DESC),'[]'::jsonb) INTO v_result
        FROM collection.acquisition_items ai JOIN collection.acquisitions a USING(acquisition_id) WHERE ai.collection_entry_id=v_entry_id;

    WHEN 'create_acquisition' THEN
        v_entry_id:=(p_params->>'inventory_item_id')::uuid;
        SELECT owner_id INTO v_owner FROM collection.entries WHERE collection_entry_id=v_entry_id AND status='ACTIVE';
        IF v_owner IS NULL OR NOT identity.can_manage_owner(v_user,v_owner,'COLLECTION') THEN RAISE EXCEPTION 'Inventory item not found or forbidden' USING ERRCODE='P0404'; END IF;
        INSERT INTO collection.acquisitions(owner_id,seller_name,source_description,acquired_on,currency,item_amount,shipping_amount,tax_amount,fee_amount,notes)
        VALUES(v_owner,p_body->>'seller_name',p_body->>'source_description',NULLIF(p_body->>'acquired_on','')::date,NULLIF(p_body->>'currency','')::app.currency_code,
            NULLIF(p_body->>'item_amount','')::app.money_amount,NULLIF(p_body->>'shipping_amount','')::app.money_amount,NULLIF(p_body->>'tax_amount','')::app.money_amount,NULLIF(p_body->>'fee_amount','')::app.money_amount,p_body->>'notes')
        RETURNING acquisition_id INTO v_catalog_item_id;
        INSERT INTO collection.acquisition_items(acquisition_id,collection_entry_id,collection_instance_id,quantity,allocated_item_amount)
        VALUES(v_catalog_item_id,v_entry_id,NULLIF(p_body->>'instance_id','')::uuid,COALESCE((p_body->>'quantity')::integer,1),NULLIF(p_body->>'allocated_item_amount','')::app.money_amount);
        SELECT jsonb_build_object('acquisition_id',a.acquisition_id,'owner_id',a.owner_id,'acquired_on',a.acquired_on,'currency',a.currency,'item_amount',a.item_amount,'created_at',a.created_at)
        INTO v_result FROM collection.acquisitions a WHERE a.acquisition_id=v_catalog_item_id;

    ELSE
        RAISE EXCEPTION 'Unknown collection/inventory API operation: %',p_operation USING ERRCODE='22023';
    END CASE;

    RETURN COALESCE(v_result,'null'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.collection_inventory_operation(text,jsonb,jsonb,text) FROM PUBLIC;

\echo '[PASS] 5230_api_collection_inventory.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5230_api_collection_inventory.sql');
