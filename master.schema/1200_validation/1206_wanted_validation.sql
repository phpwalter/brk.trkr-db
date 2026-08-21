/*
===============================================================================
 File:           1200_validation/1206_wanted_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate wishlists, wishlist entries, gift reservations, build
                 goals, and build allocations.
 Depends On:     Complete 0600_wanted domain
                 collection.entries
                 collection.instances
                 definition.inventory_versions
 Creates:        No persistent database objects.
 Key Rules:      Each owner may have at most one active default wishlist.
                 Wishlist entries target exactly one catalog item or part
                 variant.
                 Completed build goals require completion timestamps.
                 Completion goals must reference an owned physical instance.
                 Build allocations must belong to the same owner as their goal.
 Validation:     Checks default wishlist uniqueness, target integrity, goal state,
                 goal/instance ownership, allocation ownership, and reservation
                 chronology.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1206_wanted_validation.sql', ARRAY['Complete 0600_wanted domain', 'collection.entries', 'collection.instances', 'definition.inventory_versions']::text[]);



\echo '[VALIDATE] 1206_wanted_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required tables                                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_table_exists('wanted', 'wishlists');
SELECT app.assert_table_exists('wanted', 'wishlist_entries');
SELECT app.assert_table_exists('wanted', 'wishlist_reservations');
SELECT app.assert_table_exists('wanted', 'build_goals');
SELECT app.assert_table_exists('wanted', 'build_allocations');


/* -------------------------------------------------------------------------- */
/* One default wishlist per owner                                             */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT owner_id
    FROM wanted.wishlists
    WHERE is_default
      AND archived_at IS NULL
    GROUP BY owner_id
    HAVING count(*) > 1
$$,
'Owner has more than one active default wishlist'
);


/* -------------------------------------------------------------------------- */
/* Wishlist entry target integrity                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.wishlist_entries
    WHERE num_nonnulls(catalog_item_id, part_variant_id) <> 1
$$,
'Wishlist entry does not target exactly one catalog item or part variant'
);


/* -------------------------------------------------------------------------- */
/* Wishlist satisfaction state                                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.wishlist_entries
    WHERE status = 'SATISFIED'
      AND satisfied_at IS NULL
$$,
'SATISFIED wishlist entry is missing satisfied_at'
);


/* -------------------------------------------------------------------------- */
/* Reservation chronology                                                     */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.wishlist_reservations
    WHERE expires_at IS NOT NULL
      AND expires_at <= reserved_at
$$,
'Wishlist reservation expires at or before reservation time'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.wishlist_reservations
    WHERE released_at IS NOT NULL
      AND released_at < reserved_at
$$,
'Wishlist reservation was released before being reserved'
);


/* -------------------------------------------------------------------------- */
/* Completion goal requires an instance                                       */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.build_goals
    WHERE build_goal_type = 'COMPLETE_OWNED_INSTANCE'
      AND collection_instance_id IS NULL
$$,
'COMPLETE_OWNED_INSTANCE goal is missing collection_instance_id'
);


/* -------------------------------------------------------------------------- */
/* Build goal completion state                                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.build_goals
    WHERE status = 'COMPLETE'
      AND completed_at IS NULL
$$,
'Completed build goal is missing completed_at'
);


/* -------------------------------------------------------------------------- */
/* Completion goal instance owner                                             */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.build_goals g

    JOIN collection.instances i
      ON i.collection_instance_id = g.collection_instance_id

    JOIN collection.entries e
      ON e.collection_entry_id = i.collection_entry_id

    WHERE g.collection_instance_id IS NOT NULL
      AND e.owner_id <> g.owner_id
$$,
'Build goal references a physical instance owned by another owner'
);


/* -------------------------------------------------------------------------- */
/* Build allocation owner consistency                                         */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.build_allocations a

    JOIN wanted.build_goals g
      ON g.build_goal_id = a.build_goal_id

    JOIN collection.entries e
      ON e.collection_entry_id = a.collection_entry_id

    WHERE e.owner_id <> g.owner_id
$$,
'Build allocation reserves inventory owned by another owner'
);


/* -------------------------------------------------------------------------- */
/* Build allocation release chronology                                        */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM wanted.build_allocations
    WHERE released_at IS NOT NULL
      AND released_at < allocated_at
$$,
'Build allocation was released before it was allocated'
);


\echo '[VALIDATE PASS] 1206_wanted_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1206_wanted_validation.sql');
