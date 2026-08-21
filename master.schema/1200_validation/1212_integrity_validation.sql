/*
===============================================================================
 File:           1200_validation/1212_integrity_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Validate cross-domain integrity hardening and regression guards.
 Depends On:     1000_function/1009_integrity_hardening.sql
                 1100_security/1108_rls_catalog_definition.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1212_integrity_validation.sql', ARRAY['1000_function/1009_integrity_hardening.sql', '1100_security/1108_rls_catalog_definition.sql']::text[]);



\echo '[VALIDATE] 1212_integrity_validation.sql'

/* -------------------------------------------------------------------------- */
/* Correct external color source FK                                           */
/* -------------------------------------------------------------------------- */

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'reference'
          AND table_name = 'external_color_mappings'
          AND column_name = 'source_id'
          AND data_type = 'smallint'
          AND is_nullable = 'NO'
    ),
    'reference.external_color_mappings.source_id must be NOT NULL smallint'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class src ON src.oid = c.conrelid
        JOIN pg_namespace src_ns ON src_ns.oid = src.relnamespace
        JOIN pg_class dst ON dst.oid = c.confrelid
        JOIN pg_namespace dst_ns ON dst_ns.oid = dst.relnamespace
        WHERE src_ns.nspname = 'reference'
          AND src.relname = 'external_color_mappings'
          AND c.conname = 'fk_external_color_mappings_source'
          AND dst_ns.nspname = 'reference'
          AND dst.relname = 'external_sources'
          AND pg_get_constraintdef(c.oid) ILIKE '%(source_id)%REFERENCES reference.external_sources(source_id)%'
    ),
    'External color mapping source FK is not bound to reference.external_sources(source_id)'
);


/* -------------------------------------------------------------------------- */
/* Hardening indexes                                                          */
/* -------------------------------------------------------------------------- */

DO $$
DECLARE
    v_index text;
    v_schema text;
    v_name text;
BEGIN
    FOREACH v_index IN ARRAY ARRAY[
        'catalog.uq_part_variants_identity',
        'catalog.uq_lego_elements_active_id',
        'catalog.ix_catalog_parts_superseded_by',
        'collection.ix_acquisitions_owner',
        'collection.ix_acquisition_items_instance',
        'collection.ix_collection_transfers_from_owner_time',
        'collection.ix_collection_transfers_to_owner_time',
        'wanted.ix_wishlist_entries_catalog_item',
        'wanted.ix_wishlist_reservations_user_active',
        'moc.ix_moc_revisions_parent',
        'moc.uq_moc_assets_storage_key',
        'import.uq_user_mapping_suggestion_identity',
        'import.ix_import_jobs_source',
        'import.ix_import_application_changes_entity',
        'audit.ix_audit_events_owner_time'
    ]
    LOOP
        v_schema := split_part(v_index, '.', 1);
        v_name := split_part(v_index, '.', 2);

        PERFORM app.assert_true(
            to_regclass(v_schema || '.' || v_name) IS NOT NULL,
            format('Required hardening index %s is missing', v_index)
        );
    END LOOP;
END;
$$;


/* -------------------------------------------------------------------------- */
/* Lifecycle coherence                                                        */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM identity.users
    WHERE (account_status = 'ARCHIVED') <> (archived_at IS NOT NULL)
$$,
'identity.users contains incoherent ARCHIVED state'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM identity.families
    WHERE (status = 'ARCHIVED') <> (archived_at IS NOT NULL)
$$,
'identity.families contains incoherent ARCHIVED state'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.items
    WHERE (status = 'ARCHIVED') <> (archived_at IS NOT NULL)
$$,
'catalog.items contains incoherent ARCHIVED state'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.entries
    WHERE (status = 'ARCHIVED') <> (archived_at IS NOT NULL)
$$,
'collection.entries contains incoherent ARCHIVED state'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM identity.one_time_tokens
    WHERE consumed_at IS NOT NULL
      AND consumed_at > expires_at
$$,
'A one-time token was consumed after expiry'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM identity.user_sessions
    WHERE last_seen_at > expires_at
$$,
'A session has last_seen_at after expires_at'
);


/* -------------------------------------------------------------------------- */
/* Definition/source coherence                                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.inventory_versions
    WHERE
        (
            source_id IS NULL
            AND (
                source_external_id IS NOT NULL
                OR source_external_version IS NOT NULL
                OR source_run_id IS NOT NULL
            )
        )
        OR
        (
            source_id IS NOT NULL
            AND (
                source_external_id IS NULL
                OR btrim(source_external_id) = ''
            )
        )
        OR
        (
            status = 'DRAFT'
            AND finalized_at IS NOT NULL
        )
$$,
'Inventory version source/finalization metadata is incoherent'
);

SELECT app.assert_no_rows(
$$
    SELECT rg.requirement_group_id
    FROM definition.inventory_versions v
    JOIN definition.requirement_groups rg
      ON rg.inventory_version_id = v.inventory_version_id
    LEFT JOIN definition.requirement_options ro
      ON ro.requirement_group_id = rg.requirement_group_id
    WHERE v.status = 'FINALIZED'
    GROUP BY
        rg.requirement_group_id,
        rg.fulfillment_rule,
        rg.minimum_options
    HAVING count(ro.requirement_option_id) = 0
        OR (
            rg.fulfillment_rule = 'AT_LEAST_N'
            AND count(ro.requirement_option_id) < rg.minimum_options
        )
$$,
'A finalized inventory version contains an invalid requirement group'
);


/* -------------------------------------------------------------------------- */
/* Collection cross-owner/cross-parent coherence                              */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.storage_allocations a
    JOIN collection.entries e
      ON e.collection_entry_id = a.collection_entry_id
    JOIN collection.storage_locations s
      ON s.storage_location_id = a.storage_location_id
    WHERE e.owner_id <> s.owner_id
