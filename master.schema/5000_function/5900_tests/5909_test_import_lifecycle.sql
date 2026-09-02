/*
===============================================================================
 File:           5000_function/5900_tests/5909_test_import_lifecycle.sql
 Project:        BrickTrackr
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Consolidated behavioral tests for the import schema lifecycle:
                 Rebrickable MOC rejection, source-run completion/failure,
                 reference/catalog reconciliation checkpoint routines, SET
                 manifest enrichment execute-only contracts, and catalog
                 summary delta accumulation.
 Depends On:     5000_function/5000_importer/5000_importer_common.sql
                 5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql
                 5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql
                 5000_function/5000_importer/5012_importer_fail_source_run.sql
                 5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql
                 5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql
                 5000_function/5700_system/5709_system_request_context.sql
 Creates:        Test assertions only

 Transaction boundary: The five predecessor test files this consolidates
 (5900/5901/5902/5903/5904) never actually invoked the checkpointed Phase
 3B/4B/5B/6B reconciliation routines with fixture data -- they were pg_proc/
 to_regprocedure signature checks plus a handful of independent negative-path
 calls (unknown source_run_id, empty reason, etc). None of them relied on
 state committed by an earlier phase within the same test run, so there is no
 cross-phase committed-state dependency to preserve. This file therefore uses
 a single BEGIN...ROLLBACK wrapping every section below, matching the other
 5900_tests files; no intermediate COMMIT is required or performed.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5909_test_import_lifecycle.sql', ARRAY['5000_function/5000_importer/5000_importer_common.sql', '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql', '5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql', '5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql', '5000_function/5700_system/5709_system_request_context.sql']::text[]);

\echo '[TEST] 5909_test_import_lifecycle.sql'

BEGIN;

-- =============================================================================
-- 0. Routine signature/prokind contract (from tools/run_stored_procedure_tests.py
--    EXPECTED_ROUTINES, migrated verbatim from the five predecessor files).
-- =============================================================================

DO $$
DECLARE
    v record;
    v_oid oid;
    v_kind "char";
BEGIN
    FOR v IN
        SELECT *
        FROM (VALUES
            ('import.reject_rebrickable_moc_staging()', 'f'),
            ('import.complete_source_run(uuid,jsonb)', 'f'),
            ('import.reconcile_rebrickable_reference(uuid)', 'f'),
            ('import.phase3b_initialize(uuid,boolean)', 'f'),
            ('import.phase3b_run_checkpoint(uuid,text,text,integer)', 'f'),
            ('import.phase3b_progress(uuid)', 'f'),
            ('import.phase4b_initialize(uuid,boolean)', 'f'),
            ('import.phase4b_run_checkpoint(uuid,text,text,integer)', 'f'),
            ('import.phase4b_progress(uuid)', 'f'),
            ('import.phase5b_initialize(uuid,boolean)', 'f'),
            ('import.phase5b_run_checkpoint(uuid,text,text,integer)', 'f'),
            ('import.phase5b_progress(uuid)', 'f'),
            ('import.phase6b_reconcile(uuid)', 'f'),
            ('import.fail_source_run(uuid,text)', 'f'),
            ('import.accumulate_catalog_summary_delta(uuid,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint)', 'f')
        ) AS x(signature, expected_kind)
    LOOP
        v_oid := to_regprocedure(v.signature);
        PERFORM app.assert_true(
            v_oid IS NOT NULL,
            format('Required routine %s is missing', v.signature)
        );

        SELECT p.prokind
          INTO v_kind
          FROM pg_proc p
         WHERE p.oid = v_oid;

        PERFORM app.assert_true(
            v_kind = v.expected_kind::"char",
            format(
                'Routine %s has prokind=%s; expected=%s',
                v.signature, v_kind, v.expected_kind
            )
        );
    END LOOP;
END;
$$;

-- =============================================================================
-- 1. import.reject_rebrickable_moc_staging()  (trg_reject_rebrickable_mocs)
-- =============================================================================
-- Rebrickable MOC catalog ingestion is prohibited by platform policy; the
-- BEFORE INSERT/UPDATE trigger on import.source_stage_records enforces this
-- only for the REBRICKABLE source, and only for entity_namespace = 'MOC'.

DO $$
DECLARE
    v_source_id smallint;
    v_run_id uuid;
    v_failed boolean;
BEGIN
    SELECT source_id INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    INSERT INTO import.source_runs (source_id, status)
    VALUES (v_source_id, 'STARTED')
    RETURNING source_run_id INTO v_run_id;

    PERFORM app.set_import_context(v_run_id);

    /* Rebrickable MOC staging must be rejected. */
    v_failed := false;
    BEGIN
        INSERT INTO import.source_stage_records (
            source_run_id, dataset_name, entity_namespace, normalized_payload
        )
        VALUES (
            v_run_id, 'mocs', 'MOC', '{"moc_id": "MOC-1"}'::jsonb
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(
        v_failed,
        'reject_rebrickable_moc_staging() did not reject Rebrickable MOC staging'
    );

    /* Non-MOC Rebrickable staging must be unaffected. */
    INSERT INTO import.source_stage_records (
        source_run_id, dataset_name, entity_namespace, normalized_payload
    )
    VALUES (
        v_run_id, 'parts', 'PART', '{"part_num": "3001"}'::jsonb
    );

    PERFORM app.assert_true(
        EXISTS (
            SELECT 1
              FROM import.source_stage_records
             WHERE source_run_id = v_run_id
               AND entity_namespace = 'PART'
        ),
        'Non-MOC Rebrickable staging was unexpectedly rejected'
    );
END;
$$;

-- =============================================================================
-- 2. import.complete_source_run(uuid,jsonb)
-- =============================================================================
-- Authoritative source-run finalization: requires at least one authoritative
-- dataset completion record, all authoritative datasets COMPLETED, and the
-- run itself in VALIDATING/FINALIZING.

DO $$
DECLARE
    v_source_id smallint;
    v_run_id uuid;
    v_status import.source_run_status;
    v_summary jsonb;
    v_failed boolean;
BEGIN
    SELECT source_id INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    /* No authoritative dataset completion records at all. */
    INSERT INTO import.source_runs (source_id, status)
    VALUES (v_source_id, 'VALIDATING')
    RETURNING source_run_id INTO v_run_id;

    v_failed := false;
    BEGIN
        PERFORM import.complete_source_run(v_run_id, '{}'::jsonb);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'complete_source_run() completed a run with no authoritative dataset records'
    );

    /* Authoritative dataset present but not COMPLETED. */
    INSERT INTO import.source_run_datasets (
        source_run_id, dataset_name, is_authoritative_scope, status
    )
    VALUES (
        v_run_id, 'parts', true, 'VALIDATED'
    );

    v_failed := false;
    BEGIN
        PERFORM import.complete_source_run(v_run_id, '{}'::jsonb);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'complete_source_run() completed a run with an incomplete authoritative dataset'
    );

    /* All authoritative datasets COMPLETED: finalization succeeds. */
    UPDATE import.source_run_datasets
       SET status = 'COMPLETED',
           completed_at = clock_timestamp()
     WHERE source_run_id = v_run_id
       AND dataset_name = 'parts';

    v_summary := jsonb_build_object('phase', 'test', 'note', '5909 completion test');
    PERFORM import.complete_source_run(v_run_id, v_summary);

    SELECT status, summary
      INTO v_status, v_summary
      FROM import.source_runs
     WHERE source_run_id = v_run_id;

    PERFORM app.assert_true(
        v_status = 'COMPLETED',
        'complete_source_run() did not set status COMPLETED'
    );
    PERFORM app.assert_true(
        v_summary ->> 'note' = '5909 completion test',
        'complete_source_run() did not persist the supplied summary'
    );

    /* Terminal run is not in a completable state a second time. */
    v_failed := false;
    BEGIN
        PERFORM import.complete_source_run(v_run_id, '{}'::jsonb);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'complete_source_run() re-completed an already-completed run'
    );

    /* Unknown source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.complete_source_run(gen_random_uuid(), '{}'::jsonb);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'complete_source_run() accepted an unknown source_run_id'
    );
END;
$$;

-- =============================================================================
-- 3. import.reconcile_rebrickable_reference(uuid)
-- =============================================================================
-- Phase-1 reference reconciliation (colors/themes/categories). Behavioral
-- coverage is limited to the guarded entry contract; the reconciliation body
-- itself requires full Phase-1 staging fixtures that predecessor tests never
-- established either.

DO $$
DECLARE
    v_failed boolean;
BEGIN
    /* Unknown Rebrickable source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.reconcile_rebrickable_reference(gen_random_uuid());
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'reconcile_rebrickable_reference() accepted an unknown source_run_id'
    );
END;
$$;

-- =============================================================================
-- 4. import.phase3b_initialize / phase3b_run_checkpoint / phase3b_progress
-- =============================================================================
-- Checkpointed Phase 3B (parts/sets/minifigures) reconciliation. As with
-- Phase 5010 above, the batchable checkpoint bodies require complete staged
-- Phase 3 datasets (parts/sets/minifigs) plus reference mapping fixtures;
-- behavioral coverage here is the guarded entry contract shared by every
-- checkpoint routine (unknown/ineligible source run, unknown checkpoint).

DO $$
DECLARE
    v_source_id smallint;
    v_run_id uuid;
    v_failed boolean;
BEGIN
    SELECT source_id INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    /* phase3b_initialize: unknown source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.phase3b_initialize(gen_random_uuid(), false);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase3b_initialize() accepted an unknown source_run_id'
    );

    /* phase3b_initialize: run not yet eligible (still STARTED, no staging). */
    INSERT INTO import.source_runs (source_id, status)
    VALUES (v_source_id, 'STARTED')
    RETURNING source_run_id INTO v_run_id;

    v_failed := false;
    BEGIN
        PERFORM import.phase3b_initialize(v_run_id, false);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase3b_initialize() accepted a source run ineligible for Phase 3B'
    );

    /* phase3b_run_checkpoint: unknown source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.phase3b_run_checkpoint(
            gen_random_uuid(), 'VALIDATE_SOURCE_RUN', 'RUN_CONTRACT', 5000
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase3b_run_checkpoint() accepted an unknown source_run_id'
    );

    /* phase3b_run_checkpoint: batch_size out of range rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.phase3b_run_checkpoint(
            v_run_id, 'VALIDATE_SOURCE_RUN', 'RUN_CONTRACT', 0
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase3b_run_checkpoint() accepted an out-of-range batch_size'
    );

    /* phase3b_progress: unknown run returns no rows rather than erroring. */
    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT 1 FROM import.phase3b_progress(gen_random_uuid())
        ),
        'phase3b_progress() unexpectedly returned rows for an unknown source_run_id'
    );
