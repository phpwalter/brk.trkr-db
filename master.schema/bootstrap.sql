/*
===============================================================================
 File:           bootstrap.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Construct and validate the complete LEGO Collection Platform
                 PostgreSQL schema on a fresh database.
 Depends On:     PostgreSQL 16+
                 Permission to create extensions
                 Permission to create schemas
                 Permission to create database roles
                 All schema files referenced by this bootstrap
 Creates:        Complete LEGO Collection Platform database schema, including:
                 - bootstrap infrastructure
                 - identity and authentication
                 - reference data
                 - canonical catalog
                 - versioned inventory definitions
                 - user/family collections
                 - wishlists and build goals
                 - MOC management
                 - authoritative and user imports
                 - audit history
                 - runtime functions and triggers
                 - complete v3 stored-routine API contract
                 - database roles, grants, and row-level security
 Key Rules:      Files execute in deterministic dependency order.
                 All file and directory prefixes use four digits.
                 \set ON_ERROR_STOP prevents execution from continuing after
                 the first SQL error.
                 Schema construction is optimized for a fresh database rather
                 than migration or repeated-bootstrap semantics.
                 Domain validation runs after the corresponding base objects are
                 installed. Runtime/security validation runs only after its
                 prerequisites are installed.
===============================================================================
*/

\set ON_ERROR_STOP on
\set VERBOSITY verbose

\echo ''
\echo '=============================================================================='
\echo ' LEGO Collection Platform'
\echo ' PostgreSQL Schema Bootstrap'
\echo '=============================================================================='
\echo ''
\echo '[BOOTSTRAP] Beginning schema installation...'
\echo ''

\echo '[PRECHECK] Installing generated dependency gate...'
\ir 0000_bootstrap/0000_dependency_preflight.sql
\ir 0000_bootstrap/0006_dependency_preflight_v3.sql
\ir 0000_bootstrap/0000_extensions.sql
\ir 0000_bootstrap/0001_schemas.sql
\ir 0000_bootstrap/0002_types.sql
\ir 0000_bootstrap/0003_uuid.sql
\ir 0000_bootstrap/0004_validation_helpers.sql
\ir 0000_bootstrap/0005_migration_framework.sql
\ir 1200_validation/1200_bootstrap_validation.sql

\ir 0100_identity/0100_users.sql
\ir 0100_identity/0101_authentication.sql
\ir 0100_identity/0102_families.sql
\ir 0100_identity/0103_family_memberships.sql
\ir 0100_identity/0104_family_permissions.sql
\ir 0100_identity/0105_guardianships.sql
\ir 0100_identity/0106_owners.sql
\ir 0100_identity/0107_identity_api_state.sql
\ir 1200_validation/1201_identity_validation.sql

\ir 0200_reference/0200_external_sources.sql
\ir 0200_reference/0201_colors.sql
\ir 0200_reference/0202_themes.sql
\ir 0200_reference/0203_categories.sql
\ir 0200_reference/0204_minifig_roles.sql
\ir 1200_validation/1202_reference_validation.sql

\ir 0300_catalog/0300_catalog_items.sql
\ir 0300_catalog/0301_catalog_sets.sql
\ir 0300_catalog/0302_catalog_parts.sql
\ir 0300_catalog/0303_catalog_minifigures.sql
\ir 0300_catalog/0304_catalog_books.sql
\ir 0300_catalog/0305_catalog_mocs.sql
\ir 0300_catalog/0306_catalog_sticker_sheets.sql
\ir 0300_catalog/0307_catalog_instructions.sql
\ir 0300_catalog/0308_catalog_packaging.sql
\ir 0300_catalog/0309_catalog_gear.sql
\ir 0300_catalog/0310_catalog_accessories.sql
\ir 0300_catalog/0311_catalog_polybags.sql
\ir 0300_catalog/0312_catalog_promotional_items.sql
\ir 0300_catalog/0313_catalog_publications.sql
\ir 0300_catalog/0314_catalog_other.sql
\ir 0300_catalog/0315_part_variants.sql
\ir 0300_catalog/0316_lego_elements.sql
\ir 0300_catalog/0317_external_identifiers.sql
\ir 0300_catalog/0318_catalog_authority.sql
\ir 0300_catalog/0319_part_tooling.sql
\ir 0300_catalog/0320_catalog_search_media.sql
\ir 1200_validation/1203_catalog_validation.sql

