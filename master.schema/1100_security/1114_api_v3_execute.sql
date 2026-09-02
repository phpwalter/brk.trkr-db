/*
===============================================================================
 File:           1100_security/1114_api_v3_execute.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.1
 PostgreSQL:     16+
 Purpose:        Add the privileged v3 administrator API grant after the normal
                 brktrkr_api surface has been reconciled by 1110.
 Depends On:     1100_security/1110_api_surface_lockdown.sql
                 api.admin_finance_actor_operation()
                 brktrkr_admin role
 Key Rules:      Normal application execution is governed exclusively by the
                 canonical runtime allowlist in 1110. Privileged administration
                 and finance operations are absent from that allowlist and are
                 executable only by brktrkr_admin. The actor-aware dispatcher
                 receives explicit BrickTrackr user attribution while ADMIN
                 request context remains free of USER identity state.
                 PUBLIC receives no authority.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '1100_security/1114_api_v3_execute.sql',
    ARRAY[
        '1100_security/1110_api_surface_lockdown.sql',
        'api.admin_finance_actor_operation()',
        'brktrkr_admin role'
    ]::text[]
);

REVOKE ALL
ON FUNCTION api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)
FROM PUBLIC, brktrkr_api;

/* Retain the legacy internal dispatcher as non-runtime implementation detail. */
REVOKE ALL
ON FUNCTION api.admin_finance_operation(text,jsonb,jsonb)
FROM PUBLIC, brktrkr_api, brktrkr_admin;

GRANT USAGE ON SCHEMA api TO brktrkr_admin;
REVOKE CREATE ON SCHEMA api FROM brktrkr_admin;

GRANT EXECUTE
ON FUNCTION api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)
TO brktrkr_admin;

SELECT app.assert_true(
    has_function_privilege(
        'brktrkr_admin',
        'api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)',
        'EXECUTE'
    ),
    'brktrkr_admin lacks actor-aware administrator API execution authority'
);

SELECT app.assert_true(
    NOT has_function_privilege(
        'brktrkr_api',
        'api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)',
        'EXECUTE'
    ),
    'brktrkr_api must not execute privileged administrator operations'
);

SELECT app.assert_true(
    NOT has_function_privilege(
        'brktrkr_admin',
        'api.admin_finance_operation(text,jsonb,jsonb)',
        'EXECUTE'
    ),
    'Legacy administrator dispatcher must not remain directly executable by runtime roles'
);

\echo '[PASS] 1114_api_v3_execute.sql v1.3.1'
SELECT pg_temp.bt_mark_completed('1100_security/1114_api_v3_execute.sql');
