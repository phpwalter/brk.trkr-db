/*
===============================================================================
 File:           1200_validation/1217_pgbouncer_transaction_context_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Enforce the transaction-local request identity/context contract
                 required by PgBouncer transaction pooling.
 Depends On:     1200_validation/1216_adversarial_authorization_validation.sql
                 app.set_authenticated_user(uuid)
                 app.set_request_context(uuid,text,text)
                 app.set_import_context(uuid)
                 identity.current_user_id()
                 identity.current_user_id_optional()
 Creates:        Validation assertions only
 Key Rules:      Authenticated identity is established only through the canonical
                 setter and only with transaction-local set_config(..., true).
                 Request/trace context is also transaction-local.
                 No role/database default may pre-seed request-scoped GUCs.
                 Rollback restores the prior request context.
                 COMMIT/pool-boundary behavior is additionally tested by
                 tools/verify_pgbouncer_transaction_context.psql.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1217_pgbouncer_transaction_context_validation.sql', ARRAY['1200_validation/1216_adversarial_authorization_validation.sql', 'app.set_authenticated_user(uuid)', 'app.set_request_context(uuid,text,text)', 'app.set_import_context(uuid)', 'identity.current_user_id()', 'identity.current_user_id_optional()']::text[]);

\echo '[VALIDATE] 1217_pgbouncer_transaction_context_validation.sql'

/* The canonical identity setter must be invoker-safe and search-path pinned. */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'app'
           AND p.proname = 'set_authenticated_user'
           AND p.pronargs = 1
           AND p.proargtypes[0] = 'uuid'::regtype
           AND NOT p.prosecdef
           AND EXISTS (
               SELECT 1
                 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                WHERE cfg = 'search_path=pg_catalog'
           )
           AND regexp_replace(p.prosrc, '[[:space:]]', '', 'g')
               LIKE '%pg_catalog.set_config(''app.current_user_id'',p_user_id::text,true)%'
    ),
    'app.set_authenticated_user(uuid) must use transaction-local set_config(..., true) with search_path=pg_catalog'
);

/* Only the canonical setter may write authenticated user context. */
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
    'app.current_user_id may be written only by app.set_authenticated_user(uuid)'
);

/*
 * Request-correlation context has the same pool-safety requirement. The
 * setter must remain transaction-local and may not be converted to session
 * scope by a future refactor.
 */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'app'
           AND p.proname = 'set_request_context'
           AND p.pronargs = 3
           AND p.proargtypes[0] = 'uuid'::regtype
           AND p.proargtypes[1] = 'text'::regtype
           AND p.proargtypes[2] = 'text'::regtype
           AND NOT p.prosecdef
           AND EXISTS (
               SELECT 1
                 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                WHERE cfg = 'search_path=pg_catalog'
           )
           AND regexp_replace(p.prosrc, '[[:space:]]', '', 'g')
               LIKE '%pg_catalog.set_config(''app.request_id'',COALESCE(p_request_id::text,''''),true)%'
           AND regexp_replace(p.prosrc, '[[:space:]]', '', 'g')
               LIKE '%pg_catalog.set_config(''app.trace_id'',COALESCE(p_trace_id,''''),true)%'
           AND regexp_replace(p.prosrc, '[[:space:]]', '', 'g')
               LIKE '%pg_catalog.set_config(''app.actor_class'',p_actor_class,true)%'
    ),
    'app.set_request_context(uuid,text,text) must remain transaction-local and search-path pinned'
);

