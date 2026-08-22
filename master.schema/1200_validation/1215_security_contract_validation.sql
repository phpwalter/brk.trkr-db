/*
===============================================================================
 File:           1200_validation/1215_security_contract_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Enforce the runtime access-control contract mechanically.
                 Runtime roles are EXECUTE-only, may not own/bypass protected
                 objects, and SECURITY DEFINER routines must be hardened.
 Depends On:     1100_security/1107_grants.sql
                 1100_security/1110_api_surface_lockdown.sql
                 Complete 1000_function domain
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1215_security_contract_validation.sql', ARRAY['1100_security/1107_grants.sql', '1100_security/1110_api_surface_lockdown.sql', 'Complete 1000_function domain']::text[]);

\echo '[VALIDATE] 1215_security_contract_validation.sql'

/* -------------------------------------------------------------------------
 * Contract constants
 * -------------------------------------------------------------------------
 * lego_api is the preferred runtime role.
 * lego_app is retained only as an execute-only compatibility runtime role.
 * Neither role may directly access application tables or sequences.
 * ------------------------------------------------------------------------- */

/* Required runtime roles exist and are structurally incapable of escalation. */
DO $$
DECLARE
    v_role text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['lego_api', 'lego_app']
    LOOP
        PERFORM app.assert_true(
            EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role),
            format('Runtime role "%s" is missing', v_role)
        );

        PERFORM app.assert_true(
            EXISTS (
                SELECT 1
                FROM pg_roles
                WHERE rolname = v_role
                  AND NOT rolcanlogin
                  AND NOT rolsuper
                  AND NOT rolcreaterole
                  AND NOT rolcreatedb
                  AND NOT rolreplication
                  AND NOT rolbypassrls
            ),
            format(
                'Runtime role "%s" must be NOLOGIN, NOSUPERUSER, NOCREATEROLE, '
                'NOCREATEDB, NOREPLICATION, NOBYPASSRLS',
                v_role
            )
        );
    END LOOP;
END;
$$;


/* Runtime roles must never own application relations, routines, schemas, or types. */
DO $$
DECLARE
    v_role text;
    v_owned bigint;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['lego_api', 'lego_app']
    LOOP
        SELECT count(*)
          INTO v_owned
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          JOIN pg_roles r ON r.oid = c.relowner
         WHERE r.rolname = v_role
           AND n.nspname IN (
               'app','identity','reference','catalog','definition','collection',
               'wanted','moc','import','audit','api','admin','marketplace',
               'finance','operations','reporting'
           )
           AND c.relkind IN ('r','p','v','m','S','f');

        PERFORM app.assert_true(
            v_owned = 0,
            format('Runtime role "%s" owns %s application relation(s)', v_role, v_owned)
        );

        SELECT count(*)
          INTO v_owned
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          JOIN pg_roles r ON r.oid = p.proowner
         WHERE r.rolname = v_role
           AND n.nspname IN (
               'app','identity','reference','catalog','definition','collection',
               'wanted','moc','import','audit','api','admin','marketplace',
               'finance','operations','reporting'
           );

        PERFORM app.assert_true(
            v_owned = 0,
            format('Runtime role "%s" owns %s application routine(s)', v_role, v_owned)
        );

        SELECT count(*)
          INTO v_owned
          FROM pg_namespace n
          JOIN pg_roles r ON r.oid = n.nspowner
         WHERE r.rolname = v_role
           AND n.nspname IN (
               'app','identity','reference','catalog','definition','collection',
               'wanted','moc','import','audit','api','admin','marketplace',
               'finance','operations','reporting'
           );

        PERFORM app.assert_true(
            v_owned = 0,
            format('Runtime role "%s" owns %s application schema(s)', v_role, v_owned)
        );
    END LOOP;
END;
$$;


/* Runtime roles must have ZERO effective direct table privileges. */
DO $$
DECLARE
    v_role text;
    v_relation record;
    v_violations text[] := ARRAY[]::text[];