END;
$$;

-- =============================================================================
-- 5. import.phase4b_initialize / phase4b_run_checkpoint / phase4b_progress
-- =============================================================================
-- Checkpointed Phase 4B (elements/part-color variants) reconciliation.
-- Same rationale as Phase 3B above: guarded entry contract only.

DO $$
DECLARE
    v_source_id smallint;
    v_run_id uuid;
    v_failed boolean;
BEGIN
    SELECT source_id INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    /* phase4b_initialize: unknown source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.phase4b_initialize(gen_random_uuid(), false);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase4b_initialize() accepted an unknown source_run_id'
    );

    /* phase4b_initialize: run status not VALIDATING/FINALIZING rejected. */
    INSERT INTO import.source_runs (source_id, status)
    VALUES (v_source_id, 'STARTED')
    RETURNING source_run_id INTO v_run_id;

    v_failed := false;
    BEGIN
        PERFORM import.phase4b_initialize(v_run_id, false);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase4b_initialize() accepted a source run with the wrong lifecycle status'
    );

    /* phase4b_run_checkpoint: unknown source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.phase4b_run_checkpoint(
            gen_random_uuid(), 'P4B_VALIDATE', 'SOURCE_CONTRACT', 5000
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase4b_run_checkpoint() accepted an unknown source_run_id'
    );

    /* phase4b_progress: unknown run returns no rows rather than erroring. */
    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT 1 FROM import.phase4b_progress(gen_random_uuid())
        ),
        'phase4b_progress() unexpectedly returned rows for an unknown source_run_id'
    );
