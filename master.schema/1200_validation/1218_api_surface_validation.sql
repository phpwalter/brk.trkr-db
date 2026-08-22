/*
===============================================================================
 File:           1200_validation/1218_api_surface_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Prove the runtime api.* surface exactly matches the canonical
                 allowlist and remains deny-by-default for future routines.
 Depends On:     1100_security/1110_api_surface_lockdown.sql
                 1200_validation/1217_pgbouncer_transaction_context_validation.sql
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1218_api_surface_validation.sql', ARRAY['1100_security/1110_api_surface_lockdown.sql', '1200_validation/1217_pgbouncer_transaction_context_validation.sql']::text[]);

/* Canonical allowlist exists and is private from runtime roles. */
SELECT app.assert_true(
    to_regclass('app.runtime_api_allowlist') IS NOT NULL,
    'app.runtime_api_allowlist is missing'
);

SELECT app.assert_true(
    NOT has_table_privilege('lego_api', 'app.runtime_api_allowlist', 'SELECT')
    AND NOT has_table_privilege('lego_api', 'app.runtime_api_allowlist', 'INSERT')
    AND NOT has_table_privilege('lego_api', 'app.runtime_api_allowlist', 'UPDATE')
    AND NOT has_table_privilege('lego_api', 'app.runtime_api_allowlist', 'DELETE')
    AND NOT has_table_privilege('lego_app', 'app.runtime_api_allowlist', 'SELECT')
    AND NOT has_table_privilege('lego_app', 'app.runtime_api_allowlist', 'INSERT')
    AND NOT has_table_privilege('lego_app', 'app.runtime_api_allowlist', 'UPDATE')
    AND NOT has_table_privilege('lego_app', 'app.runtime_api_allowlist', 'DELETE'),
    'Runtime roles must not read or mutate app.runtime_api_allowlist'
);

/* Runtime roles may resolve api.* names, but may never CREATE there. */
SELECT app.assert_true(
    has_schema_privilege('lego_api', 'api', 'USAGE')
    AND has_schema_privilege('lego_app', 'api', 'USAGE')
    AND NOT has_schema_privilege('lego_api', 'api', 'CREATE')
    AND NOT has_schema_privilege('lego_app', 'api', 'CREATE'),
    'Runtime roles require api USAGE and must not have api CREATE'
);

/* Every allowlisted signature must resolve to exactly one installed routine. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM app.runtime_api_allowlist a
        WHERE to_regprocedure(a.routine_signature) IS NULL
    ),
    'One or more runtime API allowlist signatures do not resolve'
);

/* PUBLIC may execute no api.* routine, regardless of SECURITY DEFINER status. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN LATERAL aclexplode(
            coalesce(p.proacl, acldefault('f', p.proowner))
        ) acl
        WHERE n.nspname = 'api'
          AND acl.grantee = 0
          AND acl.privilege_type = 'EXECUTE'
    ),
    'PUBLIC can execute an api.* routine'
);

/*
 * Exact-set assertion:
 *   actual runtime-executable api.* routines == canonical allowlist
 */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT p.oid::regprocedure::text AS signature
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api'
          AND (
              has_function_privilege('lego_api', p.oid, 'EXECUTE')
              OR has_function_privilege('lego_app', p.oid, 'EXECUTE')
          )
        EXCEPT
        SELECT routine_signature
        FROM app.runtime_api_allowlist
    ),
    'A runtime role can execute an api.* routine not present in the canonical allowlist'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT routine_signature
        FROM app.runtime_api_allowlist
        EXCEPT
        SELECT p.oid::regprocedure::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api'
          AND has_function_privilege('lego_api', p.oid, 'EXECUTE')
          AND has_function_privilege('lego_app', p.oid, 'EXECUTE')
    ),
    'An allowlisted api.* routine is not executable by both runtime roles'
);

/* Runtime routines are privilege-elevating security boundaries: pin them. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM app.runtime_api_allowlist a
        JOIN pg_proc p ON p.oid = to_regprocedure(a.routine_signature)
        JOIN pg_roles owner_role ON owner_role.oid = p.proowner
        WHERE NOT p.prosecdef
           OR owner_role.rolname IN ('lego_api', 'lego_app')
           OR NOT EXISTS (
                SELECT 1
                FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                WHERE split_part(cfg, '=', 1) = 'search_path'
                  AND split_part(cfg, '=', 2) ~ '^[[:space:]]*pg_catalog([[:space:]]*,|[[:space:]]*$)'
           )
    ),
    'Every allowlisted api.* routine must be SECURITY DEFINER, non-runtime-owned, with pg_catalog first in search_path'
);

/*
 * Every role that owns an api.* routine must have a GLOBAL routine default ACL
 * that removes PUBLIC EXECUTE.  A schema-local REVOKE is insufficient because
 * PostgreSQL's built-in PUBLIC EXECUTE default is global.
 */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT DISTINCT p.proowner
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api'
          AND NOT EXISTS (
              SELECT 1
              FROM pg_default_acl d
              WHERE d.defaclrole = p.proowner
                AND d.defaclnamespace = 0
                AND d.defaclobjtype = 'f'
          )
    ),
    'An api.* routine owner lacks an explicit global default routine ACL'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT DISTINCT p.proowner
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api'
          AND EXISTS (
              SELECT 1
              FROM pg_default_acl d
              CROSS JOIN LATERAL aclexplode(d.defaclacl) acl
              WHERE d.defaclrole = p.proowner
                AND d.defaclnamespace = 0
                AND d.defaclobjtype = 'f'
                AND acl.grantee = 0
                AND acl.privilege_type = 'EXECUTE'
          )
    ),
    'An api.* routine owner would grant PUBLIC EXECUTE to future routines'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT DISTINCT p.proowner
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api'
          AND EXISTS (
              SELECT 1
              FROM pg_default_acl d
              CROSS JOIN LATERAL aclexplode(d.defaclacl) acl
              JOIN pg_roles grantee_role ON grantee_role.oid = acl.grantee
              WHERE d.defaclrole = p.proowner
                AND d.defaclnamespace = 0
                AND d.defaclobjtype = 'f'
                AND grantee_role.rolname IN ('lego_api', 'lego_app')
                AND acl.privilege_type = 'EXECUTE'
          )
    ),
    'An api.* routine owner would grant runtime EXECUTE to future routines by default'
);


/*
 * Defense against future accidental broad-grant changes: the installed set
 * must remain exact even if someone edits a grant script.
 */
DO $api_surface_behavior$
DECLARE
    v_signature text;
BEGIN
    FOR v_signature IN
        SELECT routine_signature
        FROM app.runtime_api_allowlist
    LOOP
        PERFORM app.assert_true(
            has_function_privilege(
                'lego_api',
                to_regprocedure(v_signature),
                'EXECUTE'
            ),
            format('lego_api lacks reviewed routine %s', v_signature)
        );
        PERFORM app.assert_true(
            has_function_privilege(
                'lego_app',
                to_regprocedure(v_signature),
                'EXECUTE'
            ),
            format('lego_app lacks reviewed routine %s', v_signature)
        );
    END LOOP;
END
$api_surface_behavior$;

\echo '[PASS] 1218_api_surface_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1218_api_surface_validation.sql');