BEGIN
    FOREACH v_role IN ARRAY ARRAY['lego_api', 'lego_app']
    LOOP
        FOR v_relation IN
            SELECT c.oid, n.nspname, c.relname
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind IN ('r','p','v','m','f')
               AND n.nspname IN (
                   'app','identity','reference','catalog','definition','collection',
                   'wanted','moc','import','audit','marketplace','finance',
                   'operations','reporting'
               )
        LOOP
            IF has_table_privilege(
                v_role,
                v_relation.oid,
                'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
            ) THEN
                v_violations := array_append(
                    v_violations,
                    format('%s:%I.%I', v_role, v_relation.nspname, v_relation.relname)
                );
            END IF;
        END LOOP;
    END LOOP;

    PERFORM app.assert_true(
        cardinality(v_violations) = 0,
        format(
            'Runtime roles must be stored-routine-only; direct relation privileges found: %s',
            array_to_string(v_violations, ', ')
        )
    );
END;
$$;


/* Runtime roles must have ZERO effective sequence privileges. */
DO $$
DECLARE
    v_role text;
    v_sequence record;
    v_violations text[] := ARRAY[]::text[];
BEGIN
    FOREACH v_role IN ARRAY ARRAY['lego_api', 'lego_app']
    LOOP
        FOR v_sequence IN
            SELECT c.oid, n.nspname, c.relname
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind = 'S'
               AND n.nspname IN (
                   'app','identity','reference','catalog','definition','collection',
                   'wanted','moc','import','audit','marketplace','finance',
                   'operations','reporting'
               )
        LOOP
            IF has_sequence_privilege(v_role, v_sequence.oid, 'USAGE,SELECT,UPDATE') THEN
                v_violations := array_append(
                    v_violations,
                    format('%s:%I.%I', v_role, v_sequence.nspname, v_sequence.relname)
                );
            END IF;
        END LOOP;
    END LOOP;

    PERFORM app.assert_true(
        cardinality(v_violations) = 0,
        format(
            'Runtime roles must not access sequences directly: %s',
            array_to_string(v_violations, ', ')
        )
    );
END;
$$;


/* Runtime roles may not CREATE in any application schema. */
DO $$
DECLARE
    v_role text;
    v_schema record;
    v_violations text[] := ARRAY[]::text[];
BEGIN
    FOREACH v_role IN ARRAY ARRAY['lego_api', 'lego_app']
    LOOP
        FOR v_schema IN
            SELECT oid, nspname
              FROM pg_namespace
             WHERE nspname IN (
                 'app','identity','reference','catalog','definition','collection',
                 'wanted','moc','import','audit','api','admin','marketplace',
                 'finance','operations','reporting'
             )
        LOOP
            IF has_schema_privilege(v_role, v_schema.oid, 'CREATE') THEN
                v_violations := array_append(
                    v_violations,
                    format('%s:%I', v_role, v_schema.nspname)
                );
            END IF;
        END LOOP;
    END LOOP;

    PERFORM app.assert_true(
        cardinality(v_violations) = 0,
        format(
            'Runtime roles unexpectedly have schema CREATE: %s',
            array_to_string(v_violations, ', ')
        )
    );
END;
$$;


/* Runtime callable-surface membership is validated against the canonical
 * app.runtime_api_allowlist by 1218_api_surface_validation.sql. */


