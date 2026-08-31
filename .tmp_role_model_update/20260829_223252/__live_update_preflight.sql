\set ON_ERROR_STOP on

/*
===============================================================================
 BrickTrackr LIVE SECURITY UPDATE preflight shim

 This file is intentionally used only for an already-built live database.

 The normal 0000_dependency_preflight.sql implementation tracks which installer
 files completed earlier in the SAME psql session. A security-only maintenance
 run cannot satisfy that greenfield-install history.

 The functions below preserve the interface expected by 1100_security/*.sql
 while treating declared installer dependencies as already satisfied.

 Real live prerequisites are checked by apply_role_model_update_v3.ps1 before
 this session starts.
===============================================================================
*/

CREATE OR REPLACE FUNCTION pg_temp.bt_preflight(
    p_file text,
    p_dependencies text[]
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE '[LIVE-PREFLIGHT] %', p_file;
    RETURN;
END;
$function$;

CREATE OR REPLACE FUNCTION pg_temp.bt_mark_completed(
    p_file text
)
RETURNS void
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE '[LIVE-COMPLETE] %', p_file;
    RETURN;
END;
$function$;

\echo '[PASS] Live-update preflight shim installed.'
