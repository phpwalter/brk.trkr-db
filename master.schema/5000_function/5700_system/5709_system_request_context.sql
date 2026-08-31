\set ON_ERROR_STOP on

/*
===============================================================================
 File:           5000_function/5700_system/5709_system_request_context.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Hardened canonical transaction-local request-context transport
                 for pooled runtime connections.
 Depends On:     0000_bootstrap/0001_schemas.sql
                 0100_identity/0100_users.sql
                 1100_security/1100_roles.sql
 Creates:        app.set_request_context(uuid,uuid,text,text)
                 app.clear_request_context()
                 identity.current_user_id()
                 identity.require_current_user_id()
                 app.current_request_id()
                 app.current_trace_id()
                 app.current_actor_class()
===============================================================================
*/

SELECT pg_temp.bt_preflight('5000_function/5700_system/5709_system_request_context.sql', ARRAY['0000_bootstrap/0001_schemas.sql', '0100_identity/0100_users.sql', '1100_security/1100_roles.sql']::text[]);

-- =============================================================================
-- 1. Canonical transaction-local context setter
-- =============================================================================

CREATE OR REPLACE FUNCTION app.set_request_context(
    p_user_id     UUID,
    p_request_id  UUID,
    p_trace_id    TEXT,
    p_actor_class TEXT DEFAULT 'USER'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_actor_class TEXT;
    v_trace_id    TEXT;
    v_target_user UUID;
    v_user_exists BOOLEAN;
BEGIN
    v_actor_class :=
        pg_catalog.upper(
            pg_catalog.btrim(
                COALESCE(p_actor_class, '')
            )
        );

    IF v_actor_class NOT IN ('USER', 'ADMIN', 'IMPORTER', 'SYSTEM') THEN
        RAISE EXCEPTION
            'Invalid actor_class: %. Must be USER, ADMIN, IMPORTER, or SYSTEM',
            p_actor_class
            USING ERRCODE = '22023';
    END IF;

    /*
     * Actor-class authority matrix.
     *
     * SESSION_USER is deliberate. CURRENT_USER changes to the function owner
     * inside SECURITY DEFINER execution and therefore must not be used for
     * caller authorization.
     *
     * brktrkr_owner is NOT a universal fallback. In particular, transitive
     * membership from brktrkr_migrator -> brktrkr_owner must not allow a
     * migrator session to claim USER, ADMIN, or IMPORTER actor classes.
     */
    IF v_actor_class = 'USER' THEN
        IF NOT pg_catalog.pg_has_role(
            SESSION_USER,
            'brktrkr_api',
            'MEMBER'
        ) THEN
            RAISE EXCEPTION
                'Session user % lacks brktrkr_api authority for USER actor class',
                SESSION_USER
                USING ERRCODE = '42501';
        END IF;

        IF p_user_id IS NULL THEN
            RAISE EXCEPTION
                'p_user_id is mandatory when actor_class is USER'
                USING ERRCODE = '22004';
        END IF;

        /*
         * The trusted API authenticates the end user before this function is
         * called. This lookup verifies only that the asserted BrickTrackr
         * identity exists; account-state authorization remains the
         * responsibility of higher-level API procedures.
         *
         * Because this function is SECURITY DEFINER and brktrkr_owner is
         * NOBYPASSRLS, the identity.users owner policy must permit this lookup.
         * The transaction-context validation suite verifies that assumption.
         */
        SELECT EXISTS (
            SELECT 1
            FROM identity.users AS u
            WHERE u.user_id = p_user_id
        )
        INTO v_user_exists;

        IF NOT v_user_exists THEN
            RAISE EXCEPTION
                'User identity % does not exist',
                p_user_id
                USING ERRCODE = '23503';
        END IF;

        v_target_user := p_user_id;

    ELSIF v_actor_class = 'ADMIN' THEN
        IF NOT pg_catalog.pg_has_role(
            SESSION_USER,
            'brktrkr_admin',
            'MEMBER'
        ) THEN
            RAISE EXCEPTION
                'Session user % lacks brktrkr_admin authority for ADMIN actor class',
                SESSION_USER
                USING ERRCODE = '42501';
        END IF;

        IF p_user_id IS NOT NULL THEN
            RAISE EXCEPTION
                'p_user_id must be NULL for ADMIN actor class'
                USING ERRCODE = '22023';
        END IF;

        v_target_user := NULL;

    ELSIF v_actor_class = 'IMPORTER' THEN
        IF NOT pg_catalog.pg_has_role(
            SESSION_USER,
            'brktrkr_import',
            'MEMBER'
        ) THEN
            RAISE EXCEPTION
                'Session user % lacks brktrkr_import authority for IMPORTER actor class',
                SESSION_USER
                USING ERRCODE = '42501';
        END IF;

        IF p_user_id IS NOT NULL THEN
            RAISE EXCEPTION
                'p_user_id must be NULL for IMPORTER actor class'
                USING ERRCODE = '22023';
        END IF;

        v_target_user := NULL;

    ELSIF v_actor_class = 'SYSTEM' THEN
        IF NOT (
            pg_catalog.pg_has_role(
                SESSION_USER,
                'brktrkr_migrator',
                'MEMBER'
            )
            OR
            pg_catalog.pg_has_role(
                SESSION_USER,
                'brktrkr_owner',
                'MEMBER'
            )
        ) THEN
            RAISE EXCEPTION
                'Session user % lacks brktrkr_migrator or brktrkr_owner authority for SYSTEM actor class',
                SESSION_USER
                USING ERRCODE = '42501';
        END IF;

        IF p_user_id IS NOT NULL THEN
            RAISE EXCEPTION
                'p_user_id must be NULL for SYSTEM actor class'
                USING ERRCODE = '22023';
        END IF;

        v_target_user := NULL;
    END IF;

    IF p_request_id IS NULL THEN
        RAISE EXCEPTION
            'p_request_id cannot be null'
            USING ERRCODE = '22004';
    END IF;

    /*
     * trace_id is optional. When supplied it must:
     *   - contain at least one non-whitespace character,
     *   - contain no more than 128 PostgreSQL characters,
     *   - contain no POSIX control characters.
     *
     * The original trace identifier is preserved exactly; trimming is used
     * only for blank-value validation.
     */
    IF p_trace_id IS NOT NULL THEN
        v_trace_id := p_trace_id;

        IF pg_catalog.length(
            pg_catalog.btrim(v_trace_id)
        ) = 0 THEN
            RAISE EXCEPTION
                'p_trace_id cannot be empty or whitespace-only'
                USING ERRCODE = '22023';
        END IF;

        IF pg_catalog.length(v_trace_id) > 128 THEN
            RAISE EXCEPTION
                'p_trace_id exceeds maximum length of 128 characters'
                USING ERRCODE = '22001';
        END IF;

        IF v_trace_id ~ '[[:cntrl:]]' THEN
            RAISE EXCEPTION
                'p_trace_id contains prohibited control characters'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    /*
     * All validation is complete before the first context mutation.
     * The third argument is hard-coded TRUE, so all app.* values are local to
     * the current transaction and disappear at COMMIT/ROLLBACK.
     */
    PERFORM pg_catalog.set_config(
        'app.current_user_id',
        COALESCE(v_target_user::TEXT, ''),
        TRUE
    );

    PERFORM pg_catalog.set_config(
        'app.request_id',
        p_request_id::TEXT,
        TRUE
    );

    PERFORM pg_catalog.set_config(
        'app.trace_id',
        COALESCE(v_trace_id, ''),
        TRUE
    );

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        v_actor_class,
        TRUE
    );
