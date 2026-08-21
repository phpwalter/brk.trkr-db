/*
===============================================================================
 File:           1200_validation/1205_collection_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate ownership, physical instances, storage, acquisitions,
                 tags, adjustments, and transfer relationships.
 Depends On:     Complete 0500_collections domain
 Creates:        No persistent database objects.
 Key Rules:      Collection entries belong to one owner.
                 Physical instances belong to their parent collection entry.
                 Storage locations and stored inventory must share an owner.
                 Owner-scoped tags may not cross ownership boundaries.
                 Acquisition records may only reference inventory owned by the
                 acquisition owner.
                 Transfers must move inventory between distinct owners.
 Validation:     Checks storage-owner consistency, instance/entry relationships,
                 tag isolation, acquisition ownership, adjustment consistency,
                 and transfer relationships.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1205_collection_validation.sql', ARRAY['Complete 0500_collections domain']::text[]);



\echo '[VALIDATE] 1205_collection_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required tables                                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_table_exists('collection', 'storage_locations');
SELECT app.assert_table_exists('collection', 'entries');
SELECT app.assert_table_exists('collection', 'instances');
SELECT app.assert_table_exists('collection', 'instance_adjustments');
SELECT app.assert_table_exists('collection', 'storage_allocations');
SELECT app.assert_table_exists('collection', 'transfers');
SELECT app.assert_table_exists('collection', 'acquisitions');
SELECT app.assert_table_exists('collection', 'acquisition_items');
SELECT app.assert_table_exists('collection', 'tags');
SELECT app.assert_table_exists('collection', 'entry_tags');


/* -------------------------------------------------------------------------- */
/* Storage location hierarchy owner consistency                               */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.storage_locations child
    JOIN collection.storage_locations parent
      ON parent.storage_location_id =
         child.parent_storage_location_id
    WHERE child.owner_id <> parent.owner_id
$$,
'Storage hierarchy crosses owner boundaries'
);


/* -------------------------------------------------------------------------- */
/* Storage allocation owner consistency                                       */
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


/* -------------------------------------------------------------------------- */
/* Instance allocation consistency                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.storage_allocations a
    JOIN collection.instances i
      ON i.collection_instance_id = a.collection_instance_id
    WHERE a.collection_instance_id IS NOT NULL
      AND i.collection_entry_id <> a.collection_entry_id
$$,
'Storage allocation references an instance from another collection entry'
);


/* -------------------------------------------------------------------------- */
/* Instance adjustment target consistency                                     */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.instance_adjustments
    WHERE num_nonnulls(catalog_item_id, part_variant_id) <> 1
$$,
'Instance adjustment does not target exactly one item or part variant'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.instance_adjustments
    WHERE adjustment_type = 'SUBSTITUTED'
      AND num_nonnulls(
          replacement_catalog_item_id,
          replacement_part_variant_id
      ) <> 1
$$,
'Substituted instance adjustment lacks exactly one replacement target'
);


/* -------------------------------------------------------------------------- */
/* Tag owner consistency                                                      */
/* -------------------------------------------------------------------------- */

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
'Owner-scoped collection tag is attached to another owner''s entry'
);


/* -------------------------------------------------------------------------- */
/* Acquisition owner consistency                                              */
/* -------------------------------------------------------------------------- */

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
'Acquisition references a collection entry owned by another owner'
);


/* -------------------------------------------------------------------------- */
/* Acquisition instance consistency                                           */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.acquisition_items ai

    JOIN collection.instances i
      ON i.collection_instance_id = ai.collection_instance_id

    WHERE ai.collection_instance_id IS NOT NULL
      AND i.collection_entry_id <> ai.collection_entry_id
$$,
'Acquisition item references an instance belonging to another entry'
);


/* -------------------------------------------------------------------------- */
/* Transfer sanity                                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM collection.transfers
    WHERE from_owner_id = to_owner_id
$$,
'Collection transfer has identical source and destination owners'
);


/* -------------------------------------------------------------------------- */
/* Storage hierarchy cycles                                                   */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    WITH RECURSIVE storage_paths AS (
        SELECT
            s.storage_location_id AS origin_location_id,
            s.parent_storage_location_id AS current_location_id,
            ARRAY[s.storage_location_id] AS path,
            false AS cycle_found
        FROM collection.storage_locations s
        WHERE s.parent_storage_location_id IS NOT NULL

        UNION ALL

        SELECT
            p.origin_location_id,
            s.parent_storage_location_id,
            p.path || s.storage_location_id,
            s.storage_location_id = ANY(p.path)
        FROM storage_paths p
        JOIN collection.storage_locations s
          ON s.storage_location_id = p.current_location_id
        WHERE NOT p.cycle_found
          AND p.current_location_id IS NOT NULL
    )
    SELECT 1
    FROM storage_paths
    WHERE cycle_found
$$,
'Storage location hierarchy contains a recursive cycle'
);


\echo '[VALIDATE PASS] 1205_collection_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1205_collection_validation.sql');
