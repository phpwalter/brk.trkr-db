/*
===============================================================================
 File:           1100_security/1103_rls_wanted.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Protect wishlists, reservations, build goals, and allocations.
 Depends On:     Complete 0600_wanted domain
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1103_rls_wanted.sql', ARRAY['Complete 0600_wanted domain', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]);



ALTER TABLE wanted.wishlists ENABLE ROW LEVEL SECURITY;
ALTER TABLE wanted.wishlist_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE wanted.wishlist_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE wanted.build_goals ENABLE ROW LEVEL SECURITY;
ALTER TABLE wanted.build_allocations ENABLE ROW LEVEL SECURITY;


/* Wishlists */
CREATE POLICY pol_wishlists_select
ON wanted.wishlists
FOR SELECT
USING (
    visibility = 'PUBLIC'
    OR identity.can_view_owner(
        identity.current_user_id(),
        owner_id,
        'WISHLIST'
    )
    OR (
        visibility = 'FAMILY'
        AND identity.can_view_family_shared_owner(
            identity.current_user_id(),
            owner_id,
            'WISHLIST'
        )
    )
);

CREATE POLICY pol_wishlists_modify
ON wanted.wishlists
FOR ALL
USING (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'WISHLIST'
    )
)
WITH CHECK (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'WISHLIST'
    )
);


/* Wishlist entries inherit parent visibility and management. */
CREATE POLICY pol_wishlist_entries_select
ON wanted.wishlist_entries
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM wanted.wishlists w
        WHERE w.wishlist_id =
              wanted.wishlist_entries.wishlist_id
          AND (
              w.visibility = 'PUBLIC'
              OR identity.can_view_owner(
                  identity.current_user_id(),
                  w.owner_id,
                  'WISHLIST'
              )
              OR (
                  w.visibility = 'FAMILY'
                  AND identity.can_view_family_shared_owner(
                      identity.current_user_id(),
                      w.owner_id,
                      'WISHLIST'
                  )
              )
          )
    )
);

CREATE POLICY pol_wishlist_entries_modify
ON wanted.wishlist_entries
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM wanted.wishlists w
        WHERE w.wishlist_id =
              wanted.wishlist_entries.wishlist_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              w.owner_id,
              'WISHLIST'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM wanted.wishlists w
        WHERE w.wishlist_id =
              wanted.wishlist_entries.wishlist_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              w.owner_id,
              'WISHLIST'
          )
    )
);


/*
 * Reservation secrecy:
 * - reserver always sees/manages their own reservation;
 * - owner may read only rows explicitly marked non-hidden;
 * - owner never gains modification rights to another person's reservation.
 */
CREATE POLICY pol_wishlist_reservations_reserver_select
ON wanted.wishlist_reservations
FOR SELECT
USING (
    reserved_by_user_id = identity.current_user_id()
);

CREATE POLICY pol_wishlist_reservations_owner_visible_select
ON wanted.wishlist_reservations
FOR SELECT
USING (
    NOT hidden_from_owner
    AND EXISTS (
        SELECT 1
        FROM wanted.wishlist_entries e
        JOIN wanted.wishlists w
          ON w.wishlist_id = e.wishlist_id
        WHERE e.wishlist_entry_id =
              wanted.wishlist_reservations.wishlist_entry_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              w.owner_id,
              'WISHLIST'
          )
    )
);

CREATE POLICY pol_wishlist_reservations_reserver_modify
ON wanted.wishlist_reservations
FOR ALL
USING (
    reserved_by_user_id = identity.current_user_id()
)
WITH CHECK (
    reserved_by_user_id = identity.current_user_id()
);


/* Build goals */
CREATE POLICY pol_build_goals_select
ON wanted.build_goals
FOR SELECT
USING (
    identity.can_view_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
);

CREATE POLICY pol_build_goals_modify
ON wanted.build_goals
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


/* Build allocations inherit the goal's owner authorization. */
CREATE POLICY pol_build_allocations_select
ON wanted.build_allocations
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM wanted.build_goals bg
        WHERE bg.build_goal_id =
              wanted.build_allocations.build_goal_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              bg.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_build_allocations_modify
ON wanted.build_allocations
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM wanted.build_goals bg
        WHERE bg.build_goal_id =
              wanted.build_allocations.build_goal_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              bg.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM wanted.build_goals bg
        WHERE bg.build_goal_id =
              wanted.build_allocations.build_goal_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              bg.owner_id,
              'COLLECTION'
          )
    )
);

\echo '[PASS] 1103_rls_wanted.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1103_rls_wanted.sql');