\ir 0400_definitions/0400_inventory_definitions.sql
\ir 0400_definitions/0401_inventory_versions.sql
\ir 0400_definitions/0402_requirement_groups.sql
\ir 0400_definitions/0403_requirement_options.sql
\ir 0400_definitions/0404_definition_authority.sql
\ir 0400_definitions/0405_manifest_graph.sql
\ir 0400_definitions/0406_minifig_compositions.sql
\ir 0400_definitions/0407_custom_minifig_lifecycle.sql
\ir 0400_definitions/0410_set_manifest_components.sql
\ir 1200_validation/1204_definition_validation.sql

\ir 0500_collections/0500_storage_locations.sql
\ir 0500_collections/0501_collection_entries.sql
\ir 0500_collections/0502_collection_instances.sql
\ir 0500_collections/0503_instance_adjustments.sql
\ir 0500_collections/0504_storage_allocations.sql
\ir 0500_collections/0505_transfers.sql
\ir 0500_collections/0506_acquisitions.sql
\ir 0500_collections/0507_tags.sql
\ir 0500_collections/0508_collection_groups.sql
\ir 1200_validation/1205_collection_validation.sql

\ir 0600_wanted/0600_wishlists.sql
\ir 0600_wanted/0601_wishlist_entries.sql
\ir 0600_wanted/0602_wishlist_reservations.sql
\ir 0600_wanted/0603_build_goals.sql
\ir 0600_wanted/0604_build_allocations.sql
\ir 0600_wanted/0605_wanted_api_state.sql
\ir 1200_validation/1206_wanted_validation.sql

\ir 0700_mocs/0700_mocs.sql
\ir 0700_mocs/0701_moc_revisions.sql
\ir 0700_mocs/0702_moc_forks.sql
\ir 0700_mocs/0703_moc_subassemblies.sql
\ir 0700_mocs/0704_moc_licenses.sql
\ir 0700_mocs/0705_moc_assets.sql
\ir 0700_mocs/0706_moc_api_state.sql
\ir 1200_validation/1207_moc_validation.sql

\ir 0750_marketplace/0750_market_prices.sql
\ir 0750_marketplace/0751_marketplace.sql
\ir 0760_finance/0760_financial_ledger.sql
\ir 0760_finance/0761_financial_readiness_anchors.sql

\ir 0800_imports/0800_import_jobs.sql
\ir 0800_imports/0801_source_runs.sql
\ir 0800_imports/0802_raw_staging.sql
\ir 0800_imports/0803_source_run_datasets.sql
\ir 0800_imports/0804_normalized_records.sql
\ir 0800_imports/0805_import_matches.sql
\ir 0800_imports/0806_user_mapping_suggestions.sql
\ir 0800_imports/0807_import_applications.sql
\ir 1200_validation/1208_import_validation.sql

\ir 0850_operations/0850_jobs_notifications.sql
\ir 0900_audit/0900_audit_events.sql
\ir 0900_audit/0901_audit_changes.sql
\ir 1200_validation/1209_audit_validation.sql

\ir 5000_function/5700_system/5700_system_identity.sql
\ir 5000_function/5700_system/5701_system_hierarchy.sql
\ir 5000_function/5700_system/5702_system_catalog.sql
\ir 5000_function/5700_system/5703_system_definition.sql
\ir 5000_function/5700_system/5704_system_collection.sql
\ir 5000_function/5700_system/5705_system_wanted.sql
\ir 5000_function/5700_system/5706_system_moc.sql
\ir 5000_function/5000_importer/5000_importer_common.sql
\ir 5000_function/5700_system/5707_system_audit.sql
\ir 5000_function/5700_system/5708_system_integrity_hardening.sql
\ir 5000_function/5200_api/5200_api_moc_access.sql
\ir 5000_function/5100_admin/5120_admin_definition_graph.sql
\ir 5000_function/5200_api/5210_api_operational.sql
\ir 5000_function/5200_api/5220_api_contract_common.sql
\ir 5000_function/5200_api/5221_api_catalog_reference.sql
\ir 5000_function/5200_api/5222_api_definition_helpers.sql
\ir 5000_function/5200_api/5230_api_collection_inventory.sql
\ir 5000_function/5200_api/5240_api_wanted.sql
\ir 5000_function/5200_api/5250_api_moc_minifig.sql
\ir 5000_function/5200_api/5260_api_identity_activity.sql
\ir 5000_function/5200_api/5270_api_market_reporting.sql
\ir 5000_function/5100_admin/5130_admin_finance.sql
\ir 5000_function/5100_admin/5131_admin_finance_actor.sql
\ir 5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql
\ir 5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql
\ir 5000_function/5000_importer/5012_importer_fail_source_run.sql
\ir 1000_reporting/1000_reporting_views.sql

