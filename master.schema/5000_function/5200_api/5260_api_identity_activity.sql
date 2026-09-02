/*
===============================================================================
 File:           5000_function/5200_api/5260_api_identity_activity.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Implement profile, family, notification, activity and dashboard
                 operations required by the v3 client contract.
 Depends On:     api.assert_if_match()
                 identity.current_user_id()
                 identity.users
                 identity.families
                 identity.family_memberships
                 identity.family_member_permissions
                 identity.owners
                 operations.notifications
                 audit.events
                 collection.entries
                 marketplace.market_price_observations
 Creates:        api.identity_activity_operation()
 Key Rules:      Users may update only their own profile through this surface.
                 Family administration requires active membership and explicit
                 management capabilities. Notification surprise/privacy rules
                 are unchanged. Dashboard data is derived from authorized owned
                 state and never mutates canonical catalog data.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5260_api_identity_activity.sql',
    ARRAY[
        'api.assert_if_match()',
        'identity.current_user_id()',
        'identity.users',
        'identity.families',
        'identity.family_memberships',
        'identity.family_member_permissions',
        'identity.owners',
        'operations.notifications',
        'audit.events',
        'collection.entries',
        'marketplace.market_price_observations'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.identity_activity_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb,
    p_body jsonb DEFAULT '{}'::jsonb,
    p_if_match text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, identity, operations, audit, collection, catalog, marketplace
AS $$
DECLARE
    v_user uuid := identity.current_user_id();
    v_family uuid;
    v_member uuid;
    v_target_user uuid;
    v_revision bigint;
    v_can_manage boolean;
    v_result jsonb;
    v_limit integer := LEAST(GREATEST(COALESCE((p_params->>'limit')::integer,50),1),200);
    v_cursor uuid := NULLIF(p_params->>'cursor','')::uuid;
BEGIN
    CASE p_operation
    WHEN 'get_profile' THEN
        SELECT jsonb_strip_nulls(jsonb_build_object(
            'user_id',u.user_id,'username',u.username::text,'display_name',u.display_name,'email',u.email::text,
            'bio',u.bio,'avatar_url',u.avatar_url,'locale',u.locale,'timezone_name',u.timezone_name,
            'preferences',u.preferences,'joined_at',u.created_at,'revision',u.edit_revision,'_etag',api.etag_for_revision(u.edit_revision)
        )) INTO v_result FROM identity.users u WHERE u.user_id=v_user AND u.account_status<>'ARCHIVED';
        IF v_result IS NULL THEN RAISE EXCEPTION 'Profile not found' USING ERRCODE='P0404'; END IF;

    WHEN 'patch_profile' THEN
        SELECT edit_revision INTO v_revision FROM identity.users WHERE user_id=v_user FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Profile not found' USING ERRCODE='P0404'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE identity.users SET
            display_name=CASE WHEN p_body?'display_name' THEN p_body->>'display_name' ELSE display_name END,
            bio=CASE WHEN p_body?'bio' THEN p_body->>'bio' ELSE bio END,
            avatar_url=CASE WHEN p_body?'avatar_url' THEN p_body->>'avatar_url' ELSE avatar_url END,
            locale=CASE WHEN p_body?'locale' THEN p_body->>'locale' ELSE locale END,
            timezone_name=CASE WHEN p_body?'timezone_name' THEN p_body->>'timezone_name' ELSE timezone_name END,
            preferences=CASE WHEN p_body?'preferences' THEN p_body->'preferences' ELSE preferences END,
            edit_revision=edit_revision+1,updated_at=now()
        WHERE user_id=v_user;
        SELECT api.identity_activity_operation('get_profile','{}','{}',NULL) INTO v_result;

    WHEN 'list_families' THEN
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'family_id',f.family_id,'name',f.family_name,'description',f.description,'status',f.status::text,
            'member_role',m.member_role::text,'revision',f.edit_revision,'etag',api.etag_for_revision(f.edit_revision),
            'created_at',f.created_at,'updated_at',f.updated_at
        )) ORDER BY f.family_name),'[]'::jsonb) INTO v_result
        FROM identity.family_memberships m JOIN identity.families f USING(family_id)
        WHERE m.user_id=v_user AND m.membership_status='ACTIVE' AND f.status='ACTIVE';

    WHEN 'create_family' THEN
        INSERT INTO identity.families(family_name,description,status,created_by_user_id)
        VALUES(p_body->>'name',p_body->>'description','ACTIVE',v_user)
        RETURNING family_id,edit_revision INTO v_family,v_revision;
        INSERT INTO identity.owners(owner_type,family_id) VALUES('FAMILY',v_family);
        INSERT INTO identity.family_memberships(family_id,user_id,member_role,membership_status,added_by_user_id)
        VALUES(v_family,v_user,'PARENT','ACTIVE',v_user) RETURNING family_membership_id INTO v_member;
        INSERT INTO identity.family_member_permissions(
            family_membership_id,can_manage_family,can_manage_members,can_manage_permissions,
            can_view_family_collection,can_manage_family_collection,can_view_family_wanted,can_manage_family_wanted,
            can_view_family_mocs,can_manage_family_mocs,can_view_family_storage,can_manage_family_storage,
            can_view_family_purchases,can_manage_family_purchases,can_transfer_to_family,can_transfer_from_family,can_view_family_audit,updated_by_user_id
        ) VALUES(v_member,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,true,v_user);
        v_result:=jsonb_build_object('family_id',v_family,'name',p_body->>'name','revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'get_family' THEN
        v_family:=(p_params->>'family_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM identity.family_memberships WHERE family_id=v_family AND user_id=v_user AND membership_status='ACTIVE') THEN RAISE EXCEPTION 'Family not found' USING ERRCODE='P0404'; END IF;
        SELECT jsonb_strip_nulls(jsonb_build_object('family_id',f.family_id,'name',f.family_name,'description',f.description,'status',f.status::text,
            'revision',f.edit_revision,'_etag',api.etag_for_revision(f.edit_revision),'created_at',f.created_at,'updated_at',f.updated_at,
            'members',COALESCE((SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('family_membership_id',m.family_membership_id,'user_id',m.user_id,'display_name',u.display_name,'role',m.member_role::text,
                'status',m.membership_status::text,'joined_at',m.joined_at,'ended_at',m.ended_at,'permissions',to_jsonb(p)-ARRAY['family_membership_id','created_at','updated_at','updated_by_user_id'])) ORDER BY u.display_name)
                FROM identity.family_memberships m JOIN identity.users u USING(user_id) LEFT JOIN identity.family_member_permissions p USING(family_membership_id) WHERE m.family_id=f.family_id),'[]'::jsonb)))
        INTO v_result FROM identity.families f WHERE f.family_id=v_family;

    WHEN 'patch_family' THEN
        v_family:=(p_params->>'family_id')::uuid;
        SELECT f.edit_revision,COALESCE(p.can_manage_family,false) INTO v_revision,v_can_manage
        FROM identity.families f JOIN identity.family_memberships m USING(family_id) LEFT JOIN identity.family_member_permissions p USING(family_membership_id)
        WHERE f.family_id=v_family AND m.user_id=v_user AND m.membership_status='ACTIVE' FOR UPDATE OF f;
        IF NOT FOUND THEN RAISE EXCEPTION 'Family not found' USING ERRCODE='P0404'; END IF;
        IF NOT v_can_manage THEN RAISE EXCEPTION 'Family management permission required' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE identity.families SET family_name=CASE WHEN p_body?'name' THEN p_body->>'name' ELSE family_name END,
            description=CASE WHEN p_body?'description' THEN p_body->>'description' ELSE description END,
            edit_revision=edit_revision+1,updated_at=now() WHERE family_id=v_family;
        SELECT api.identity_activity_operation('get_family',jsonb_build_object('family_id',v_family),'{}',NULL) INTO v_result;

    WHEN 'list_family_members' THEN
        v_family:=(p_params->>'family_id')::uuid;
        IF NOT EXISTS(SELECT 1 FROM identity.family_memberships WHERE family_id=v_family AND user_id=v_user AND membership_status='ACTIVE') THEN RAISE EXCEPTION 'Family not found' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('family_membership_id',m.family_membership_id,'user_id',m.user_id,'display_name',u.display_name,'role',m.member_role::text,
            'status',m.membership_status::text,'joined_at',m.joined_at,'ended_at',m.ended_at,'permissions',to_jsonb(p)-ARRAY['family_membership_id','created_at','updated_at','updated_by_user_id'])) ORDER BY u.display_name),'[]'::jsonb)
        INTO v_result FROM identity.family_memberships m JOIN identity.users u USING(user_id) LEFT JOIN identity.family_member_permissions p USING(family_membership_id) WHERE m.family_id=v_family;

    WHEN 'add_family_member' THEN
        v_family:=(p_params->>'family_id')::uuid;
        v_target_user:=(p_body->>'user_id')::uuid;
        SELECT COALESCE(p.can_manage_members,false) INTO v_can_manage FROM identity.family_memberships m LEFT JOIN identity.family_member_permissions p USING(family_membership_id)
        WHERE m.family_id=v_family AND m.user_id=v_user AND m.membership_status='ACTIVE';
        IF NOT COALESCE(v_can_manage,false) THEN RAISE EXCEPTION 'Family member management permission required' USING ERRCODE='P0403'; END IF;
        INSERT INTO identity.family_memberships(family_id,user_id,member_role,membership_status,added_by_user_id)
        VALUES(v_family,v_target_user,upper(COALESCE(p_body->>'role','ADULT'))::identity.family_member_role,'ACTIVE',v_user)
        RETURNING family_membership_id INTO v_member;
        INSERT INTO identity.family_member_permissions(family_membership_id,updated_by_user_id) VALUES(v_member,v_user);
        UPDATE identity.families SET edit_revision=edit_revision+1,updated_at=now() WHERE family_id=v_family;
        v_result:=jsonb_build_object('family_membership_id',v_member,'family_id',v_family,'user_id',v_target_user,'role',upper(COALESCE(p_body->>'role','ADULT')));

    WHEN 'patch_family_member' THEN
        v_family:=(p_params->>'family_id')::uuid;
        v_target_user:=(p_params->>'user_id')::uuid;
        SELECT f.edit_revision,COALESCE(p.can_manage_permissions,false) INTO v_revision,v_can_manage
        FROM identity.families f JOIN identity.family_memberships m USING(family_id) LEFT JOIN identity.family_member_permissions p USING(family_membership_id)
        WHERE f.family_id=v_family AND m.user_id=v_user AND m.membership_status='ACTIVE' FOR UPDATE OF f;
        IF NOT FOUND THEN RAISE EXCEPTION 'Family not found' USING ERRCODE='P0404'; END IF;
        IF NOT v_can_manage THEN RAISE EXCEPTION 'Family permission-management capability required' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        SELECT family_membership_id INTO v_member FROM identity.family_memberships WHERE family_id=v_family AND user_id=v_target_user AND membership_status='ACTIVE';
        IF v_member IS NULL THEN RAISE EXCEPTION 'Active family member not found' USING ERRCODE='P0404'; END IF;
        UPDATE identity.family_memberships SET member_role=CASE WHEN p_body?'role' THEN upper(p_body->>'role')::identity.family_member_role ELSE member_role END WHERE family_membership_id=v_member;
        UPDATE identity.family_member_permissions SET
            can_manage_family=COALESCE((p_body->>'can_manage_family')::boolean,can_manage_family),
            can_manage_members=COALESCE((p_body->>'can_manage_members')::boolean,can_manage_members),
            can_manage_permissions=COALESCE((p_body->>'can_manage_permissions')::boolean,can_manage_permissions),
            can_view_family_collection=COALESCE((p_body->>'can_view_family_collection')::boolean,can_view_family_collection),
            can_manage_family_collection=COALESCE((p_body->>'can_manage_family_collection')::boolean,can_manage_family_collection),
            can_view_family_wanted=COALESCE((p_body->>'can_view_family_wanted')::boolean,can_view_family_wanted),
            can_manage_family_wanted=COALESCE((p_body->>'can_manage_family_wanted')::boolean,can_manage_family_wanted),
            can_view_family_mocs=COALESCE((p_body->>'can_view_family_mocs')::boolean,can_view_family_mocs),
            can_manage_family_mocs=COALESCE((p_body->>'can_manage_family_mocs')::boolean,can_manage_family_mocs),
            can_view_family_storage=COALESCE((p_body->>'can_view_family_storage')::boolean,can_view_family_storage),
            can_manage_family_storage=COALESCE((p_body->>'can_manage_family_storage')::boolean,can_manage_family_storage),
            updated_at=now(),updated_by_user_id=v_user
        WHERE family_membership_id=v_member;
        UPDATE identity.families SET edit_revision=edit_revision+1,updated_at=now() WHERE family_id=v_family RETURNING edit_revision INTO v_revision;
        v_result:=jsonb_build_object('family_id',v_family,'user_id',v_target_user,'revision',v_revision,'_etag',api.etag_for_revision(v_revision));

    WHEN 'remove_family_member' THEN
        v_family:=(p_params->>'family_id')::uuid;
        v_target_user:=(p_params->>'user_id')::uuid;
        SELECT f.edit_revision,COALESCE(p.can_manage_members,false) INTO v_revision,v_can_manage
        FROM identity.families f JOIN identity.family_memberships m USING(family_id) LEFT JOIN identity.family_member_permissions p USING(family_membership_id)
        WHERE f.family_id=v_family AND m.user_id=v_user AND m.membership_status='ACTIVE' FOR UPDATE OF f;
        IF NOT FOUND OR NOT COALESCE(v_can_manage,false) THEN RAISE EXCEPTION 'Family member management permission required' USING ERRCODE='P0403'; END IF;
        PERFORM api.assert_if_match(p_if_match,v_revision);
        UPDATE identity.family_memberships SET membership_status='REMOVED',ended_at=now() WHERE family_id=v_family AND user_id=v_target_user AND membership_status='ACTIVE';
        IF NOT FOUND THEN RAISE EXCEPTION 'Active family member not found' USING ERRCODE='P0404'; END IF;
        UPDATE identity.families SET edit_revision=edit_revision+1,updated_at=now() WHERE family_id=v_family;
        v_result:=jsonb_build_object('removed',true,'family_id',v_family,'user_id',v_target_user);

    WHEN 'list_notifications' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('notification_id',n.notification_id,'type',n.notification_type,'priority',n.priority::text,'title',n.title,'message',n.body,'data',n.data,
            'is_read',n.is_read,'read_at',n.read_at,'created_at',n.created_at) ORDER BY n.created_at DESC),'[]'::jsonb) INTO v_result
        FROM (SELECT * FROM operations.notifications n WHERE n.user_id=v_user AND (NOT COALESCE((p_params->>'unread_only')::boolean,false) OR NOT n.is_read) AND (v_cursor IS NULL OR n.notification_id>v_cursor) ORDER BY n.created_at DESC LIMIT v_limit) n;

    WHEN 'mark_notification_read' THEN
        IF NOT api.mark_notification_read((p_params->>'notification_id')::uuid) THEN RAISE EXCEPTION 'Notification not found' USING ERRCODE='P0404'; END IF;
        v_result:=jsonb_build_object('notification_id',p_params->>'notification_id','is_read',true);

    WHEN 'list_activity' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object('event_id',e.audit_event_id,'type',e.event_type,'occurred_at',e.occurred_at,'actor_user_id',e.actor_user_id,'subject_user_id',e.subject_user_id,
            'entity_schema',e.entity_schema,'entity_table',e.entity_table,'entity_id',e.entity_id,'data',e.metadata) ORDER BY e.occurred_at DESC),'[]'::jsonb) INTO v_result
        FROM (SELECT * FROM audit.events e WHERE (e.actor_user_id=v_user OR e.subject_user_id=v_user OR (e.owner_id IS NOT NULL AND identity.can_view_owner(v_user,e.owner_id,'AUDIT'))) AND (v_cursor IS NULL OR e.audit_event_id>v_cursor) ORDER BY e.occurred_at DESC LIMIT v_limit) e;

    WHEN 'get_dashboard' THEN
        SELECT jsonb_build_object(
            'counts',jsonb_build_object(
                'sets',count(*) FILTER(WHERE i.item_kind='SET'),
                'minifigs',count(*) FILTER(WHERE i.item_kind='MINIFIGURE'),
                'mocs',count(*) FILTER(WHERE i.item_kind='MOC'),
                'parts',count(*) FILTER(WHERE i.item_kind='PART' OR ce.part_variant_id IS NOT NULL)
            ),
            'total_quantity',COALESCE(sum(ce.quantity),0),
            'unread_notifications',(SELECT count(*) FROM operations.notifications n WHERE n.user_id=v_user AND NOT n.is_read),
            'recent_activity',COALESCE((SELECT jsonb_agg(jsonb_build_object('event_id',x.audit_event_id,'type',x.event_type,'occurred_at',x.occurred_at,'data',x.metadata) ORDER BY x.occurred_at DESC)
                FROM (SELECT * FROM audit.events a WHERE a.actor_user_id=v_user OR a.subject_user_id=v_user ORDER BY a.occurred_at DESC LIMIT 10) x),'[]'::jsonb)
        ) INTO v_result
        FROM collection.entries ce LEFT JOIN catalog.items i ON i.catalog_item_id=ce.catalog_item_id
        WHERE ce.status='ACTIVE' AND identity.can_view_owner(v_user,ce.owner_id,'COLLECTION');

    ELSE
        RAISE EXCEPTION 'Unknown identity/activity API operation: %',p_operation USING ERRCODE='22023';
    END CASE;

    RETURN COALESCE(v_result,'null'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.identity_activity_operation(text,jsonb,jsonb,text) FROM PUBLIC;

\echo '[PASS] 5260_api_identity_activity.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5260_api_identity_activity.sql');
