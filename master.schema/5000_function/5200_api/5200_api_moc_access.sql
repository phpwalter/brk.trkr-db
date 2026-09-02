/*
===============================================================================
 File:           5000_function/5200_api/5200_api_moc_access.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Provide exact-ID access to PUBLIC/UNLISTED MOCs without making
                 UNLISTED rows enumerable through direct table SELECT.
 Depends On:     api schema
                 moc.mocs
                 moc.revisions
                 moc.assets
                 moc.licenses
                 moc.subassemblies
                 identity.current_user_id()
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5200_api/5200_api_moc_access.sql', ARRAY['api schema', 'moc.mocs', 'moc.revisions', 'moc.assets', 'moc.licenses', 'moc.subassemblies', 'identity.current_user_id()']::text[]);



CREATE FUNCTION api.get_moc_by_id(
    p_moc_id uuid
)
RETURNS SETOF moc.mocs
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, api, moc, identity
AS $$
    SELECT m.*
    FROM moc.mocs m
    WHERE m.moc_id = p_moc_id
      AND m.archived_at IS NULL
      AND (
          m.visibility IN ('PUBLIC', 'UNLISTED')
          OR identity.can_view_owner(
              identity.current_user_id_optional(),
              m.owner_id,
              'MOCS'
          )
      );
$$;


CREATE FUNCTION api.get_moc_revisions(
    p_moc_id uuid
)
RETURNS SETOF moc.revisions
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, api, moc, identity
AS $$
    SELECT r.*
    FROM moc.revisions r
    JOIN moc.mocs m
      ON m.moc_id = r.moc_id
    WHERE m.moc_id = p_moc_id
      AND m.archived_at IS NULL
      AND (
          (
              m.visibility IN ('PUBLIC', 'UNLISTED')
              AND r.status = 'PUBLISHED'
          )
          OR identity.can_view_owner(
              identity.current_user_id_optional(),
              m.owner_id,
              'MOCS'
          )
      )
    ORDER BY r.revision_number DESC;
$$;


CREATE FUNCTION api.get_moc_assets(
    p_moc_id uuid,
    p_moc_revision_id uuid
)
RETURNS SETOF moc.assets
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, api, moc, identity
AS $$
    SELECT a.*
    FROM moc.assets a
    JOIN moc.revisions r
      ON r.moc_revision_id = a.moc_revision_id
    JOIN moc.mocs m
      ON m.moc_id = r.moc_id
    WHERE m.moc_id = p_moc_id
      AND r.moc_revision_id = p_moc_revision_id
      AND m.archived_at IS NULL
      AND (
          (
              m.visibility IN ('PUBLIC', 'UNLISTED')
              AND r.status = 'PUBLISHED'
          )
          OR identity.can_view_owner(
              identity.current_user_id_optional(),
              m.owner_id,
              'MOCS'
          )
      )
    ORDER BY a.created_at, a.moc_asset_id;
$$;


CREATE FUNCTION api.get_moc_licenses(
    p_moc_id uuid,
    p_moc_revision_id uuid
)
RETURNS SETOF moc.licenses
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, api, moc, identity
AS $$
    SELECT l.*
    FROM moc.licenses l
    JOIN moc.revisions r
      ON r.moc_revision_id = l.moc_revision_id
    JOIN moc.mocs m
      ON m.moc_id = r.moc_id
    WHERE m.moc_id = p_moc_id
      AND r.moc_revision_id = p_moc_revision_id
      AND m.archived_at IS NULL
      AND (
          (
              m.visibility IN ('PUBLIC', 'UNLISTED')
              AND r.status = 'PUBLISHED'
          )
          OR identity.can_view_owner(
              identity.current_user_id_optional(),
              m.owner_id,
              'MOCS'
          )
      )
    ORDER BY l.created_at, l.moc_license_id;
$$;


CREATE FUNCTION api.get_moc_subassemblies(
    p_moc_id uuid,
    p_moc_revision_id uuid
)
RETURNS SETOF moc.subassemblies
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, api, moc, identity
AS $$
    SELECT s.*
    FROM moc.subassemblies s
    JOIN moc.revisions r
      ON r.moc_revision_id = s.moc_revision_id
    JOIN moc.mocs m
      ON m.moc_id = r.moc_id
    WHERE m.moc_id = p_moc_id
      AND r.moc_revision_id = p_moc_revision_id
      AND m.archived_at IS NULL
      AND (
          (
              m.visibility IN ('PUBLIC', 'UNLISTED')
              AND r.status = 'PUBLISHED'
          )
          OR identity.can_view_owner(
              identity.current_user_id_optional(),
              m.owner_id,
              'MOCS'
          )
      )
    ORDER BY s.sort_order NULLS LAST, s.subassembly_id;
$$;


/*
 * SECURITY DEFINER functions must not inherit the default PUBLIC EXECUTE grant.
 * 1107_grants.sql grants EXECUTE explicitly to brktrkr_api and brktrkr_admin.
 */
REVOKE ALL ON FUNCTION api.get_moc_by_id(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_moc_revisions(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_moc_assets(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_moc_licenses(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.get_moc_subassemblies(uuid, uuid) FROM PUBLIC;

\echo '[PASS] 1010_moc_access_function.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5200_api_moc_access.sql');