/* Every runtime API routine must be SECURITY DEFINER with a pinned search_path. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'api'
           AND (
               has_function_privilege('lego_api', p.oid, 'EXECUTE')
               OR has_function_privilege('lego_app', p.oid, 'EXECUTE')
           )
           AND (
               NOT p.prosecdef
               OR NOT EXISTS (
                   SELECT 1
                     FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                    WHERE split_part(cfg, '=', 1) = 'search_path'
                      AND (
                          split_part(cfg, '=', 2) = 'pg_catalog'
                          OR split_part(cfg, '=', 2) LIKE 'pg_catalog,%'
                      )
               )
           )
    ),
    'Every runtime api.* routine must be SECURITY DEFINER with search_path beginning pg_catalog'
);


/* No SECURITY DEFINER routine in application schemas may be executable by PUBLIC. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          CROSS JOIN LATERAL aclexplode(
              coalesce(p.proacl, acldefault('f', p.proowner))
          ) acl
         WHERE p.prosecdef
           AND n.nspname IN (
               'app','identity','reference','catalog','definition','collection',
               'wanted','moc','import','audit','api','admin','marketplace',
               'finance','operations','reporting'
           )
           AND acl.grantee = 0
           AND acl.privilege_type = 'EXECUTE'
    ),
    'A SECURITY DEFINER routine is executable by PUBLIC'
);


/* Every SECURITY DEFINER routine must pin search_path with pg_catalog first. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE p.prosecdef
           AND n.nspname IN (
               'app','identity','reference','catalog','definition','collection',
               'wanted','moc','import','audit','api','admin','marketplace',
               'finance','operations','reporting'
           )
           AND NOT EXISTS (
               SELECT 1
                 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                WHERE split_part(cfg, '=', 1) = 'search_path'
                  AND (
                      split_part(cfg, '=', 2) = 'pg_catalog'
                      OR split_part(cfg, '=', 2) LIKE 'pg_catalog,%'
                  )
           )
    ),
    'A SECURITY DEFINER routine lacks a pinned search_path beginning with pg_catalog'
);


/* Runtime roles must not inherit elevated administrator/importer/reporting roles. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_auth_members m
          JOIN pg_roles child_role ON child_role.oid = m.member
          JOIN pg_roles parent_role ON parent_role.oid = m.roleid
         WHERE child_role.rolname IN ('lego_api','lego_app')
           AND parent_role.rolname IN ('lego_admin','lego_importer','lego_reporting')
    ),
    'Runtime role inherits an elevated admin/importer/reporting role'
);


/* Admin remains separate from the normal runtime role. */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_roles
         WHERE rolname = 'lego_admin'
           AND NOT rolcanlogin
           AND rolbypassrls
    ),
    'lego_admin must remain a separate NOLOGIN BYPASSRLS group role'
);


/* ==========================================================================
 * Authenticated caller identity contract
 * ==========================================================================
 * Reads and writes are deliberately separated:
 *   - only identity.current_user_id[_optional]() may READ the identity GUC;
 *   - only app.set_authenticated_user(uuid) may WRITE the identity GUC.
 *
 * This makes the request-identity boundary mechanically reviewable while still
 * allowing trusted middleware to establish transaction-local identity through
 * one canonical routine.
 */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE p.prosrc ~* 'current_setting[[:space:]]*\([[:space:]]*''app\.current_user_id'''
           AND NOT (
               n.nspname = 'identity'
               AND p.proname IN ('current_user_id', 'current_user_id_optional')
           )
    ),
    'A database routine reads app.current_user_id outside the canonical identity helpers'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE p.prosrc ~* 'set_config[[:space:]]*\([[:space:]]*''app\.current_user_id'''
           AND NOT (
               n.nspname = 'app'
               AND p.proname = 'set_authenticated_user'
               AND p.pronargs = 1
               AND p.proargtypes[0] = 'uuid'::regtype
           )
    ),
    'A database routine writes app.current_user_id outside app.set_authenticated_user(uuid)'
);


/* Required identity helper must be fail-closed and have a pinned search_path. */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'identity'
           AND p.proname = 'current_user_id'
           AND p.prorettype = 'uuid'::regtype
           AND EXISTS (
               SELECT 1
                 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                WHERE cfg = 'search_path=pg_catalog'
           )
    ),
    'identity.current_user_id() must exist, return uuid, and pin search_path=pg_catalog'
);


/* Anonymous-safe identity is a deliberately narrow exception. */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'identity'
           AND p.proname = 'current_user_id_optional'
           AND p.prorettype = 'uuid'::regtype
           AND EXISTS (
               SELECT 1
                 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                WHERE cfg = 'search_path=pg_catalog'
           )
    ),
    'identity.current_user_id_optional() must exist, return uuid, and pin search_path=pg_catalog'
);


/* Prove behavior, not just catalog shape. */
DO $$
DECLARE
    v_test_user uuid := '00000000-0000-4000-8000-000000000001'::uuid;
    v_actual uuid;
    v_failed_closed boolean := false;
