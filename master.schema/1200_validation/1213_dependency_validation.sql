/*
===============================================================================
 File:           1200_validation/1213_dependency_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Prove that every bootstrap SQL file passed its generated
                 dependency preflight before its executable body ran.
 Depends On:     1200_validation/1212_integrity_validation.sql
                 1200_validation/1214_extended_architecture_validation.sql
                 1200_validation/1215_security_contract_validation.sql
                 1200_validation/1216_adversarial_authorization_validation.sql
                 1200_validation/1217_pgbouncer_transaction_context_validation.sql
                 1200_validation/1218_api_surface_validation.sql
                 1200_validation/1219_migration_framework_validation.sql
                 1200_validation/1220_financial_readiness_validation.sql
                 1200_validation/1221_operational_integrity_validation.sql
                 1200_validation/1222_role_separation_validation.sql
                 1200_validation/1223_admin_catalog_lifecycle_validation.sql
                 5000_function/5900_tests/5900_test_importer_common.sql
                 5000_function/5900_tests/5901_test_rebrickable_reference_reconcile.sql
                 5000_function/5900_tests/5902_test_rebrickable_catalog_reconcile.sql
                 5000_function/5900_tests/5903_test_fail_source_run.sql
                 5000_function/5900_tests/5910_test_admin_common.sql
                 5000_function/5900_tests/5911_test_admin_catalog_lifecycle.sql
                 5000_function/5900_tests/5912_test_admin_definition_graph.sql
                 5000_function/5900_tests/5913_test_admin_finance.sql
                 5000_function/5900_tests/5920_test_api_moc_access.sql
                 5000_function/5900_tests/5921_test_api_operational.sql
                 5000_function/5900_tests/5970_test_system_identity.sql
                 5000_function/5900_tests/5971_test_system_hierarchy.sql
                 5000_function/5900_tests/5972_test_system_catalog.sql
                 5000_function/5900_tests/5973_test_system_definition.sql
                 5000_function/5900_tests/5974_test_system_collection.sql
                 5000_function/5900_tests/5975_test_system_wanted.sql
                 5000_function/5900_tests/5976_test_system_moc.sql
                 5000_function/5900_tests/5977_test_system_audit.sql
                 5000_function/5900_tests/5978_test_system_integrity.sql
                 5000_function/5900_tests/5979_test_system_request_context.sql
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1213_dependency_validation.sql', ARRAY['1200_validation/1212_integrity_validation.sql', '1200_validation/1214_extended_architecture_validation.sql', '1200_validation/1215_security_contract_validation.sql', '1200_validation/1216_adversarial_authorization_validation.sql', '1200_validation/1217_pgbouncer_transaction_context_validation.sql', '1200_validation/1218_api_surface_validation.sql', '1200_validation/1219_migration_framework_validation.sql', '1200_validation/1220_financial_readiness_validation.sql', '1200_validation/1221_operational_integrity_validation.sql', '1200_validation/1222_role_separation_validation.sql', '1200_validation/1223_admin_catalog_lifecycle_validation.sql', '5000_function/5900_tests/5900_test_importer_common.sql', '5000_function/5900_tests/5901_test_rebrickable_reference_reconcile.sql', '5000_function/5900_tests/5902_test_rebrickable_catalog_reconcile.sql', '5000_function/5900_tests/5903_test_fail_source_run.sql', '5000_function/5900_tests/5910_test_admin_common.sql', '5000_function/5900_tests/5911_test_admin_catalog_lifecycle.sql', '5000_function/5900_tests/5912_test_admin_definition_graph.sql', '5000_function/5900_tests/5913_test_admin_finance.sql', '5000_function/5900_tests/5920_test_api_moc_access.sql', '5000_function/5900_tests/5921_test_api_operational.sql', '5000_function/5900_tests/5970_test_system_identity.sql', '5000_function/5900_tests/5971_test_system_hierarchy.sql', '5000_function/5900_tests/5972_test_system_catalog.sql', '5000_function/5900_tests/5973_test_system_definition.sql', '5000_function/5900_tests/5974_test_system_collection.sql', '5000_function/5900_tests/5975_test_system_wanted.sql', '5000_function/5900_tests/5976_test_system_moc.sql', '5000_function/5900_tests/5977_test_system_audit.sql', '5000_function/5900_tests/5978_test_system_integrity.sql', '5000_function/5900_tests/5979_test_system_request_context.sql']::text[]);



\echo '[VALIDATE] 1213_dependency_validation.sql'

DO $$
DECLARE
    v_missing text;
    v_unchecked text;
BEGIN
    SELECT string_agg(e.file_path, ', ' ORDER BY e.ordinal)
      INTO v_missing
      FROM pg_temp.bt_expected_files e
      LEFT JOIN pg_temp.bt_completed_files c USING (file_path)
     WHERE c.file_path IS NULL
       AND e.file_path <> '1200_validation/1213_dependency_validation.sql';

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Expected schema files were not completed before dependency validation: %', v_missing;
    END IF;

    SELECT string_agg(e.file_path, ', ' ORDER BY e.ordinal)
      INTO v_unchecked
      FROM pg_temp.bt_expected_files e
      LEFT JOIN pg_temp.bt_file_preflights p USING (file_path)
     WHERE p.file_path IS NULL
       AND e.file_path NOT IN (
           '0000_bootstrap/0000_dependency_preflight.sql',
           '1200_validation/1213_dependency_validation.sql'
       );

    IF v_unchecked IS NOT NULL THEN
        RAISE EXCEPTION 'Schema files executed without dependency preflight: %', v_unchecked;
    END IF;
END;
$$;

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_temp.bt_dependency_checks
        WHERE NOT satisfied
    ),
    'At least one declared dependency was recorded as unsatisfied'
);

\echo '[PASS] 1213_dependency_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1213_dependency_validation.sql');