END;
$$;

-- =============================================================================
-- 6. import.phase5b_initialize / phase5b_run_checkpoint / phase5b_progress
-- =============================================================================
-- Checkpointed Phase 5B (inventories/definitions/versions) reconciliation.
-- Same rationale as Phase 3B/4B above: guarded entry contract only.

DO $$
DECLARE
    v_source_id smallint;
    v_run_id uuid;
    v_failed boolean;
BEGIN
    SELECT source_id INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    /* phase5b_initialize: unknown source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.phase5b_initialize(gen_random_uuid(), false);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase5b_initialize() accepted an unknown source_run_id'
    );

    /* phase5b_initialize: run status not VALIDATING/FINALIZING rejected. */
    INSERT INTO import.source_runs (source_id, status)
    VALUES (v_source_id, 'STARTED')
    RETURNING source_run_id INTO v_run_id;

    v_failed := false;
    BEGIN
        PERFORM import.phase5b_initialize(v_run_id, false);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase5b_initialize() accepted a source run with the wrong lifecycle status'
    );

    /* phase5b_run_checkpoint: unknown source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.phase5b_run_checkpoint(
            gen_random_uuid(), 'P5B_VALIDATE', 'SOURCE_CONTRACT', 5000
        );
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase5b_run_checkpoint() accepted an unknown source_run_id'
    );

    /* phase5b_progress: unknown run returns no rows rather than erroring. */
    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT 1 FROM import.phase5b_progress(gen_random_uuid())
        ),
        'phase5b_progress() unexpectedly returned rows for an unknown source_run_id'
    );
