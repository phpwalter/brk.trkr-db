/*
===============================================================================
 File:           1100_security/1104_rls_mocs.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Protect all MOC tables and make UNLISTED content non-enumerable.
 Key Rules:      Direct table SELECT exposes PUBLIC rows, FAMILY-shared rows,
                 and rows visible to their owner/manager.
                 UNLISTED rows are deliberately excluded from direct public
                 table scans; exact-ID access is provided by api.get_moc_*().
 Depends On:     Complete 0700_mocs domain
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1104_rls_mocs.sql', ARRAY['Complete 0700_mocs domain', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]);



ALTER TABLE moc.mocs ENABLE ROW LEVEL SECURITY;
ALTER TABLE moc.revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE moc.forks ENABLE ROW LEVEL SECURITY;
ALTER TABLE moc.subassemblies ENABLE ROW LEVEL SECURITY;
ALTER TABLE moc.licenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE moc.assets ENABLE ROW LEVEL SECURITY;


/* MOC root */
CREATE POLICY pol_mocs_select
ON moc.mocs
FOR SELECT
USING (
    visibility = 'PUBLIC'
    OR identity.can_view_owner(
        identity.current_user_id(),
        owner_id,
        'MOCS'
    )
    OR (
        visibility = 'FAMILY'
        AND identity.can_view_family_shared_owner(
            identity.current_user_id(),
            owner_id,
            'MOCS'
        )
    )
);

CREATE POLICY pol_mocs_modify
ON moc.mocs
FOR ALL
USING (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'MOCS'
    )
)
WITH CHECK (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'MOCS'
    )
);


/* Revisions: non-owners see published revisions only. */
CREATE POLICY pol_moc_revisions_select
ON moc.revisions
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM moc.mocs m
        WHERE m.moc_id = moc.revisions.moc_id
          AND (
              identity.can_view_owner(
                  identity.current_user_id(),
                  m.owner_id,
                  'MOCS'
              )
              OR (
                  moc.revisions.status = 'PUBLISHED'
                  AND (
                      m.visibility = 'PUBLIC'
                      OR (
                          m.visibility = 'FAMILY'
                          AND identity.can_view_family_shared_owner(
                              identity.current_user_id(),
                              m.owner_id,
                              'MOCS'
                          )
                      )
                  )
              )
          )
    )
);

CREATE POLICY pol_moc_revisions_modify
ON moc.revisions
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM moc.mocs m
        WHERE m.moc_id = moc.revisions.moc_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              m.owner_id,
              'MOCS'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM moc.mocs m
        WHERE m.moc_id = moc.revisions.moc_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              m.owner_id,
              'MOCS'
          )
    )
);


/* Shared child visibility predicate repeated explicitly to avoid helper
 * functions that could accidentally make UNLISTED rows enumerable. */
CREATE POLICY pol_moc_subassemblies_select
ON moc.subassemblies
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m
          ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id =
              moc.subassemblies.moc_revision_id
          AND (
              identity.can_view_owner(
                  identity.current_user_id(),
                  m.owner_id,
                  'MOCS'
              )
              OR (
                  r.status = 'PUBLISHED'
                  AND (
                      m.visibility = 'PUBLIC'
                      OR (
                          m.visibility = 'FAMILY'
                          AND identity.can_view_family_shared_owner(
                              identity.current_user_id(),
                              m.owner_id,
                              'MOCS'
                          )
                      )
                  )
              )
          )
    )
);

CREATE POLICY pol_moc_subassemblies_modify
ON moc.subassemblies
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id =
              moc.subassemblies.moc_revision_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              m.owner_id,
              'MOCS'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id =
              moc.subassemblies.moc_revision_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              m.owner_id,
              'MOCS'
          )
    )
);


