/*
===============================================================================
 File:           1100_security/1113_api_v3_rls.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Extend defense-in-depth row security to v3 named collections
                 and owner-authored custom minifigure lifecycle state.
 Depends On:     collection.collections
                 collection.collection_memberships
                 definition.custom_minifigs
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
                 identity.can_view_family_shared_owner()
 Key Rules:      Named collection containers inherit owner COLLECTION authority.
                 Membership rows inherit their container authority. Custom
                 minifigs use owner COLLECTION authority plus public/unlisted/
                 family visibility semantics.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '1100_security/1113_api_v3_rls.sql',
    ARRAY[
        'collection.collections',
        'collection.collection_memberships',
        'definition.custom_minifigs',
        'identity.current_user_id()',
        'identity.can_view_owner()',
        'identity.can_manage_owner()',
        'identity.can_view_family_shared_owner()'
    ]::text[]
);

ALTER TABLE collection.collections ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.collection_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE definition.custom_minifigs ENABLE ROW LEVEL SECURITY;

CREATE POLICY pol_named_collections_select
ON collection.collections
FOR SELECT
USING (
    visibility = 'PUBLIC'
    OR identity.can_view_owner(identity.current_user_id(), owner_id, 'COLLECTION')
    OR (
        visibility = 'FAMILY'
        AND identity.can_view_family_shared_owner(identity.current_user_id(), owner_id, 'COLLECTION')
    )
);

CREATE POLICY pol_named_collections_modify
ON collection.collections
FOR ALL
USING (identity.can_manage_owner(identity.current_user_id(), owner_id, 'COLLECTION'))
WITH CHECK (identity.can_manage_owner(identity.current_user_id(), owner_id, 'COLLECTION'));

CREATE POLICY pol_named_collection_memberships_select
ON collection.collection_memberships
FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM collection.collections c
        WHERE c.collection_id = collection.collection_memberships.collection_id
          AND (
              c.visibility = 'PUBLIC'
              OR identity.can_view_owner(identity.current_user_id(), c.owner_id, 'COLLECTION')
              OR (c.visibility='FAMILY' AND identity.can_view_family_shared_owner(identity.current_user_id(), c.owner_id, 'COLLECTION'))
          )
    )
);

CREATE POLICY pol_named_collection_memberships_modify
ON collection.collection_memberships
FOR ALL
USING (
    EXISTS (
        SELECT 1 FROM collection.collections c
        WHERE c.collection_id = collection.collection_memberships.collection_id
          AND identity.can_manage_owner(identity.current_user_id(), c.owner_id, 'COLLECTION')
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM collection.collections c
        WHERE c.collection_id = collection.collection_memberships.collection_id
          AND identity.can_manage_owner(identity.current_user_id(), c.owner_id, 'COLLECTION')
    )
);

CREATE POLICY pol_custom_minifigs_select
ON definition.custom_minifigs
FOR SELECT
USING (
    archived_at IS NULL
    AND (
        visibility IN ('PUBLIC','UNLISTED')
        OR identity.can_view_owner(identity.current_user_id(), owner_id, 'COLLECTION')
        OR (visibility='FAMILY' AND identity.can_view_family_shared_owner(identity.current_user_id(), owner_id, 'COLLECTION'))
    )
);

CREATE POLICY pol_custom_minifigs_modify
ON definition.custom_minifigs
FOR ALL
USING (identity.can_manage_owner(identity.current_user_id(), owner_id, 'COLLECTION'))
WITH CHECK (identity.can_manage_owner(identity.current_user_id(), owner_id, 'COLLECTION'));

\echo '[PASS] 1113_api_v3_rls.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1113_api_v3_rls.sql');