$$,
'Storage allocation crosses owner boundaries'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.storage_allocations a
    JOIN collection.instances i
      ON i.collection_instance_id = a.collection_instance_id
    WHERE a.collection_instance_id IS NOT NULL
      AND i.collection_entry_id <> a.collection_entry_id
$$,
'Storage allocation instance belongs to another entry'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.acquisition_items ai
    JOIN collection.acquisitions a
      ON a.acquisition_id = ai.acquisition_id
    JOIN collection.entries e
      ON e.collection_entry_id = ai.collection_entry_id
    WHERE a.owner_id <> e.owner_id
$$,
'Acquisition item points at a collection entry owned by someone else'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.acquisition_items ai
    JOIN collection.instances i
      ON i.collection_instance_id = ai.collection_instance_id
    WHERE ai.collection_instance_id IS NOT NULL
      AND i.collection_entry_id <> ai.collection_entry_id
$$,
'Acquisition item instance belongs to another collection entry'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.entry_tags et
    JOIN collection.entries e
      ON e.collection_entry_id = et.collection_entry_id
    JOIN collection.tags t
      ON t.tag_id = et.tag_id
    WHERE e.owner_id <> t.owner_id
$$,
'Collection tag crosses owner boundaries'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.instance_adjustments a
    JOIN collection.instances i
      ON i.collection_instance_id = a.collection_instance_id
    JOIN definition.requirement_groups g
      ON g.requirement_group_id = a.expected_requirement_group_id
    WHERE a.expected_requirement_group_id IS NOT NULL
      AND (
          i.inventory_version_id IS NULL
          OR i.inventory_version_id <> g.inventory_version_id
      )
$$,
'Instance adjustment requirement group belongs to another inventory version'
);


/* -------------------------------------------------------------------------- */
/* Wanted/build integrity                                                     */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.wishlist_entries e
    JOIN definition.inventory_versions v
      ON v.inventory_version_id = e.preferred_inventory_version_id
    JOIN definition.inventory_definitions d
      ON d.inventory_definition_id = v.inventory_definition_id
    WHERE e.preferred_inventory_version_id IS NOT NULL
      AND (
          e.catalog_item_id IS NULL
          OR d.catalog_item_id <> e.catalog_item_id
      )
$$,
'Wishlist entry preferred inventory version does not match the target item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.build_goals bg
    JOIN definition.inventory_versions v
      ON v.inventory_version_id = bg.inventory_version_id
    JOIN definition.inventory_definitions d
      ON d.inventory_definition_id = v.inventory_definition_id
    WHERE d.catalog_item_id <> bg.target_catalog_item_id
$$,
'Build-goal inventory version does not describe the target item'
);

SELECT app.assert_no_rows(
$$
    SELECT r.wishlist_entry_id
    FROM wanted.wishlist_reservations r
    JOIN wanted.wishlist_entries e
      ON e.wishlist_entry_id = r.wishlist_entry_id
    WHERE r.released_at IS NULL
      AND (r.expires_at IS NULL OR r.expires_at > now())
    GROUP BY r.wishlist_entry_id, e.desired_quantity
    HAVING sum(r.quantity) > e.desired_quantity
$$,
'Active wishlist reservations exceed desired quantity'
);

SELECT app.assert_no_rows(
$$
    SELECT a.collection_entry_id
    FROM wanted.build_allocations a
    JOIN collection.entries e
      ON e.collection_entry_id = a.collection_entry_id
    WHERE a.released_at IS NULL
    GROUP BY a.collection_entry_id, e.quantity
    HAVING sum(a.quantity) > e.quantity
$$,
'Active build allocations exceed owned quantity'
);


/* -------------------------------------------------------------------------- */
/* MOC lineage/version coherence                                              */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.revisions child
    JOIN moc.revisions parent
      ON parent.moc_revision_id = child.parent_revision_id
    WHERE child.parent_revision_id IS NOT NULL
      AND (
          child.moc_id <> parent.moc_id
          OR parent.revision_number >= child.revision_number
      )
$$,
'MOC revision parent lineage is invalid'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.revisions r
    JOIN moc.mocs m
      ON m.moc_id = r.moc_id
    JOIN definition.inventory_versions v
      ON v.inventory_version_id = r.inventory_version_id
    JOIN definition.inventory_definitions d
      ON d.inventory_definition_id = v.inventory_definition_id
    WHERE r.inventory_version_id IS NOT NULL
      AND d.catalog_item_id <> m.catalog_item_id
$$,
'MOC revision inventory version does not describe its MOC catalog item'
);


/* -------------------------------------------------------------------------- */
/* Import parent consistency                                                  */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.normalized_records n
    JOIN import.raw_records r
      ON r.raw_record_id = n.raw_record_id
    WHERE n.raw_record_id IS NOT NULL
      AND r.import_job_id <> n.import_job_id
$$,
'Normalized record references a raw record from another import job'
);

\echo '[VALIDATE PASS] 1212_integrity_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1212_integrity_validation.sql');