END;
$function$;

-- Remove default PUBLIC execution immediately.
REVOKE ALL
ON FUNCTION app.set_request_context(UUID, UUID, TEXT, TEXT)
FROM PUBLIC;

ALTER FUNCTION app.set_request_context(UUID, UUID, TEXT, TEXT)
OWNER TO brktrkr_owner;

COMMENT ON FUNCTION app.set_request_context(UUID, UUID, TEXT, TEXT)
IS
'Canonical transaction-local BrickTrackr request-context setter. Authentication occurs upstream. USER/ADMIN/IMPORTER/SYSTEM actor classes are constrained to their corresponding database capability roles, and all app.* context is written with transaction-local set_config(..., true) semantics.';

-- =============================================================================
-- 2. Explicit transaction-local context clearer
-- =============================================================================

CREATE OR REPLACE FUNCTION app.clear_request_context()
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
BEGIN
    PERFORM pg_catalog.set_config(
        'app.current_user_id',
        '',
        TRUE
    );

    PERFORM pg_catalog.set_config(
        'app.request_id',
        '',
        TRUE
    );

    PERFORM pg_catalog.set_config(
        'app.trace_id',
        '',
        TRUE
    );

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        '',
        TRUE
    );
END;
$function$;

REVOKE ALL
ON FUNCTION app.clear_request_context()
FROM PUBLIC;

ALTER FUNCTION app.clear_request_context()
OWNER TO brktrkr_owner;

COMMENT ON FUNCTION app.clear_request_context()
IS
'Idempotently clears BrickTrackr transaction-local request context without affecting unrelated PostgreSQL settings.';

