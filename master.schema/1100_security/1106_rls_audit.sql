/*
===============================================================================
 File:           1100_security/1106_rls_audit.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Prevent ordinary application-role access to internal audit
                 history.
 Depends On:     audit.events
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
SELECT pg_temp.bt_preflight('1100_security/1106_rls_audit.sql', ARRAY['audit.events', 'audit.changes']::text[]);



ALTER TABLE audit.events
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE audit.changes
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE audit.events
    FORCE ROW LEVEL SECURITY;

ALTER TABLE audit.changes
    FORCE ROW LEVEL SECURITY;

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

\echo '[PASS] 1106_rls_audit.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1106_rls_audit.sql');
