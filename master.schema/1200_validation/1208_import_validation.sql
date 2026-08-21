/*
===============================================================================
 File:           1200_validation/1208_import_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate authoritative synchronization runs, raw/normalized
                 user imports, candidate matches, mapping suggestions, and
                 reversible import applications.
 Depends On:     Complete 0800_imports domain
                 reference.external_sources
                 catalog
 Creates:        No persistent database objects.
 Key Rules:      Source runs are observations, not semantic versions.
                 Completed authoritative runs require all authoritative datasets
                 to be complete.
                 Rebrickable MOC catalog data is explicitly prohibited.
                 User imports never directly mutate canonical data.
                 At most one selected candidate match exists per normalized row.
                 Applied imports remain reversible as logical operations.
 Validation:     Checks dataset completion, Rebrickable MOC exclusion, selected
                 match uniqueness, match-state consistency, raw/normalized job
                 ownership, mapping targets, and application reversal state.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1208_import_validation.sql', ARRAY['Complete 0800_imports domain', 'reference.external_sources', 'catalog']::text[]);



\echo '[VALIDATE] 1208_import_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required tables                                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_table_exists('import', 'jobs');
SELECT app.assert_table_exists('import', 'source_runs');
SELECT app.assert_table_exists('import', 'raw_records');
SELECT app.assert_table_exists('import', 'source_stage_records');
SELECT app.assert_table_exists('import', 'source_run_datasets');
SELECT app.assert_table_exists('import', 'normalized_records');
SELECT app.assert_table_exists('import', 'matches');
SELECT app.assert_table_exists('import', 'user_mapping_suggestions');
SELECT app.assert_table_exists('import', 'applications');
SELECT app.assert_table_exists('import', 'application_changes');


/* -------------------------------------------------------------------------- */
/* Completed source runs require complete authoritative datasets              */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.source_runs r
    WHERE r.status = 'COMPLETED'
      AND EXISTS (
          SELECT 1
          FROM import.source_run_datasets d
          WHERE d.source_run_id = r.source_run_id
            AND d.is_authoritative_scope
            AND d.status <> 'COMPLETED'
      )
$$,
'Completed source run contains incomplete authoritative datasets'
);


/* -------------------------------------------------------------------------- */
/* Completed source run must have dataset evidence                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.source_runs r
    WHERE r.status = 'COMPLETED'
      AND NOT EXISTS (
          SELECT 1
          FROM import.source_run_datasets d
          WHERE d.source_run_id = r.source_run_id
      )
$$,
'Completed source run has no dataset-completion evidence'
);


/* -------------------------------------------------------------------------- */
/* Rebrickable MOC exclusion                                                  */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.source_stage_records sr

    JOIN import.source_runs r
      ON r.source_run_id = sr.source_run_id

    JOIN reference.external_sources s
      ON s.source_id = r.source_id

    WHERE s.source_code = 'REBRICKABLE'
      AND sr.entity_namespace = 'MOC'
$$,
'Rebrickable MOC data exists in authoritative staging'
);


/* -------------------------------------------------------------------------- */
/* Selected match uniqueness                                                  */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT normalized_record_id
    FROM import.matches
    WHERE is_selected
    GROUP BY normalized_record_id
    HAVING count(*) > 1
$$,
'Normalized import record has more than one selected match'
);


/* -------------------------------------------------------------------------- */
/* Selected target consistency                                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.matches
    WHERE num_nonnulls(catalog_item_id, part_variant_id) <> 1
$$,
'Import match does not target exactly one catalog item or part variant'
);


/* -------------------------------------------------------------------------- */
/* Normalized/raw record must belong to same job                              */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.normalized_records n
    JOIN import.raw_records r
      ON r.raw_record_id = n.raw_record_id
    WHERE n.raw_record_id IS NOT NULL
      AND n.import_job_id <> r.import_job_id
$$,
'Normalized import record references raw data from another import job'
);


/* -------------------------------------------------------------------------- */
/* USER_MATCHED rows should have a selected resolved candidate                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.normalized_records n
    WHERE n.match_status = 'USER_MATCHED'
      AND NOT EXISTS (
          SELECT 1
          FROM import.matches m
          WHERE m.normalized_record_id = n.normalized_record_id
            AND m.is_selected
            AND m.resolved_by_user_id IS NOT NULL
            AND m.resolved_at IS NOT NULL
      )
$$,
'USER_MATCHED normalized record lacks a user-resolved selected match'
);


/* -------------------------------------------------------------------------- */
/* AUTO_MATCHED rows require selected candidate                               */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.normalized_records n
    WHERE n.match_status = 'AUTO_MATCHED'
      AND NOT EXISTS (
          SELECT 1
          FROM import.matches m
          WHERE m.normalized_record_id = n.normalized_record_id
            AND m.is_selected
      )
$$,
'AUTO_MATCHED normalized record lacks a selected candidate'
);


/* -------------------------------------------------------------------------- */
/* Ambiguous rows must not have selected match                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.normalized_records n
    WHERE n.match_status = 'AMBIGUOUS'
      AND EXISTS (
          SELECT 1
          FROM import.matches m
          WHERE m.normalized_record_id = n.normalized_record_id
            AND m.is_selected
      )
$$,
'AMBIGUOUS normalized record already has a selected match'
);


/* -------------------------------------------------------------------------- */
/* User mapping target integrity                                              */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.user_mapping_suggestions
    WHERE num_nonnulls(catalog_item_id, part_variant_id) <> 1
$$,
'User mapping suggestion does not target exactly one canonical object'
);


/* -------------------------------------------------------------------------- */
/* Import application reversal consistency                                    */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM import.applications
    WHERE
        (
            reversed_at IS NULL
            AND reversed_by_user_id IS NOT NULL
        )
        OR
        (
            reversed_at IS NOT NULL
            AND reversed_by_user_id IS NULL
        )
$$,
'Import application reversal state is incomplete'
);


/* -------------------------------------------------------------------------- */
/* Only one currently active application per job                              */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT import_job_id
    FROM import.applications
    WHERE reversed_at IS NULL
    GROUP BY import_job_id
    HAVING count(*) > 1
$$,
'Import job has more than one active application'
);


\echo '[VALIDATE PASS] 1208_import_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1208_import_validation.sql');