/* Request/trace IDs may be written only by the canonical request setter. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE (
                p.prosrc ~* 'set_config[[:space:]]*\([[:space:]]*''app\.request_id'''
             OR p.prosrc ~* 'set_config[[:space:]]*\([[:space:]]*''app\.trace_id'''
         )
           AND NOT (
               n.nspname = 'app'
               AND p.proname = 'set_request_context'
               AND p.pronargs = 3
               AND p.proargtypes[0] = 'uuid'::regtype
               AND p.proargtypes[1] = 'text'::regtype
               AND p.proargtypes[2] = 'text'::regtype
           )
    ),
    'Request/trace GUCs may be written only by app.set_request_context(uuid,text,text)'
);

/*
 * actor_class has five approved transaction-local writers:
 * - the canonical request/import context setters; and
 * - the three reviewed admin lifecycle entry points, which set ADMIN only
 *   after admin.assert_system_admin() succeeds and restore the prior value.
 */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE p.prosrc ~* 'set_config[[:space:]]*\([[:space:]]*''app\.actor_class'''
           AND NOT (
                (
                    n.nspname = 'app'
                    AND p.proname = 'set_request_context'
                    AND p.pronargs = 3
                    AND p.proargtypes[0] = 'uuid'::regtype
                    AND p.proargtypes[1] = 'text'::regtype
                    AND p.proargtypes[2] = 'text'::regtype
                )
                OR
                (
                    n.nspname = 'app'
                    AND p.proname = 'set_import_context'
                    AND p.pronargs = 1
                    AND p.proargtypes[0] = 'uuid'::regtype
                )
                OR
                (
                    n.nspname = 'admin'
                    AND p.proname IN (
                        'retire_catalog_item',
                        'archive_catalog_item'
                    )
                    AND p.pronargs = 2
                    AND p.proargtypes[0] = 'uuid'::regtype
                    AND p.proargtypes[1] = 'text'::regtype
                    AND p.prosecdef
                )
                OR
                (
                    n.nspname = 'admin'
                    AND p.proname = 'restore_catalog_item'
                    AND p.pronargs = 3
                    AND p.proargtypes[0] = 'uuid'::regtype
                    AND p.proargtypes[1] = 'text'::regtype
                    AND p.proargtypes[2] = 'text'::regtype
                    AND p.prosecdef
                )
           )
    ),
    'app.actor_class may be written only by approved request/import setters or reviewed admin lifecycle entry points'
);

/* Import source provenance has one approved transaction-local writer. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE p.prosrc ~* 'set_config[[:space:]]*\([[:space:]]*''app\.source_run_id'''
           AND NOT (
               n.nspname = 'app'
               AND p.proname = 'set_import_context'
               AND p.pronargs = 1
               AND p.proargtypes[0] = 'uuid'::regtype
           )
    ),
    'app.source_run_id may be written only by app.set_import_context(uuid)'
);

/* Canonical importer setter must be invoker-safe, pinned, and transaction-local. */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'app'
           AND p.proname = 'set_import_context'
           AND p.pronargs = 1
           AND p.proargtypes[0] = 'uuid'::regtype
           AND NOT p.prosecdef
           AND EXISTS (
               SELECT 1
                 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) cfg
                WHERE cfg = 'search_path=pg_catalog'
           )
           AND p.prosrc LIKE '%app.actor_class%'
           AND p.prosrc LIKE '%app.source_run_id%'
           AND p.prosrc LIKE '%set_config%'
           AND regexp_replace(p.prosrc, '[[:space:]]', '', 'g')
               LIKE '%true)%'
    ),
    'app.set_import_context(uuid) must remain transaction-local and search-path pinned'
);

/*
 * A role/database ALTER ... SET would silently seed pooled sessions and defeat
 * the fail-closed model. Reject any such defaults for request-scoped settings.
 */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_db_role_setting s
          CROSS JOIN LATERAL unnest(coalesce(s.setconfig, ARRAY[]::text[])) cfg
         WHERE split_part(cfg, '=', 1) IN (
             'app.current_user_id',
             'app.request_id',
             'app.trace_id',
             'app.actor_class',
             'app.source_run_id'
         )
    ),
    'Request-scoped GUCs must not be configured as role/database defaults'
);

/* Runtime roles need exactly the canonical context setters, not raw table access. */
SELECT app.assert_true(
    has_function_privilege('lego_api', 'app.set_authenticated_user(uuid)', 'EXECUTE')
    AND has_function_privilege('lego_app', 'app.set_authenticated_user(uuid)', 'EXECUTE')
    AND has_function_privilege('lego_api', 'app.set_request_context(uuid,text,text)', 'EXECUTE')
    AND has_function_privilege('lego_app', 'app.set_request_context(uuid,text,text)', 'EXECUTE'),
    'Runtime roles must be able to establish transaction-local authenticated/request context'
);

