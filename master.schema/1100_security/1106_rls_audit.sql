/*
===============================================================================
 File:           1100_security/1106_rls_audit.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Prevent ordinary application-role access to internal audit
                 history.
 Depends On:     1100_security/1100_roles.sql
                 audit.events
                 audit.changes
 Creates:        RLS/forced-RLS configuration on audit tables
 Key Rules:      No ordinary-user audit policy is intentionally defined.
                 Audit access is limited to trusted administrative/import paths.
                 Audit data remains append-only independently of RLS.
 Validation:     Enables and forces RLS on both audit tables and verifies the
                 audit.events RLS flag.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1106_rls_audit.sql', ARRAY['1100_security/1100_roles.sql', 'audit.events', 'audit.changes']::text[]);



ALTER TABLE audit.events
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE audit.changes
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE audit.events
    FORCE ROW LEVEL SECURITY;

ALTER TABLE audit.changes
    FORCE ROW LEVEL SECURITY;


-- FORCE RLS intentionally remains enabled.  The trusted SECURITY DEFINER audit
-- capture path runs as brktrkr_owner, so grant that owner role only the minimum
-- row-policy access required to append audit history and return inserted IDs.
-- Runtime/admin roles receive no audit policies.
CREATE POLICY audit_events_owner_insert
ON audit.events
FOR INSERT
TO brktrkr_owner
WITH CHECK (true);

CREATE POLICY audit_events_owner_select
ON audit.events
FOR SELECT
TO brktrkr_owner
USING (true);

CREATE POLICY audit_changes_owner_insert
ON audit.changes
FOR INSERT
TO brktrkr_owner
WITH CHECK (true);

CREATE POLICY audit_changes_owner_select
ON audit.changes
FOR SELECT
TO brktrkr_owner
USING (true);

SELECT app.assert_true(
    (
        SELECT relrowsecurity
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'audit'
          AND c.relname = 'events'
    ),
    'RLS was not enabled on audit.events'
);


DO $$
DECLARE
    v_expected text[] := ARRAY[
        'audit_events_owner_insert',
        'audit_events_owner_select',
        'audit_changes_owner_insert',
        'audit_changes_owner_select'
    ];
    v_policy text;
BEGIN
    FOREACH v_policy IN ARRAY v_expected
    LOOP
        PERFORM app.assert_true(
            EXISTS (
                SELECT 1
                FROM pg_policies
                WHERE schemaname = 'audit'
                  AND policyname = v_policy
                  AND roles = ARRAY['brktrkr_owner']::name[]
            ),
            format('Required owner-only audit RLS policy %I is missing or broadened', v_policy)
        );
    END LOOP;

    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT 1
            FROM pg_policies
            WHERE schemaname = 'audit'
              AND (
                    'public'::name = ANY (roles)
                 OR 'brktrkr_api'::name = ANY (roles)
                 OR 'brktrkr_api'::name = ANY (roles)
                 OR 'brktrkr_admin'::name = ANY (roles)
                 OR 'brktrkr_import'::name = ANY (roles)
                 OR 'brktrkr_reporting'::name = ANY (roles)
              )
        ),
        'Audit RLS policies must not grant PUBLIC or operational roles access'
    );
END;
$$;

\echo '[PASS] 1106_rls_audit.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1106_rls_audit.sql');
