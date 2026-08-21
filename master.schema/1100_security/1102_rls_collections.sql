/*
===============================================================================
 File:           1100_security/1102_rls_collections.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Apply complete owner-aware RLS across the collection domain.
 Depends On:     Complete 0500_collections domain
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1102_rls_collections.sql', ARRAY['Complete 0500_collections domain', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]);



ALTER TABLE collection.storage_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.instance_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.storage_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.acquisitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.acquisition_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE collection.entry_tags ENABLE ROW LEVEL SECURITY;


/* Storage locations */
CREATE POLICY pol_storage_select
ON collection.storage_locations
FOR SELECT
USING (
    identity.can_view_owner(
        identity.current_user_id(),
        owner_id,
        'STORAGE'
    )
);

CREATE POLICY pol_storage_modify
ON collection.storage_locations
FOR ALL
USING (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'STORAGE'
    )
)
WITH CHECK (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'STORAGE'
    )
);


/* Collection entries */
CREATE POLICY pol_collection_entry_select
ON collection.entries
FOR SELECT
USING (
    identity.can_view_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
);

CREATE POLICY pol_collection_entry_modify
ON collection.entries
FOR ALL
USING (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
)
WITH CHECK (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
);


/* Physical instances */
CREATE POLICY pol_collection_instance_select
ON collection.instances
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        WHERE e.collection_entry_id =
              collection.instances.collection_entry_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_collection_instance_modify
ON collection.instances
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        WHERE e.collection_entry_id =
              collection.instances.collection_entry_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        WHERE e.collection_entry_id =
              collection.instances.collection_entry_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
);


/* Instance adjustments */
CREATE POLICY pol_instance_adjustments_select
ON collection.instance_adjustments
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM collection.instances i
        JOIN collection.entries e
          ON e.collection_entry_id = i.collection_entry_id
        WHERE i.collection_instance_id =
              collection.instance_adjustments.collection_instance_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_instance_adjustments_modify
ON collection.instance_adjustments
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM collection.instances i
        JOIN collection.entries e
          ON e.collection_entry_id = i.collection_entry_id
        WHERE i.collection_instance_id =
              collection.instance_adjustments.collection_instance_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM collection.instances i
        JOIN collection.entries e
          ON e.collection_entry_id = i.collection_entry_id
        WHERE i.collection_instance_id =
              collection.instance_adjustments.collection_instance_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
);


/* Storage allocations require collection visibility plus storage authority. */
CREATE POLICY pol_storage_allocations_select
ON collection.storage_allocations
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        JOIN collection.storage_locations s
          ON s.storage_location_id =
             collection.storage_allocations.storage_location_id
        WHERE e.collection_entry_id =
              collection.storage_allocations.collection_entry_id
          AND e.owner_id = s.owner_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
          AND identity.can_view_owner(
              identity.current_user_id(),
              s.owner_id,
              'STORAGE'
          )
    )
);

CREATE POLICY pol_storage_allocations_modify
ON collection.storage_allocations
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        JOIN collection.storage_locations s
          ON s.storage_location_id =
             collection.storage_allocations.storage_location_id
        WHERE e.collection_entry_id =
              collection.storage_allocations.collection_entry_id
          AND e.owner_id = s.owner_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
          AND identity.can_manage_owner(
              identity.current_user_id(),
              s.owner_id,
              'STORAGE'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        JOIN collection.storage_locations s
          ON s.storage_location_id =
             collection.storage_allocations.storage_location_id
        WHERE e.collection_entry_id =
              collection.storage_allocations.collection_entry_id
          AND e.owner_id = s.owner_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
          AND identity.can_manage_owner(
              identity.current_user_id(),
              s.owner_id,
              'STORAGE'
          )
    )
);


/* Acquisitions and acquisition items */
CREATE POLICY pol_acquisitions_select
ON collection.acquisitions
FOR SELECT
USING (
    identity.can_view_owner(
        identity.current_user_id(),
        owner_id,
        'PURCHASES'
    )
);

CREATE POLICY pol_acquisitions_modify
ON collection.acquisitions
FOR ALL
USING (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'PURCHASES'
    )
)
WITH CHECK (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'PURCHASES'
    )
);

CREATE POLICY pol_acquisition_items_select
ON collection.acquisition_items
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM collection.acquisitions a
        WHERE a.acquisition_id =
              collection.acquisition_items.acquisition_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              a.owner_id,
              'PURCHASES'
          )
    )
);

CREATE POLICY pol_acquisition_items_modify
ON collection.acquisition_items
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM collection.acquisitions a
        WHERE a.acquisition_id =
              collection.acquisition_items.acquisition_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              a.owner_id,
              'PURCHASES'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM collection.acquisitions a
        WHERE a.acquisition_id =
              collection.acquisition_items.acquisition_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              a.owner_id,
              'PURCHASES'
          )
    )
);


/* Tags */
CREATE POLICY pol_tags_select
ON collection.tags
FOR SELECT
USING (
    identity.can_view_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
);

CREATE POLICY pol_tags_modify
ON collection.tags
FOR ALL
USING (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
)
WITH CHECK (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
);

CREATE POLICY pol_entry_tags_select
ON collection.entry_tags
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        WHERE e.collection_entry_id =
              collection.entry_tags.collection_entry_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_entry_tags_modify
ON collection.entry_tags
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        WHERE e.collection_entry_id =
              collection.entry_tags.collection_entry_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM collection.entries e
        WHERE e.collection_entry_id =
              collection.entry_tags.collection_entry_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
);


/* Transfers are readable by either side and insert-only for authorized actors. */
CREATE POLICY pol_transfers_select
ON collection.transfers
FOR SELECT
USING (
    identity.can_view_owner(
        identity.current_user_id(),
        from_owner_id,
        'COLLECTION'
    )
    OR identity.can_view_owner(
        identity.current_user_id(),
        to_owner_id,
        'COLLECTION'
    )
);

CREATE POLICY pol_transfers_insert
ON collection.transfers
FOR INSERT
WITH CHECK (
    actor_user_id = identity.current_user_id()
    AND identity.can_transfer_between(
        identity.current_user_id(),
        from_owner_id,
        to_owner_id
    )
);

\echo '[PASS] 1102_rls_collections.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1102_rls_collections.sql');