END;
$$;

-- =============================================================================
-- 7. import.phase6b_reconcile(uuid)
-- =============================================================================
-- Part-relationship reconciliation. Guarded entry contract only, matching
-- the same scope predecessor test 5902 covered (signature only).

DO $$
DECLARE
    v_failed boolean;
BEGIN
    v_failed := false;
    BEGIN
        PERFORM import.phase6b_reconcile(gen_random_uuid());
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase6b_reconcile() accepted an unknown source_run_id'
    );

    /* p_source_run_id IS NULL explicitly rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.phase6b_reconcile(NULL);
    EXCEPTION
        WHEN OTHERS THEN
            v_failed := true;
    END;
    PERFORM app.assert_true(
        v_failed,
        'phase6b_reconcile() accepted a NULL source_run_id'
    );
END;
$$;

-- =============================================================================
-- 8. import.fail_source_run(uuid,text)
-- =============================================================================

DO $$
DECLARE
    v_source_id smallint;
    v_run_id uuid;
    v_status import.source_run_status;
    v_failed_at timestamptz;
    v_failure_message text;
    v_failed boolean;
BEGIN
    SELECT source_id INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    /* Guarded transition from a live, non-terminal status to FAILED. */
    INSERT INTO import.source_runs (source_id, status)
    VALUES (v_source_id, 'STARTED')
    RETURNING source_run_id INTO v_run_id;

    PERFORM import.fail_source_run(v_run_id, '5909 fail_source_run test');

    SELECT status, failed_at, failure_message
      INTO v_status, v_failed_at, v_failure_message
      FROM import.source_runs
     WHERE source_run_id = v_run_id;

    PERFORM app.assert_true(
        v_status = 'FAILED',
        'fail_source_run() did not set status FAILED'
    );
    PERFORM app.assert_true(
        v_failed_at IS NOT NULL,
        'fail_source_run() did not set failed_at'
    );
    PERFORM app.assert_true(
        v_failure_message = '5909 fail_source_run test',
        'fail_source_run() did not persist the failure message'
    );

    /* Terminal (FAILED) run cannot transition to FAILED again. */
    v_failed := false;
    BEGIN
        PERFORM import.fail_source_run(v_run_id, 'second failure attempt');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '55000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'fail_source_run() allowed a terminal FAILED run to fail again'
    );

    /* NULL/blank failure_message rejected. */
    INSERT INTO import.source_runs (source_id, status)
    VALUES (v_source_id, 'STARTED')
    RETURNING source_run_id INTO v_run_id;

    v_failed := false;
    BEGIN
        PERFORM import.fail_source_run(v_run_id, '   ');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'fail_source_run() accepted a blank failure_message'
    );

    /* Unknown source run rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.fail_source_run(gen_random_uuid(), 'stored procedure test');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0002' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'fail_source_run() accepted an unknown source_run_id'
    );
END;
$$;

-- =============================================================================
-- 9. SET manifest enrichment execute-only contract
--    (import.upsert_set_manifest_component, import.mark_set_manifest_component_missing,
--    import.reconcile_rebrickable_sticker_sheets)
-- =============================================================================
-- Migrated verbatim from predecessor 5904. These are contract/privilege
-- checks, not behavioral fixture tests; the routines require full Phase 5
-- manifest/inventory fixtures to exercise behaviorally, which predecessor
-- tests never established.
--
-- reporting.get_set_manifest_enrichment is intentionally only signature/
-- privilege-checked here (as it always was) -- its real behavioral test
-- belongs to the reporting schema's own consolidated test file, not here.

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'import'
          AND p.proname = 'upsert_set_manifest_component'
          AND p.prosecdef
    ),
    'import.upsert_set_manifest_component must be SECURITY DEFINER'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'import'
          AND p.proname = 'mark_set_manifest_component_missing'
          AND p.prosecdef
    ),
    'import.mark_set_manifest_component_missing must be SECURITY DEFINER'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'import'
          AND p.proname = 'reconcile_rebrickable_sticker_sheets'
          AND p.prosecdef
    ),
    'import.reconcile_rebrickable_sticker_sheets must be SECURITY DEFINER'
);

SELECT app.assert_true(
    has_function_privilege(
        'brktrkr_import',
        'import.reconcile_rebrickable_sticker_sheets(uuid)',
        'EXECUTE'
    ),
    'brktrkr_import must execute automatic sticker reconciliation'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'reporting'
          AND p.proname = 'get_set_manifest_enrichment'
          AND p.prosecdef
    ),
    'reporting.get_set_manifest_enrichment must be SECURITY DEFINER'
);

SELECT app.assert_true(
    NOT has_table_privilege('brktrkr_import','definition.set_manifest_components','INSERT')
    AND NOT has_table_privilege('brktrkr_import','definition.set_manifest_components','UPDATE')
    AND NOT has_table_privilege('brktrkr_import','definition.set_manifest_components','DELETE'),
    'brktrkr_import must remain execute-only for manifest enrichment'
);

-- =============================================================================
-- 10. import.accumulate_catalog_summary_delta(...)  [NEW COVERAGE]
-- =============================================================================
-- Defined in 1000_reporting/1011_reporting_aggregate_tables.sql (schema-
-- qualified `import.` despite living under 1000_reporting/ -- it is the
-- importer-side write path feeding reporting.import_summary/catalog_kind_summary).
-- No prior test file exercised this routine at all; this is genuinely new
-- coverage proving it correctly accumulates a catalog-summary delta.

DO $$
DECLARE
    v_source_id smallint;
    v_run_id uuid;
    v_delta import.catalog_summary_delta%ROWTYPE;
    v_summary reporting.import_summary%ROWTYPE;
    v_failed boolean;
BEGIN
    SELECT source_id INTO v_source_id
      FROM reference.external_sources
     WHERE source_code = 'REBRICKABLE';

    INSERT INTO import.source_runs (source_id, status)
    VALUES (v_source_id, 'STARTED')
    RETURNING source_run_id INTO v_run_id;

    /* First delta call: catalog_summary_delta row created with these values. */
    PERFORM import.accumulate_catalog_summary_delta(
        p_source_run_id => v_run_id,
        p_catalog_items_inserted => 5,
        p_sets_inserted => 3
    );

    SELECT * INTO v_delta
      FROM import.catalog_summary_delta
     WHERE source_run_id = v_run_id;

    PERFORM app.assert_true(
        FOUND,
        'accumulate_catalog_summary_delta() did not create a catalog_summary_delta row'
    );
    PERFORM app.assert_true(
        v_delta.catalog_items_inserted = 5 AND v_delta.sets_inserted = 3,
        'accumulate_catalog_summary_delta() did not persist the initial delta'
    );
    PERFORM app.assert_true(
        v_delta.parts_inserted = 0,
        'accumulate_catalog_summary_delta() populated an untouched column'
    );

    /* Second delta call: values must accumulate additively, not overwrite. */
    PERFORM import.accumulate_catalog_summary_delta(
        p_source_run_id => v_run_id,
        p_catalog_items_inserted => 2,
        p_parts_inserted => 1
    );

    SELECT * INTO v_delta
      FROM import.catalog_summary_delta
     WHERE source_run_id = v_run_id;

    PERFORM app.assert_true(
        v_delta.catalog_items_inserted = 7,
        'accumulate_catalog_summary_delta() did not accumulate catalog_items_inserted additively'
    );
    PERFORM app.assert_true(
        v_delta.sets_inserted = 3,
        'accumulate_catalog_summary_delta() clobbered a column not touched by the second call'
    );
    PERFORM app.assert_true(
        v_delta.parts_inserted = 1,
        'accumulate_catalog_summary_delta() did not persist the second call''s new column'
    );

    /* reporting.import_summary must mirror the current accumulated totals. */
    SELECT * INTO v_summary
      FROM reporting.import_summary
     WHERE source_run_id = v_run_id;

    PERFORM app.assert_true(
        FOUND,
        'accumulate_catalog_summary_delta() did not mirror into reporting.import_summary'
    );
    PERFORM app.assert_true(
        v_summary.source_code = 'REBRICKABLE'
        AND v_summary.catalog_items_inserted = 7
        AND v_summary.sets_inserted = 3
        AND v_summary.parts_inserted = 1,
        'reporting.import_summary does not mirror the accumulated catalog_summary_delta totals'
    );

    /* NULL source_run_id is a documented no-op, not an error. */
    PERFORM import.accumulate_catalog_summary_delta(p_source_run_id => NULL);

    /* Unknown source_run_id rejected. */
    v_failed := false;
    BEGIN
        PERFORM import.accumulate_catalog_summary_delta(
            p_source_run_id => gen_random_uuid()
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22023' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'accumulate_catalog_summary_delta() accepted an unknown source_run_id'
    );
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5909_test_import_lifecycle.sql');
