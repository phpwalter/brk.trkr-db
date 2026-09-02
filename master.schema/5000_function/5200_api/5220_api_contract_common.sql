/*
===============================================================================
 File:           5000_function/5200_api/5220_api_contract_common.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Shared helpers for the complete v3 HTTP contract, including
                 deterministic ETags, optimistic concurrency validation and
                 current-user ownership resolution.
 Depends On:     api schema
                 identity.current_user_id()
                 identity.owners
 Creates:        api.etag_for_revision()
                 api.assert_if_match()
                 api.current_user_owner_id()
 Key Rules:      If-Match is mandatory at the HTTP layer for protected writes;
                 the database independently verifies the supplied revision.
                 API resources never authorize ownership by caller-supplied
                 owner identifiers alone.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5220_api_contract_common.sql',
    ARRAY[
        'api schema',
        'identity.current_user_id()',
        'identity.owners'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.etag_for_revision(p_revision bigint)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT format('W/"rev%s"', p_revision);
$$;

CREATE OR REPLACE FUNCTION api.assert_if_match(
    p_if_match text,
    p_revision bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, api
AS $$
DECLARE
    v_expected text := api.etag_for_revision(p_revision);
BEGIN
    IF p_if_match IS NULL OR btrim(p_if_match) = '' THEN
        RAISE EXCEPTION 'If-Match is required'
            USING ERRCODE = 'P0428';
    END IF;

    IF p_if_match <> v_expected AND p_if_match <> '*' THEN
        RAISE EXCEPTION 'ETag does not match current resource revision'
            USING ERRCODE = 'P0412',
                  DETAIL = format('Expected %s', v_expected);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.current_user_owner_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $$
DECLARE
    v_user_id uuid := identity.current_user_id();
    v_owner_id uuid;
BEGIN
    SELECT o.owner_id
      INTO v_owner_id
      FROM identity.owners o
     WHERE o.owner_type = 'USER'
       AND o.user_id = v_user_id;

    IF v_owner_id IS NULL THEN
        RAISE EXCEPTION 'Authenticated user has no ownership principal'
            USING ERRCODE = 'P0403';
    END IF;

    RETURN v_owner_id;
END;
$$;

REVOKE ALL ON FUNCTION api.etag_for_revision(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.assert_if_match(text,bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.current_user_owner_id() FROM PUBLIC;

\echo '[PASS] 5220_api_contract_common.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5220_api_contract_common.sql');