BEGIN
    /* Missing required identity must fail with SQLSTATE 28000. */
    PERFORM set_config('app.current_user_id', '', true);
    BEGIN
        PERFORM identity.current_user_id();
    EXCEPTION
        WHEN SQLSTATE '28000' THEN
            v_failed_closed := true;
    END;

    PERFORM app.assert_true(
        v_failed_closed,
        'identity.current_user_id() did not fail closed when context was missing'
    );

    /* Malformed required identity must also fail closed. */
    v_failed_closed := false;
    PERFORM set_config('app.current_user_id', 'not-a-uuid', true);
    BEGIN
        PERFORM identity.current_user_id();
    EXCEPTION
        WHEN SQLSTATE '28000' THEN
            v_failed_closed := true;
    END;

    PERFORM app.assert_true(
        v_failed_closed,
        'identity.current_user_id() did not fail closed when context was malformed'
    );

    /* Valid identity must round-trip exactly. */
    PERFORM set_config('app.current_user_id', v_test_user::text, true);
    v_actual := identity.current_user_id();

    PERFORM app.assert_true(
        v_actual = v_test_user,
        'identity.current_user_id() did not return the established authenticated identity'
    );

    /* Anonymous-safe helper may return NULL only when context is absent. */
    PERFORM set_config('app.current_user_id', '', true);
    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'identity.current_user_id_optional() must return NULL when context is absent'
    );

    /* But malformed context is still a security error, never anonymous. */
    v_failed_closed := false;
    PERFORM set_config('app.current_user_id', 'not-a-uuid', true);
    BEGIN
        PERFORM identity.current_user_id_optional();
    EXCEPTION
        WHEN SQLSTATE '28000' THEN
            v_failed_closed := true;
    END;

    PERFORM app.assert_true(
        v_failed_closed,
        'identity.current_user_id_optional() accepted malformed identity context'
    );

    /* Leave no identity context behind in the validation transaction. */
    PERFORM set_config('app.current_user_id', '', true);
END;
$$;


/* Anonymous-safe identity may only be consumed by reviewed public/unlisted MOC
 * read helpers. Any expansion of this list is a security-contract change.
 */
DO $$
DECLARE
    v_allowed text[] := ARRAY[
        'api.get_moc_by_id(uuid)',
        'api.get_moc_revisions(uuid)',
        'api.get_moc_assets(uuid,uuid)',
        'api.get_moc_licenses(uuid,uuid)',
        'api.get_moc_subassemblies(uuid,uuid)'
    ];
    v_proc record;
BEGIN
    FOR v_proc IN
        SELECT p.oid::regprocedure::text AS signature
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE p.prosrc LIKE '%current_user_id_optional%'
           AND NOT (
               n.nspname = 'identity'
               AND p.proname = 'current_user_id_optional'
           )
    LOOP
        PERFORM app.assert_true(
            v_proc.signature = ANY(v_allowed),
            format(
                'Anonymous-safe identity helper used by unapproved routine: %s',
                v_proc.signature
            )
        );
    END LOOP;
END;
$$;


/* Runtime API routines must never accept a caller/authenticated identity
 * argument. Caller identity comes only from transaction context. Target-user
 * parameters remain allowed when they represent the object of an operation.
 */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'api'
           AND (
               has_function_privilege('lego_api', p.oid, 'EXECUTE')
               OR has_function_privilege('lego_app', p.oid, 'EXECUTE')
           )
           AND EXISTS (
               SELECT 1
                 FROM unnest(coalesce(p.proargnames, ARRAY[]::text[])) arg_name
                WHERE lower(arg_name) IN (
                    'p_actor_user_id',
                    'p_caller_user_id',
                    'p_authenticated_user_id',
                    'actor_user_id',
                    'caller_user_id',
                    'authenticated_user_id'
                )
           )
    ),
    'A runtime API routine accepts caller identity as an argument instead of trusted transaction context'
);



/* UUID generation must be independent of caller search_path. pgcrypto is pinned
 * to public and app.uuid_v7() must itself pin search_path to pg_catalog while
 * schema-qualifying the extension function.
 */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_extension e
          JOIN pg_namespace n ON n.oid = e.extnamespace
         WHERE e.extname = 'pgcrypto'
           AND n.nspname = 'public'
    ),
    'pgcrypto must be installed in schema public for deterministic UUID generation'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'app'
           AND p.proname = 'uuid_v7'
           AND pg_get_function_identity_arguments(p.oid) = ''
           AND EXISTS (
               SELECT 1
                 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                WHERE cfg = 'search_path=pg_catalog'
           )
           AND pg_get_functiondef(p.oid) LIKE '%public.gen_random_bytes(10)%'
    ),
    'app.uuid_v7() must pin search_path=pg_catalog and schema-qualify public.gen_random_bytes()'
);

\echo '[VALIDATE PASS] 1215_security_contract_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1215_security_contract_validation.sql');
