\set ON_ERROR_STOP on

/*
===============================================================================
 File:           1200_validation/1217_pgbouncer_transaction_context_validation.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Installed-catalog validation for the canonical transaction-
                 local request-context contract used with PgBouncer transaction
                 pooling.
 Depends On:     5000_function/5700_system/5709_system_request_context.sql
 Creates:        Validation assertions only
===============================================================================
*/

SELECT pg_temp.bt_preflight('1200_validation/1217_pgbouncer_transaction_context_validation.sql', ARRAY['5000_function/5700_system/5709_system_request_context.sql']::text[]);

\echo '[VALIDATE] 1217_pgbouncer_transaction_context_validation.sql'

DO $validation$
DECLARE
    v_count integer;
    v_owner text;
    v_src text;
    v_config text[];
BEGIN
    /* Canonical setter: exact signature, SECURITY DEFINER, owner, search path. */
    SELECT
        pg_catalog.pg_get_userbyid(p.proowner),
        p.prosrc,
        COALESCE(p.proconfig, ARRAY[]::text[])
    INTO v_owner, v_src, v_config
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'app'
      AND p.proname = 'set_request_context'
      AND pg_catalog.pg_get_function_identity_arguments(p.oid) =
          'p_user_id uuid, p_request_id uuid, p_trace_id text, p_actor_class text'
      AND p.prosecdef;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Canonical SECURITY DEFINER app.set_request_context(uuid,uuid,text,text) is missing'
            USING ERRCODE = 'P0001';
    END IF;

    IF v_owner <> 'brktrkr_owner' THEN
        RAISE EXCEPTION
            'app.set_request_context owner must be brktrkr_owner; found %',
            v_owner
            USING ERRCODE = 'P0001';
    END IF;

    IF NOT ('search_path=pg_catalog' = ANY(v_config)) THEN
        RAISE EXCEPTION
            'app.set_request_context must pin search_path=pg_catalog'
            USING ERRCODE = 'P0001';
    END IF;

    /*
     * Catalog-source inspection is intentionally redundant with the static
     * verifier. Deployment validation must still fail if the installed
     * function no longer contains the four canonical transaction-local keys.
     */
    IF v_src NOT LIKE '%app.current_user_id%'
       OR v_src NOT LIKE '%app.request_id%'
       OR v_src NOT LIKE '%app.trace_id%'
       OR v_src NOT LIKE '%app.actor_class%'
       OR v_src NOT LIKE '%set_config%' THEN
        RAISE EXCEPTION
            'app.set_request_context does not contain the canonical context writer contract'
            USING ERRCODE = 'P0001';
    END IF;

    /* Clearer must be invoker-safe and owner-controlled. */
    SELECT pg_catalog.count(*)
    INTO v_count
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'app'
      AND p.proname = 'clear_request_context'
      AND p.pronargs = 0
      AND NOT p.prosecdef
      AND pg_catalog.pg_get_userbyid(p.proowner) = 'brktrkr_owner'
      AND EXISTS (
          SELECT 1
          FROM pg_catalog.unnest(COALESCE(p.proconfig, ARRAY[]::text[])) AS cfg
          WHERE cfg = 'search_path=pg_catalog'
      );

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'app.clear_request_context() must be SECURITY INVOKER, owned by brktrkr_owner, search_path=pg_catalog'
            USING ERRCODE = 'P0001';
    END IF;

    /* Typed observational getters and strict getter must all exist. */
    SELECT pg_catalog.count(*)
    INTO v_count
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n
      ON n.oid = p.pronamespace
    WHERE (
            (n.nspname = 'identity' AND p.proname IN ('current_user_id', 'require_current_user_id'))
         OR (n.nspname = 'app' AND p.proname IN ('current_request_id', 'current_trace_id', 'current_actor_class'))
    )
      AND p.pronargs = 0
      AND pg_catalog.pg_get_userbyid(p.proowner) = 'brktrkr_owner';

    IF v_count <> 5 THEN
        RAISE EXCEPTION
            'Expected five canonical request-context getter/enforcement functions; found %',
            v_count
            USING ERRCODE = 'P0001';
    END IF;

    /* PUBLIC must never execute the two context mutators. */
    IF pg_catalog.has_function_privilege(
            'public',
            'app.set_request_context(uuid,uuid,text,text)',
            'EXECUTE'
       ) THEN
        RAISE EXCEPTION
            'PUBLIC must not execute app.set_request_context(uuid,uuid,text,text)'
            USING ERRCODE = 'P0001';
    END IF;

    IF pg_catalog.has_function_privilege(
            'public',
            'app.clear_request_context()',
            'EXECUTE'
       ) THEN
        RAISE EXCEPTION
            'PUBLIC must not execute app.clear_request_context()'
            USING ERRCODE = 'P0001';
    END IF;

    /* Capability roles require the mutators. */
    IF NOT pg_catalog.has_function_privilege(
            'brktrkr_api',
            'app.set_request_context(uuid,uuid,text,text)',
            'EXECUTE'
       )
       OR NOT pg_catalog.has_function_privilege(
            'brktrkr_admin',
            'app.set_request_context(uuid,uuid,text,text)',
            'EXECUTE'
       )
       OR NOT pg_catalog.has_function_privilege(
            'brktrkr_import',
            'app.set_request_context(uuid,uuid,text,text)',
            'EXECUTE'
       )
       OR NOT pg_catalog.has_function_privilege(
            'brktrkr_migrator',
            'app.set_request_context(uuid,uuid,text,text)',
            'EXECUTE'
       ) THEN
        RAISE EXCEPTION
            'BrickTrackr capability roles are missing request-context setter EXECUTE'
            USING ERRCODE = 'P0001';
    END IF;

    /* No role/database default may pre-seed request-scoped context. */
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_db_role_setting AS s
        CROSS JOIN LATERAL pg_catalog.unnest(
            COALESCE(s.setconfig, ARRAY[]::text[])
        ) AS cfg
        WHERE pg_catalog.split_part(cfg, '=', 1) IN (
            'app.current_user_id',
            'app.request_id',
            'app.trace_id',
            'app.actor_class'
        )
    ) THEN
        RAISE EXCEPTION
            'Request-scoped app.* GUCs must not be configured as role/database defaults'
            USING ERRCODE = 'P0001';
    END IF;

    /* Observational getter ACL is intentionally PUBLIC. */
    IF NOT pg_catalog.has_function_privilege(
            'public',
            'identity.current_user_id()',
            'EXECUTE'
       )
       OR NOT pg_catalog.has_function_privilege(
            'public',
            'app.current_request_id()',
            'EXECUTE'
       )
       OR NOT pg_catalog.has_function_privilege(
            'public',
            'app.current_trace_id()',
            'EXECUTE'
       )
       OR NOT pg_catalog.has_function_privilege(
            'public',
            'app.current_actor_class()',
            'EXECUTE'
       ) THEN
        RAISE EXCEPTION
            'Observational request-context getters must remain PUBLIC for RLS evaluation'
            USING ERRCODE = 'P0001';
    END IF;

    IF pg_catalog.has_function_privilege(
            'public',
            'identity.require_current_user_id()',
            'EXECUTE'
       ) THEN
        RAISE EXCEPTION
            'PUBLIC must not execute identity.require_current_user_id()'
            USING ERRCODE = 'P0001';
    END IF;
END;
$validation$;

\echo '[PASS] 1217_pgbouncer_transaction_context_validation.sql'

SELECT pg_temp.bt_mark_completed('1200_validation/1217_pgbouncer_transaction_context_validation.sql');
