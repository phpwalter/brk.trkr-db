\set ON_ERROR_STOP on

-- =============================================================================
-- File: master.schema/5000_function/5700_system/5709_system_request_context.sql
-- File Version: 1.1.0
-- Description:
--   Hardened canonical transaction-local request-context transport for
--   BrickTrackr. Authentication is performed upstream by trusted application
--   services. These GUCs carry already-established authority inside a single
--   PostgreSQL transaction; they are not authentication primitives.
--
-- Security invariants:
--   * All app.* context writes use pg_catalog.set_config(..., true).
--   * USER context may be established only by brktrkr_api.
--   * ADMIN context may be established only by brktrkr_admin.
--   * IMPORTER context may be established only by brktrkr_import.
--   * SYSTEM context may be established only by brktrkr_migrator or
--     brktrkr_owner.
--   * Privileged actor classes never carry an application user UUID.
--   * SECURITY DEFINER routines use search_path = pg_catalog only.
--   * PUBLIC receives no execution right on request-context mutators.
--   * Context clearing is SECURITY INVOKER and transaction-local.
--   * Request-context callers receive USAGE, not CREATE, on app/identity.
-- =============================================================================

SELECT pg_temp.bt_preflight(
    '5000_function/5700_system/5709_system_request_context.sql',
    ARRAY[
        '0000_bootstrap/0001_schemas.sql',
        '0100_identity/0100_users.sql',
        '1100_security/1100_roles.sql'
    ]
);

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
    PERFORM pg_catalog.set_config('app.current_user_id', '', TRUE);
    PERFORM pg_catalog.set_config('app.request_id', '', TRUE);
    PERFORM pg_catalog.set_config('app.trace_id', '', TRUE);
    PERFORM pg_catalog.set_config('app.actor_class', '', TRUE);
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
        pg_catalog.current_setting('app.current_user_id', TRUE),
        ''
    )::UUID;
$function$;

ALTER FUNCTION identity.current_user_id()
OWNER TO brktrkr_owner;

CREATE OR REPLACE FUNCTION app.current_request_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
    SELECT NULLIF(
        pg_catalog.current_setting('app.request_id', TRUE),
        ''
    )::UUID;
$function$;

ALTER FUNCTION app.current_request_id()
OWNER TO brktrkr_owner;

CREATE OR REPLACE FUNCTION app.current_trace_id()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
    SELECT NULLIF(
        pg_catalog.current_setting('app.trace_id', TRUE),
        ''
    );
$function$;

ALTER FUNCTION app.current_trace_id()
OWNER TO brktrkr_owner;

CREATE OR REPLACE FUNCTION app.current_actor_class()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog
AS $function$
    SELECT NULLIF(
        pg_catalog.current_setting('app.actor_class', TRUE),
        ''
    );
$function$;

ALTER FUNCTION app.current_actor_class()
OWNER TO brktrkr_owner;

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

-- =============================================================================
-- 5. Deterministic schema/routine privileges
-- =============================================================================

/*
 * PostgreSQL requires schema USAGE in addition to routine EXECUTE.
 * These grants permit request-context routine resolution only.
 */
GRANT USAGE
ON SCHEMA app, identity
TO
    brktrkr_api,
    brktrkr_admin,
    brktrkr_import,
    brktrkr_migrator,
    brktrkr_owner;

REVOKE CREATE
ON SCHEMA app, identity
FROM
    brktrkr_api,
    brktrkr_admin,
    brktrkr_import,
    brktrkr_migrator;

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

REVOKE ALL ON FUNCTION identity.current_user_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.current_request_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.current_trace_id() FROM PUBLIC;
REVOKE ALL ON FUNCTION app.current_actor_class() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION identity.current_user_id() TO PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_request_id() TO PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_trace_id() TO PUBLIC;
GRANT EXECUTE ON FUNCTION app.current_actor_class() TO PUBLIC;

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

SELECT pg_temp.bt_mark_completed(
    '5000_function/5700_system/5709_system_request_context.sql'
);

\echo '[PASS] 5709_system_request_context.sql v1.1.0 installed successfully.'
