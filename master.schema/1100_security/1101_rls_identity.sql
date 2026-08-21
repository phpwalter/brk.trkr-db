/*
===============================================================================
 File:           1100_security/1101_rls_identity.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Protect authentication credentials, sessions and one-time
                 tokens with row-level security.
 Depends On:     identity.user_credentials
                 identity.user_sessions
                 identity.one_time_tokens
                 identity.current_user_id()
                 identity.can_manage_user()
 Creates:        RLS policies on authentication tables
 Key Rules:      Users may manage their own security resources.
                 Delegated family security management requires SECURITY
                 capability.
                 Ordinary users cannot access unrelated authentication records.
 Validation:     Enables RLS and defines ALL policies with matching USING and
                 WITH CHECK authorization predicates.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1101_rls_identity.sql', ARRAY['identity.user_credentials', 'identity.user_sessions', 'identity.one_time_tokens', 'identity.current_user_id()', 'identity.can_manage_user()']::text[]);



ALTER TABLE identity.user_credentials
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE identity.user_sessions
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE identity.one_time_tokens
    ENABLE ROW LEVEL SECURITY;


CREATE POLICY pol_credentials_manage
ON identity.user_credentials
FOR ALL
USING (
    identity.can_manage_user(
        identity.current_user_id(),
        user_id,
        'SECURITY'
    )
)
WITH CHECK (
    identity.can_manage_user(
        identity.current_user_id(),
        user_id,
        'SECURITY'
    )
);


CREATE POLICY pol_sessions_manage
ON identity.user_sessions
FOR ALL
USING (
    identity.can_manage_user(
        identity.current_user_id(),
        user_id,
        'SECURITY'
    )
)
WITH CHECK (
    identity.can_manage_user(
        identity.current_user_id(),
        user_id,
        'SECURITY'
    )
);


CREATE POLICY pol_tokens_manage
ON identity.one_time_tokens
FOR ALL
USING (
    identity.can_manage_user(
        identity.current_user_id(),
        user_id,
        'SECURITY'
    )
)
WITH CHECK (
    identity.can_manage_user(
        identity.current_user_id(),
        user_id,
        'SECURITY'
    )
);

\echo '[PASS] 1101_rls_identity.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1101_rls_identity.sql');
