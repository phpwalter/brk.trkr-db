/*
===============================================================================
 File:           5000_function/5000_importer/5012_importer_fail_source_run.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Provide the canonical guarded lifecycle transition from an
                 active import source run to FAILED.
 Depends On:     5000_function/5000_importer/5000_importer_common.sql
 Creates:        import.fail_source_run(uuid,text)
 Key Rules:      Only STARTED/STAGING/VALIDATING/FINALIZING may become FAILED.
                 COMPLETED and FAILED are terminal.
                 A nonblank failure message is mandatory.
                 Staging, dataset, checkpoint, and provenance evidence is kept.
                 Ownership is normalized later by 1111_role_ownership_separation.
                 EXECUTE policy is applied later by 1107_grants.sql.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5000_importer/5012_importer_fail_source_run.sql', ARRAY['5000_function/5000_importer/5000_importer_common.sql']::text[]);

CREATE OR REPLACE FUNCTION import.fail_source_run(
    p_source_run_id uuid,
    p_failure_message text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_status import.source_run_status;
    v_message text;
BEGIN
    IF p_source_run_id IS NULL THEN
        RAISE EXCEPTION 'source_run_id must not be NULL'
            USING ERRCODE = '22004';
    END IF;

    v_message := btrim(p_failure_message);

    IF v_message IS NULL OR v_message = '' THEN
        RAISE EXCEPTION 'failure_message must not be NULL or blank'
            USING ERRCODE = '22023';
    END IF;

    SELECT sr.status
      INTO v_status
      FROM import.source_runs AS sr
     WHERE sr.source_run_id = p_source_run_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source run "%" does not exist', p_source_run_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_status IN (
        'COMPLETED'::import.source_run_status,
        'FAILED'::import.source_run_status
    ) THEN
        RAISE EXCEPTION
            'Source run "%" is terminal with status % and cannot transition to FAILED',
            p_source_run_id, v_status
            USING ERRCODE = '55000';
    END IF;

    IF v_status NOT IN (
        'STARTED'::import.source_run_status,
        'STAGING'::import.source_run_status,
        'VALIDATING'::import.source_run_status,
        'FINALIZING'::import.source_run_status
    ) THEN
        RAISE EXCEPTION
            'Source run "%" has unsupported lifecycle status %',
            p_source_run_id, v_status
            USING ERRCODE = '55000';
    END IF;

    UPDATE import.source_runs
       SET status = 'FAILED'::import.source_run_status,
           failed_at = clock_timestamp(),
           failure_message = v_message
     WHERE source_run_id = p_source_run_id;
END;
$function$;

COMMENT ON FUNCTION import.fail_source_run(uuid,text) IS
    'Guarded authoritative import lifecycle transition from a non-terminal source run to FAILED.';

SELECT pg_temp.bt_mark_completed('5000_function/5000_importer/5012_importer_fail_source_run.sql');
