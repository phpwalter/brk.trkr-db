/*
===============================================================================
 File:           1000_function/1007_import_function.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Connect source-run provenance to catalog/definitions and enforce
                 authoritative source-run finalization rules.
 Depends On:     import.source_runs
                 import.source_run_datasets
                 import.source_stage_records
                 catalog.source_values
                 catalog.source_value_history
                 definition.inventory_versions
                 reference.external_sources
 Creates:        source-run foreign keys on catalog/definition provenance
                 import.reject_rebrickable_moc_staging()
                 import.complete_source_run()
                 trg_reject_rebrickable_mocs
 Key Rules:      Rebrickable MOC catalog ingestion is prohibited.
                 Source runs complete only after all authoritative datasets are
                 completed.
                 Finalization uses a transaction-scoped advisory lock.
                 Failed/non-finalizable runs may not be marked complete.
 Validation:     FK constraints bind source-run provenance; runtime functions
                 reject Rebrickable MOCs and incomplete source-run completion.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1000_function/1007_import_function.sql', ARRAY['import.source_runs', 'import.source_run_datasets', 'import.source_stage_records', 'catalog.source_values', 'catalog.source_value_history', 'definition.inventory_versions', 'reference.external_sources']::text[]);



ALTER TABLE catalog.source_values
    ADD CONSTRAINT fk_catalog_source_values_run
    FOREIGN KEY (last_source_run_id)
    REFERENCES import.source_runs(source_run_id);

ALTER TABLE catalog.source_value_history
    ADD CONSTRAINT fk_catalog_source_value_history_run
    FOREIGN KEY (source_run_id)
    REFERENCES import.source_runs(source_run_id);

ALTER TABLE definition.inventory_versions
    ADD CONSTRAINT fk_inventory_versions_source_run
    FOREIGN KEY (source_run_id)
    REFERENCES import.source_runs(source_run_id);


CREATE FUNCTION import.reject_rebrickable_moc_staging()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_source_code text;
BEGIN
    SELECT s.source_code
    INTO v_source_code
    FROM import.source_runs r
    JOIN reference.external_sources s
      ON s.source_id = r.source_id
    WHERE r.source_run_id =
          NEW.source_run_id;

    IF v_source_code = 'REBRICKABLE'
       AND NEW.entity_namespace = 'MOC'
    THEN
        RAISE EXCEPTION
            'Rebrickable MOC catalog import is disabled by platform policy';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reject_rebrickable_mocs
BEFORE INSERT OR UPDATE
ON import.source_stage_records
FOR EACH ROW
EXECUTE FUNCTION import.reject_rebrickable_moc_staging();


CREATE FUNCTION import.complete_source_run(
    p_source_run_id uuid,
    p_summary jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_incomplete bigint;
BEGIN
    /*
     * Serializes finalization for this run without requiring a global lock.
     */
    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            p_source_run_id::text,
            0
        )
    );

    IF NOT EXISTS (
        SELECT 1
        FROM import.source_runs
        WHERE source_run_id =
              p_source_run_id
    ) THEN
        RAISE EXCEPTION
            'Source run "%" does not exist',
            p_source_run_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM import.source_run_datasets
        WHERE source_run_id =
              p_source_run_id
          AND is_authoritative_scope
    ) THEN
        RAISE EXCEPTION
            'Source run "%" contains no authoritative dataset completion records',
            p_source_run_id;
    END IF;

    SELECT count(*)
    INTO v_incomplete
    FROM import.source_run_datasets
    WHERE source_run_id =
          p_source_run_id
      AND is_authoritative_scope
      AND status <> 'COMPLETED';

    IF v_incomplete > 0 THEN
        RAISE EXCEPTION
            'Source run "%" has % incomplete authoritative datasets',
            p_source_run_id,
            v_incomplete;
    END IF;

    UPDATE import.source_runs
    SET
        status = 'COMPLETED',
        completed_at = now(),
        failed_at = NULL,
        failure_message = NULL,
        summary = p_summary
    WHERE source_run_id = p_source_run_id
      AND status IN (
          'VALIDATING',
          'FINALIZING'
      );

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Source run "%" is not in a completable state',
            p_source_run_id;
    END IF;
END;
$$;

\echo '[PASS] 1007_import_function.sql'
SELECT pg_temp.bt_mark_completed('1000_function/1007_import_function.sql');