/* Importer provenance setter is importer-only. */
SELECT app.assert_true(
    has_function_privilege('lego_importer', 'app.set_import_context(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('lego_api', 'app.set_import_context(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('lego_app', 'app.set_import_context(uuid)', 'EXECUTE'),
    'Only lego_importer may execute app.set_import_context(uuid)'
);

/* PUBLIC must not be able to invoke either context setter. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          CROSS JOIN LATERAL aclexplode(
              coalesce(p.proacl, acldefault('f', p.proowner))
          ) a
         WHERE n.nspname = 'app'
           AND p.proname IN ('set_authenticated_user', 'set_request_context', 'set_import_context')
           AND a.grantee = 0
           AND a.privilege_type = 'EXECUTE'
    ),
    'PUBLIC must not execute request-context setter functions'
);


/* ==========================================================================
 * Behavioral subtransaction checks
 * ==========================================================================
 *
 * The deployment itself is one outer transaction, so COMMIT-boundary behavior
 * cannot be tested here without destroying atomic bootstrap semantics. We can
 * still prove rollback restoration and transaction-local propagation within
 * the current transaction. A separate PgBouncer test exercises real COMMIT and
 * ROLLBACK boundaries after installation.
 */
DO $pgbouncer_contract$
DECLARE
    v_user_a uuid := '00000000-0000-7000-8000-0000000000a1';
    v_user_b uuid := '00000000-0000-7000-8000-0000000000b2';
    v_request_a uuid := '00000000-0000-7000-8000-0000000000c1';
BEGIN
    /* Previous validators must not leave an authenticated actor behind. */
    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'Validation entered with leaked app.current_user_id context'
    );

    /*
     * set_config(..., true) inside a rolled-back subtransaction must restore
     * the previous context rather than leak the temporary actor.
     */
    BEGIN
        PERFORM app.set_authenticated_user(v_user_a);
        PERFORM app.set_request_context(v_request_a, 'pgbouncer-rollback-test', 'USER');

        PERFORM app.assert_true(
            identity.current_user_id() = v_user_a,
            'Authenticated identity was not visible inside transaction scope'
        );

        PERFORM app.assert_true(
            app.current_request_id() = v_request_a
            AND app.current_trace_id() = 'pgbouncer-rollback-test'
            AND app.current_actor_class() = 'USER',
            'Request context was not visible inside transaction scope'
        );

        RAISE EXCEPTION 'intentional transaction-context rollback'
            USING ERRCODE = 'P0198';
    EXCEPTION
        WHEN SQLSTATE 'P0198' THEN
            NULL;
    END;

    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'Authenticated identity leaked after subtransaction rollback'
    );

    PERFORM app.assert_true(
        app.current_request_id() IS NULL
        AND app.current_trace_id() IS NULL
        AND app.current_actor_class() = 'USER',
        'Request context leaked after subtransaction rollback'
    );

    /*
     * A successfully released subtransaction remains part of the surrounding
     * transaction, so its local setting must remain visible until the outer
     * transaction ends or the middleware replaces/clears it.
     */
    BEGIN
        PERFORM app.set_authenticated_user(v_user_a);
    END;

    PERFORM app.assert_true(
        identity.current_user_id() = v_user_a,
        'Transaction-local identity disappeared before transaction end'
    );

    /* Re-establishing context must replace the prior actor deterministically. */
    PERFORM app.set_authenticated_user(v_user_b);

    PERFORM app.assert_true(
        identity.current_user_id() = v_user_b,
        'Re-established transaction identity did not replace prior actor'
    );

    /* Leave the deployment transaction anonymous for later validation. */
    PERFORM pg_catalog.set_config('app.current_user_id', '', true);
    PERFORM pg_catalog.set_config('app.request_id', '', true);
    PERFORM pg_catalog.set_config('app.trace_id', '', true);
    PERFORM pg_catalog.set_config('app.actor_class', '', true);

    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'Transaction-context validator failed to clear its test identity'
    );
END;
$pgbouncer_contract$;

\echo '[PASS] 1217_pgbouncer_transaction_context_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1217_pgbouncer_transaction_context_validation.sql');