CREATE POLICY pol_moc_licenses_select
ON moc.licenses
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id = moc.licenses.moc_revision_id
          AND (
              identity.can_view_owner(
                  identity.current_user_id(),
                  m.owner_id,
                  'MOCS'
              )
              OR (
                  r.status = 'PUBLISHED'
                  AND (
                      m.visibility = 'PUBLIC'
                      OR (
                          m.visibility = 'FAMILY'
                          AND identity.can_view_family_shared_owner(
                              identity.current_user_id(),
                              m.owner_id,
                              'MOCS'
                          )
                      )
                  )
              )
          )
    )
);

CREATE POLICY pol_moc_licenses_modify
ON moc.licenses
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id = moc.licenses.moc_revision_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              m.owner_id,
              'MOCS'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id = moc.licenses.moc_revision_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              m.owner_id,
              'MOCS'
          )
    )
);


CREATE POLICY pol_moc_assets_select
ON moc.assets
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id = moc.assets.moc_revision_id
          AND (
              identity.can_view_owner(
                  identity.current_user_id(),
                  m.owner_id,
                  'MOCS'
              )
              OR (
                  r.status = 'PUBLISHED'
                  AND (
                      m.visibility = 'PUBLIC'
                      OR (
                          m.visibility = 'FAMILY'
                          AND identity.can_view_family_shared_owner(
                              identity.current_user_id(),
                              m.owner_id,
                              'MOCS'
                          )
                      )
                  )
              )
          )
    )
);

CREATE POLICY pol_moc_assets_modify
ON moc.assets
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id = moc.assets.moc_revision_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              m.owner_id,
              'MOCS'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM moc.revisions r
        JOIN moc.mocs m ON m.moc_id = r.moc_id
        WHERE r.moc_revision_id = moc.assets.moc_revision_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              m.owner_id,
              'MOCS'
          )
    )
);


/* Fork ancestry is visible only when both source and fork are directly visible. */
CREATE POLICY pol_moc_forks_select
ON moc.forks
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM moc.mocs src
        JOIN moc.mocs dst
          ON dst.moc_id = moc.forks.forked_moc_id
        WHERE src.moc_id = moc.forks.source_moc_id
          AND (
              src.visibility = 'PUBLIC'
              OR identity.can_view_owner(
                  identity.current_user_id(),
                  src.owner_id,
                  'MOCS'
              )
              OR (
                  src.visibility = 'FAMILY'
                  AND identity.can_view_family_shared_owner(
                      identity.current_user_id(),
                      src.owner_id,
                      'MOCS'
                  )
              )
          )
          AND (
              dst.visibility = 'PUBLIC'
              OR identity.can_view_owner(
                  identity.current_user_id(),
                  dst.owner_id,
                  'MOCS'
              )
              OR (
                  dst.visibility = 'FAMILY'
                  AND identity.can_view_family_shared_owner(
                      identity.current_user_id(),
                      dst.owner_id,
                      'MOCS'
                  )
              )
          )
    )
);

CREATE POLICY pol_moc_forks_modify
ON moc.forks
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM moc.mocs dst
        WHERE dst.moc_id = moc.forks.forked_moc_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              dst.owner_id,
              'MOCS'
          )
    )
)
WITH CHECK (
    forked_by_user_id = identity.current_user_id()
    AND EXISTS (
        SELECT 1
        FROM moc.mocs src
        JOIN moc.mocs dst
          ON dst.moc_id = moc.forks.forked_moc_id
        WHERE src.moc_id = moc.forks.source_moc_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              dst.owner_id,
              'MOCS'
          )
          AND (
              src.visibility = 'PUBLIC'
              OR identity.can_view_owner(
                  identity.current_user_id(),
                  src.owner_id,
                  'MOCS'
              )
              OR (
                  src.visibility = 'FAMILY'
                  AND identity.can_view_family_shared_owner(
                      identity.current_user_id(),
                      src.owner_id,
                      'MOCS'
                  )
              )
          )
    )
);

\echo '[PASS] 1104_rls_mocs.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1104_rls_mocs.sql');
