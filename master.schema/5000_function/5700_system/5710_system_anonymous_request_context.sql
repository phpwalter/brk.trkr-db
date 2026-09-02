/*
===============================================================================
 File:           5000_function/5700_system/5710_system_anonymous_request_context.sql
 Project:        BrickTrackr
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Provide transaction-local correlation context for anonymous
                 public API reads without manufacturing an application user or
                 granting a privileged actor class.
 Depends On:     5000_function/5700_system/5709_system_request_context.sql
                 brktrkr_api role
 Creates:        app.set_anonymous_request_context()
 Key Rules:      Authentication is not established by this routine. It may be
                 called only by the API database capability role. User context
                 remains empty, so owner-scoped fail-closed helpers continue to
                 deny access. Anonymous context is intended only for explicitly
                 public read routines.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5700_system/5710_system_anonymous_request_context.sql',
    ARRAY[
        '5000_function/5700_system/5709_system_request_context.sql',
        'brktrkr_api role'
    ]::text[]
);

CREATE OR REPLACE FUNCTION app.set_anonymous_request_context(
    p_request_id uuid,
    p_trace_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_trace_id text;
BEGIN
    IF NOT pg_catalog.pg_has_role(
        SESSION_USER,
        'brktrkr_api',
        'MEMBER'
    ) THEN
        RAISE EXCEPTION
            'Session user % lacks brktrkr_api authority for anonymous API context',
            SESSION_USER
            USING ERRCODE = '42501';
    END IF;

    IF p_request_id IS NULL THEN
        RAISE EXCEPTION
            'p_request_id cannot be null'
            USING ERRCODE = '22004';
    END IF;

    v_trace_id := NULLIF(pg_catalog.btrim(COALESCE(p_trace_id, '')), '');

    IF v_trace_id IS NULL THEN
        RAISE EXCEPTION
            'p_trace_id cannot be null or blank'
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

    PERFORM pg_catalog.set_config('app.current_user_id', '', TRUE);
    PERFORM pg_catalog.set_config('app.request_id', p_request_id::text, TRUE);
    PERFORM pg_catalog.set_config('app.trace_id', v_trace_id, TRUE);
    PERFORM pg_catalog.set_config('app.actor_class', '', TRUE);
END;
$function$;

ALTER FUNCTION app.set_anonymous_request_context(uuid, text)
OWNER TO brktrkr_owner;

REVOKE ALL
ON FUNCTION app.set_anonymous_request_context(uuid, text)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION app.set_anonymous_request_context(uuid, text)
TO brktrkr_api, brktrkr_admin;

COMMENT ON FUNCTION app.set_anonymous_request_context(uuid, text)
IS
'Transaction-local correlation context for explicitly public API reads. Does not establish user identity or a privileged actor class.';

\echo '[PASS] 5710_system_anonymous_request_context.sql v1.3.0 installed successfully.'
SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5710_system_anonymous_request_context.sql');