-- =============================================================================
-- 3. Observational getters
-- =============================================================================

CREATE OR REPLACE FUNCTION identity.current_user_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
    SELECT NULLIF(
        pg_catalog.current_setting(
            'app.current_user_id',
            TRUE
        ),
        ''
    )::UUID;
$function$;

ALTER FUNCTION identity.current_user_id()
OWNER TO brktrkr_owner;

COMMENT ON FUNCTION identity.current_user_id()
IS
'Returns the transaction-local BrickTrackr user UUID, or NULL when no user context is established.';

CREATE OR REPLACE FUNCTION app.current_request_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
    SELECT NULLIF(
        pg_catalog.current_setting(
            'app.request_id',
            TRUE
        ),
        ''
    )::UUID;
$function$;

ALTER FUNCTION app.current_request_id()
OWNER TO brktrkr_owner;

COMMENT ON FUNCTION app.current_request_id()
IS
'Returns the transaction-local BrickTrackr request UUID, or NULL when no request context is established.';

CREATE OR REPLACE FUNCTION app.current_trace_id()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
    SELECT NULLIF(
        pg_catalog.current_setting(
            'app.trace_id',
            TRUE
        ),
        ''
    );
$function$;

ALTER FUNCTION app.current_trace_id()
OWNER TO brktrkr_owner;

COMMENT ON FUNCTION app.current_trace_id()
IS
'Returns the transaction-local BrickTrackr trace identifier, or NULL when no trace context is established.';

CREATE OR REPLACE FUNCTION app.current_actor_class()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
    SELECT NULLIF(
        pg_catalog.current_setting(
            'app.actor_class',
            TRUE
        ),
        ''
    );
$function$;

ALTER FUNCTION app.current_actor_class()
OWNER TO brktrkr_owner;

COMMENT ON FUNCTION app.current_actor_class()
IS
'Returns the transaction-local BrickTrackr actor class (USER, ADMIN, IMPORTER, SYSTEM), or NULL when no actor context is established.';

-- =============================================================================
-- 4. Strict user-context enforcement helper
-- =============================================================================

CREATE OR REPLACE FUNCTION identity.require_current_user_id()
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_user_id UUID;
BEGIN
    v_user_id := identity.current_user_id();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION
            'Required user identity context is absent'
            USING ERRCODE = '22004';
    END IF;

    RETURN v_user_id;
END;
$function$;

ALTER FUNCTION identity.require_current_user_id()
OWNER TO brktrkr_owner;

COMMENT ON FUNCTION identity.require_current_user_id()
IS
'Returns the current BrickTrackr user UUID and raises SQLSTATE 22004 when transaction-local user context is absent.';

-- =============================================================================
-- 5. Deterministic execution privileges
-- =============================================================================

REVOKE ALL
ON FUNCTION app.set_request_context(UUID, UUID, TEXT, TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION app.clear_request_context()
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION app.set_request_context(UUID, UUID, TEXT, TEXT)
TO
    brktrkr_api,
    brktrkr_admin,
    brktrkr_import,
    brktrkr_migrator,
    brktrkr_owner;

GRANT EXECUTE
ON FUNCTION app.clear_request_context()
TO
    brktrkr_api,
    brktrkr_admin,
    brktrkr_import,
    brktrkr_migrator,
    brktrkr_owner;

/*
 * Observational getters are intentionally PUBLIC for use by RLS and policy
 * expressions. They expose only transaction-local context already present in
 * the caller's backend and do not grant authority.
 */
REVOKE ALL
ON FUNCTION identity.current_user_id()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION app.current_request_id()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION app.current_trace_id()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION app.current_actor_class()
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION identity.current_user_id()
TO PUBLIC;

GRANT EXECUTE
ON FUNCTION app.current_request_id()
TO PUBLIC;

GRANT EXECUTE
ON FUNCTION app.current_trace_id()
TO PUBLIC;

GRANT EXECUTE
ON FUNCTION app.current_actor_class()
TO PUBLIC;

/*
 * Strict throwing getter remains limited to BrickTrackr capability roles.
 */
REVOKE ALL
ON FUNCTION identity.require_current_user_id()
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION identity.require_current_user_id()
TO
    brktrkr_api,
    brktrkr_admin,
    brktrkr_import,
    brktrkr_migrator,
    brktrkr_owner;

-- =============================================================================
-- 6. Completion marker
-- =============================================================================

SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5709_system_request_context.sql');

\echo '[PASS] 5709_system_request_context.sql installed successfully.'
