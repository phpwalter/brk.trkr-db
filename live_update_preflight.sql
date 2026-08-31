\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION pg_temp.bt_preflight(
    p_file text,
    p_dependencies text[]
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE '[LIVE-PREFLIGHT] %', p_file;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bt_mark_completed(
    p_file text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE '[LIVE-COMPLETE] %', p_file;
END;
$$;

\echo '[PASS] Live-update preflight shim installed.'