\ir 1100_security/1100_roles.sql
\ir 5000_function/5700_system/5709_system_request_context.sql
\ir 5000_function/5700_system/5710_system_anonymous_request_context.sql
\ir 5000_function/5100_admin/5100_admin_common.sql
\ir 5000_function/5100_admin/5110_admin_catalog_lifecycle.sql
\ir 5000_function/5200_api/5280_api_admin_finance.sql
\ir 5000_function/5200_api/5281_api_admin_finance_actor.sql
\ir 5000_function/5200_api/5290_api_visibility_reads.sql
\ir 1200_validation/1210_function_validation.sql

\ir 1100_security/1101_rls_identity.sql
\ir 1100_security/1102_rls_collections.sql
\ir 1100_security/1103_rls_wanted.sql
\ir 1100_security/1104_rls_mocs.sql
\ir 1100_security/1105_rls_imports.sql
\ir 1100_security/1106_rls_audit.sql
\ir 1100_security/1108_rls_catalog_definition.sql
\ir 1100_security/1109_rls_extended.sql
\ir 1100_security/1113_api_v3_rls.sql
\ir 1100_security/1107_grants.sql
\ir 1100_security/1110_api_surface_lockdown.sql
\ir 1100_security/1114_api_v3_execute.sql

\ir 1000_reporting/1010_reporting_system_summary.sql
\ir 1000_reporting/1011_reporting_aggregate_tables.sql
\ir 5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql
\ir 5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql
\ir 1100_security/1111_role_ownership_separation.sql
\ir 5000_function/5100_admin/5140_users.sql
\ir 5000_function/5100_admin/5150_audit.sql
\ir 1100_security/1112_admin_execute_only.sql

\ir 1200_validation/1211_security_validation.sql
\ir 1200_validation/1212_integrity_validation.sql
\ir 1200_validation/1214_extended_architecture_validation.sql
\ir 1200_validation/1215_security_contract_validation.sql
\ir 1200_validation/1216_adversarial_authorization_validation.sql
\ir 1200_validation/1217_pgbouncer_transaction_context_validation.sql
\ir 1200_validation/1218_api_surface_validation.sql
\ir 1200_validation/1219_migration_framework_validation.sql
\ir 1200_validation/1220_financial_readiness_validation.sql
\ir 1200_validation/1221_operational_integrity_validation.sql
\ir 1200_validation/1222_role_separation_validation.sql
\ir 1200_validation/1223_admin_catalog_lifecycle_validation.sql
\ir 1200_validation/1224_system_summary_validation.sql
\ir 1200_validation/1225_aggregate_tables_validation.sql
\ir 1200_validation/1226_set_manifest_enrichment_validation.sql
\ir 1200_validation/1227_api_v3_validation.sql

\ir 5000_function/5900_tests/5900_test_app_lifecycle.sql
\ir 5000_function/5900_tests/5901_test_identity_lifecycle.sql
\ir 5000_function/5900_tests/5902_test_reference_lifecycle.sql
\ir 5000_function/5900_tests/5903_test_catalog_lifecycle.sql
\ir 5000_function/5900_tests/5904_test_definition_lifecycle.sql
\ir 5000_function/5900_tests/5905_test_collection_lifecycle.sql
\ir 5000_function/5900_tests/5906_test_wanted_lifecycle.sql
\ir 5000_function/5900_tests/5907_test_moc_lifecycle.sql
\ir 5000_function/5900_tests/5908_test_audit_lifecycle.sql
\ir 5000_function/5900_tests/5909_test_import_lifecycle.sql
\ir 5000_function/5900_tests/5910_test_api_lifecycle.sql
\ir 5000_function/5900_tests/5911_test_admin_lifecycle.sql
\ir 5000_function/5900_tests/5912_test_finance_lifecycle.sql
\ir 5000_function/5900_tests/5913_test_reporting_lifecycle.sql
\ir 5000_function/5900_tests/5914_test_api_v3.sql
\ir 1200_validation/1213_dependency_validation.sql
