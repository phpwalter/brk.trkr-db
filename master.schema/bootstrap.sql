/*
===============================================================================
 File:           bootstrap.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
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
                 - database roles, grants, and row-level security
 Key Rules:      Files execute in deterministic dependency order.
                 All file and directory prefixes use four digits.
                 \set ON_ERROR_STOP prevents execution from continuing after
                 the first SQL error.
                 Schema construction is optimized for a fresh database rather
                 than migration or repeated-bootstrap semantics.
                 Core schema construction executes inside one deployment
                 transaction so failed validation rolls back the installation.
                 Deployment validation is separate from runtime constraints;
                 both are required.
                 Domain validation runs after the corresponding base objects are
                 installed.
                 Runtime function validation runs only after all functions and
                 triggers have been installed.
                 Security validation runs only after roles, policies, and grants
                 have been installed.
                 Nightly source synchronization does not use this deployment
                 transaction model; runtime imports use their own bounded
                 transactions and finalization rules.
 Validation:     Executes the complete 1200_validation family:
                 1200_bootstrap_validation.sql
                 1201_identity_validation.sql
                 1202_reference_validation.sql
                 1203_catalog_validation.sql
                 1204_definition_validation.sql
                 1205_collection_validation.sql
                 1206_wanted_validation.sql
                 1207_moc_validation.sql
                 1208_import_validation.sql
                 1209_audit_validation.sql
                 1210_function_validation.sql
                 1211_security_validation.sql
                 1212_integrity_validation.sql
                 1214_extended_architecture_validation.sql
                 1215_security_contract_validation.sql
                 1216_adversarial_authorization_validation.sql
                 1217_pgbouncer_transaction_context_validation.sql
                 1218_api_surface_validation.sql
                 1219_migration_framework_validation.sql
                 1220_financial_readiness_validation.sql
                 1221_operational_integrity_validation.sql
                 1213_dependency_validation.sql
                 Any failed assertion aborts the bootstrap transaction.
===============================================================================
*/

\set ON_ERROR_STOP on
\set VERBOSITY verbose

\echo ''
\echo '==============================================================================='
\echo ' LEGO Collection Platform'
\echo ' PostgreSQL Schema Bootstrap'
\echo '==============================================================================='
\echo ''

\echo '[BOOTSTRAP] Beginning schema installation...'
\echo ''


/* =============================================================================
 * TRANSACTION
 * =============================================================================
 *
 * This transaction covers schema deployment only.
 *
 * It does NOT imply that production source synchronization, collection imports,
 * or other long-running operational workflows should execute as one large
 * transaction.
 * ========================================================================== */

\echo '[PRECHECK] Installing generated dependency gate...'
\ir 0000_bootstrap/0000_dependency_preflight.sql

BEGIN;


/* =============================================================================
 * 0000 - BOOTSTRAP INFRASTRUCTURE
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0000] Bootstrap infrastructure'
\echo '-------------------------------------------------------------------------------'

\echo '[0000] Installing required extensions...'
\ir 0000_bootstrap/0000_extensions.sql

\echo '[0001] Creating application schemas...'
\ir 0000_bootstrap/0001_schemas.sql

\echo '[0002] Creating shared scalar domains...'
\ir 0000_bootstrap/0002_types.sql

\echo '[0003] Installing UUIDv7 generator...'
\ir 0000_bootstrap/0003_uuid.sql

\echo '[0004] Installing validation helpers...'
\ir 0000_bootstrap/0004_validation_helpers.sql

\echo '[0005] Installing forward-only migration framework...'
\ir 0000_bootstrap/0005_migration_framework.sql

\echo '[1200] Validating bootstrap infrastructure...'
\ir 1200_validation/1200_bootstrap_validation.sql

\echo '[0000] Bootstrap infrastructure complete.'


/* =============================================================================
 * 0100 - IDENTITY
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0100] Identity and authentication'
\echo '-------------------------------------------------------------------------------'

\echo '[0100] Creating users...'
\ir 0100_identity/0100_users.sql

\echo '[0101] Creating authentication structures...'
\ir 0100_identity/0101_authentication.sql

\echo '[0102] Creating families...'
\ir 0100_identity/0102_families.sql

\echo '[0103] Creating family memberships...'
\ir 0100_identity/0103_family_memberships.sql

\echo '[0104] Creating family permissions...'
\ir 0100_identity/0104_family_permissions.sql

\echo '[0105] Creating guardianships...'
\ir 0100_identity/0105_guardianships.sql

\echo '[0106] Creating ownership principals...'
\ir 0100_identity/0106_owners.sql

\echo '[1201] Validating identity domain...'
\ir 1200_validation/1201_identity_validation.sql

\echo '[0100] Identity domain complete.'


/* =============================================================================
 * 0200 - REFERENCE DATA
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0200] Reference data'
\echo '-------------------------------------------------------------------------------'

\echo '[0200] Creating external source registry...'
\ir 0200_reference/0200_external_sources.sql

\echo '[0201] Creating canonical colors...'
\ir 0200_reference/0201_colors.sql

\echo '[0202] Creating themes...'
\ir 0200_reference/0202_themes.sql

\echo '[0203] Creating classification categories...'
\ir 0200_reference/0203_categories.sql

\echo '[0204] Creating minifigure component roles...'
\ir 0200_reference/0204_minifig_roles.sql

\echo '[1202] Validating reference domain...'
\ir 1200_validation/1202_reference_validation.sql

\echo '[0200] Reference domain complete.'


/* =============================================================================
 * 0300 - CATALOG
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0300] Canonical catalog'
\echo '-------------------------------------------------------------------------------'

\echo '[0300] Creating catalog root items...'
\ir 0300_catalog/0300_catalog_items.sql

\echo '[0301] Creating SET catalog subtype...'
\ir 0300_catalog/0301_catalog_sets.sql

\echo '[0302] Creating PART catalog subtype...'
\ir 0300_catalog/0302_catalog_parts.sql

\echo '[0303] Creating MINIFIGURE catalog subtype...'
\ir 0300_catalog/0303_catalog_minifigures.sql

\echo '[0304] Creating BOOK catalog subtype...'
\ir 0300_catalog/0304_catalog_books.sql

\echo '[0305] Creating MOC catalog subtype...'
\ir 0300_catalog/0305_catalog_mocs.sql

\echo '[0306] Creating STICKER_SHEET catalog subtype...'
\ir 0300_catalog/0306_catalog_sticker_sheets.sql

\echo '[0307] Creating INSTRUCTIONS catalog subtype...'
\ir 0300_catalog/0307_catalog_instructions.sql

\echo '[0308] Creating PACKAGING catalog subtype...'
\ir 0300_catalog/0308_catalog_packaging.sql

\echo '[0309] Creating GEAR catalog subtype...'
\ir 0300_catalog/0309_catalog_gear.sql

\echo '[0310] Creating ACCESSORY catalog subtype...'
\ir 0300_catalog/0310_catalog_accessories.sql

\echo '[0311] Creating POLYBAG catalog subtype...'
\ir 0300_catalog/0311_catalog_polybags.sql

\echo '[0312] Creating PROMOTIONAL_ITEM catalog subtype...'
\ir 0300_catalog/0312_catalog_promotional_items.sql

\echo '[0313] Creating PUBLICATION catalog subtype...'
\ir 0300_catalog/0313_catalog_publications.sql

\echo '[0314] Creating OTHER catalog subtype...'
\ir 0300_catalog/0314_catalog_other.sql

\echo '[0315] Creating part variants...'
\ir 0300_catalog/0315_part_variants.sql

\echo '[0316] Creating LEGO element identity history...'
\ir 0300_catalog/0316_lego_elements.sql

\echo '[0317] Creating external identifier mappings...'
\ir 0300_catalog/0317_external_identifiers.sql

\echo '[0318] Creating catalog source authority and admin overrides...'
\ir 0300_catalog/0318_catalog_authority.sql
\ir 0300_catalog/0319_part_tooling.sql
\ir 0300_catalog/0320_catalog_search_media.sql

\echo '[1203] Validating catalog domain...'
\ir 1200_validation/1203_catalog_validation.sql

\echo '[0300] Catalog domain complete.'


/* =============================================================================
 * 0400 - VERSIONED DEFINITIONS
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0400] Inventory definitions and semantic versions'
\echo '-------------------------------------------------------------------------------'

\echo '[0400] Creating inventory definitions...'
\ir 0400_definitions/0400_inventory_definitions.sql

\echo '[0401] Creating inventory semantic versions...'
\ir 0400_definitions/0401_inventory_versions.sql

\echo '[0402] Creating requirement groups...'
\ir 0400_definitions/0402_requirement_groups.sql

\echo '[0403] Creating requirement options...'
\ir 0400_definitions/0403_requirement_options.sql

\echo '[0404] Creating definition authority state...'
\ir 0400_definitions/0404_definition_authority.sql
\ir 0400_definitions/0405_manifest_graph.sql
\ir 0400_definitions/0406_minifig_compositions.sql

\echo '[1204] Validating definition domain...'
\ir 1200_validation/1204_definition_validation.sql

\echo '[0400] Definition domain complete.'


/* =============================================================================
 * 0500 - COLLECTIONS
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0500] Collections and physical ownership'
\echo '-------------------------------------------------------------------------------'

\echo '[0500] Creating storage locations...'
\ir 0500_collections/0500_storage_locations.sql

\echo '[0501] Creating collection entries...'
\ir 0500_collections/0501_collection_entries.sql

\echo '[0502] Creating physical collection instances...'
\ir 0500_collections/0502_collection_instances.sql

\echo '[0503] Creating instance manifest adjustments...'
\ir 0500_collections/0503_instance_adjustments.sql

\echo '[0504] Creating storage allocations...'
\ir 0500_collections/0504_storage_allocations.sql

\echo '[0505] Creating ownership transfers...'
\ir 0500_collections/0505_transfers.sql

\echo '[0506] Creating acquisition provenance...'
\ir 0500_collections/0506_acquisitions.sql

\echo '[0507] Creating owner-scoped collection tags...'
\ir 0500_collections/0507_tags.sql

\echo '[1205] Validating collection domain...'
\ir 1200_validation/1205_collection_validation.sql

\echo '[0500] Collection domain complete.'


/* =============================================================================
 * 0600 - WANTED / GOALS
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0600] Wishlists and build goals'
\echo '-------------------------------------------------------------------------------'

\echo '[0600] Creating wishlists...'
\ir 0600_wanted/0600_wishlists.sql

\echo '[0601] Creating wishlist entries...'
\ir 0600_wanted/0601_wishlist_entries.sql

\echo '[0602] Creating hidden gift reservations...'
\ir 0600_wanted/0602_wishlist_reservations.sql

\echo '[0603] Creating build and completion goals...'
\ir 0600_wanted/0603_build_goals.sql

\echo '[0604] Creating build allocations...'
\ir 0600_wanted/0604_build_allocations.sql

\echo '[1206] Validating wanted/build-goal domain...'
\ir 1200_validation/1206_wanted_validation.sql

\echo '[0600] Wanted/build-goal domain complete.'


/* =============================================================================
 * 0700 - MOCS
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0700] MOCs'
\echo '-------------------------------------------------------------------------------'

\echo '[0700] Creating MOC identities...'
\ir 0700_mocs/0700_mocs.sql

\echo '[0701] Creating MOC revisions...'
\ir 0700_mocs/0701_moc_revisions.sql

\echo '[0702] Creating MOC fork ancestry...'
\ir 0700_mocs/0702_moc_forks.sql

\echo '[0703] Creating MOC subassemblies...'
\ir 0700_mocs/0703_moc_subassemblies.sql

\echo '[0704] Creating MOC licensing...'
\ir 0700_mocs/0704_moc_licenses.sql

\echo '[0705] Creating MOC asset metadata...'
\ir 0700_mocs/0705_moc_assets.sql

\echo '[1207] Validating MOC domain...'
\ir 1200_validation/1207_moc_validation.sql

\echo '[0750] Installing marketplace and financial domains...'
\ir 0750_marketplace/0750_market_prices.sql
\ir 0750_marketplace/0751_marketplace.sql
\ir 0760_finance/0760_financial_ledger.sql
\ir 0760_finance/0761_financial_readiness_anchors.sql

\echo '[0700] MOC domain complete.'


/* =============================================================================
 * 0800 - IMPORTS AND AUTHORITATIVE SOURCE RUNS
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0800] Imports and authoritative source synchronization'
\echo '-------------------------------------------------------------------------------'

\echo '[0800] Creating user import jobs...'
\ir 0800_imports/0800_import_jobs.sql

\echo '[0801] Creating authoritative source runs...'
\ir 0800_imports/0801_source_runs.sql

\echo '[0802] Creating raw and source-run staging...'
\ir 0800_imports/0802_raw_staging.sql

\echo '[0803] Creating source-run dataset completion records...'
\ir 0800_imports/0803_source_run_datasets.sql

\echo '[0804] Creating normalized user-import records...'
\ir 0800_imports/0804_normalized_records.sql

\echo '[0805] Creating import candidate matches...'
\ir 0800_imports/0805_import_matches.sql

\echo '[0806] Creating user mapping suggestions...'
\ir 0800_imports/0806_user_mapping_suggestions.sql

\echo '[0807] Creating reversible import applications...'
\ir 0800_imports/0807_import_applications.sql

\echo '[1208] Validating import domain...'
\ir 1200_validation/1208_import_validation.sql

\echo '[0850] Installing operations domain...'
\ir 0850_operations/0850_jobs_notifications.sql

\echo '[0800] Import domain complete.'


/* =============================================================================
 * 0900 - AUDIT
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[0900] Audit history'
\echo '-------------------------------------------------------------------------------'

\echo '[0900] Creating audit events...'
\ir 0900_audit/0900_audit_events.sql

\echo '[0901] Creating audit field changes...'
\ir 0900_audit/0901_audit_changes.sql

\echo '[1209] Validating audit domain...'
\ir 1200_validation/1209_audit_validation.sql

\echo '[0900] Audit domain complete.'


/* =============================================================================
 * 1000 - FUNCTIONS AND RUNTIME INVARIANTS
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[1000] Runtime functions and invariant triggers'
\echo '-------------------------------------------------------------------------------'

\echo '[1000] Installing identity functions and guardianship validation...'
\ir 1000_function/1000_identity_function.sql

\echo '[1001] Installing hierarchy validation functions...'
\ir 1000_function/1001_hierarchy_function.sql

\echo '[1002] Installing catalog subtype functions...'
\ir 1000_function/1002_catalog_function.sql

\echo '[1003] Installing definition/version functions...'
\ir 1000_function/1003_definition_function.sql

\echo '[1004] Installing collection functions...'
\ir 1000_function/1004_collection_function.sql

\echo '[1005] Installing wishlist/build-goal functions...'
\ir 1000_function/1005_wanted_function.sql

\echo '[1006] Installing MOC functions...'
\ir 1000_function/1006_moc_function.sql

\echo '[1007] Installing import/source-run functions and late-bound source FKs...'
\ir 1000_function/1007_import_function.sql

\echo '[1008] Installing audit functions and audit triggers...'
\ir 1000_function/1008_audit_function.sql

\echo '[1009] Installing cross-domain integrity hardening...'
\ir 1000_function/1009_integrity_hardening.sql

\echo '[1010] Installing exact-ID MOC access functions...'
\ir 1000_function/1010_moc_access_function.sql
\ir 1000_function/1011_request_context.sql
\ir 1000_function/1012_graph_function.sql
\ir 1000_function/1013_operational_api.sql
\ir 1000_function/1014_finance_function.sql

\echo '[1015] Installing Rebrickable reference reconciliation...'
\ir 1000_function/1015_rebrickable_reference_reconcile.sql

\echo '[1016] Installing Rebrickable catalog reconciliation...'
\ir 1000_function/1016_rebrickable_catalog_reconcile.sql

\echo '[1210] Validating functions and runtime triggers...'
\ir 1200_validation/1210_function_validation.sql

\echo '[1050] Installing reporting views...'
\ir 1050_reporting/1050_reporting_views.sql

\echo '[1000] Function domain complete.'


/* =============================================================================
 * 1100 - SECURITY
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[1100] Roles, row-level security, and grants'
\echo '-------------------------------------------------------------------------------'

\echo '[1100] Creating database roles...'
\ir 1100_security/1100_roles.sql

\echo '[1101] Installing identity RLS policies...'
\ir 1100_security/1101_rls_identity.sql

\echo '[1102] Installing collection RLS policies...'
\ir 1100_security/1102_rls_collections.sql

\echo '[1103] Installing wishlist/build-goal RLS policies...'
\ir 1100_security/1103_rls_wanted.sql

\echo '[1104] Installing MOC RLS policies...'
\ir 1100_security/1104_rls_mocs.sql

\echo '[1105] Installing import RLS policies...'
\ir 1100_security/1105_rls_imports.sql

\echo '[1106] Installing audit RLS protections...'
\ir 1100_security/1106_rls_audit.sql

\echo '[1108] Protecting private catalog and definition graphs...'
\ir 1100_security/1108_rls_catalog_definition.sql

\echo '[1109] Installing extended-domain RLS policies...'
\ir 1100_security/1109_rls_extended.sql

\echo '[1107] Applying database privileges and grants...'
\ir 1100_security/1107_grants.sql

\echo '[1110] Locking down runtime API surface...'
\ir 1100_security/1110_api_surface_lockdown.sql

\echo '[1111] Separating runtime/admin/deployment ownership...'
\ir 1100_security/1111_role_ownership_separation.sql

\echo '[1211] Validating security configuration...'
\ir 1200_validation/1211_security_validation.sql

\echo '[1212] Validating cross-domain hardening...'
\ir 1200_validation/1212_integrity_validation.sql
\ir 1200_validation/1214_extended_architecture_validation.sql
\ir 1200_validation/1215_security_contract_validation.sql
\ir 1200_validation/1216_adversarial_authorization_validation.sql
\ir 1200_validation/1217_pgbouncer_transaction_context_validation.sql
\ir 1200_validation/1218_api_surface_validation.sql
\echo '[1219] Validating migration framework...'
\ir 1200_validation/1219_migration_framework_validation.sql
\echo '[1220] Validating financial readiness invariants...'
\ir 1200_validation/1220_financial_readiness_validation.sql
\echo '[1221] Validating operational integrity and critical indexes...'
\ir 1200_validation/1221_operational_integrity_validation.sql
\echo '[1222] Validating role and ownership separation...'
\ir 1200_validation/1222_role_separation_validation.sql
\ir 1200_validation/1213_dependency_validation.sql

\echo '[1100] Security domain complete.'


/* =============================================================================
 * FINAL DEPLOYMENT CHECK
 * =============================================================================
 *
 * Domain validators have already executed throughout installation.
 *
 * Run the most important structural validators once more after all functions,
 * late-bound foreign keys, RLS policies, and grants exist.  These checks are
 * read-only and therefore safe to repeat within this deployment transaction.
 * ========================================================================== */

\echo ''
\echo '-------------------------------------------------------------------------------'
\echo '[FINAL] Running final cross-domain validation'
\echo '-------------------------------------------------------------------------------'

\ir 1200_validation/1200_bootstrap_validation.sql
\ir 1200_validation/1201_identity_validation.sql
\ir 1200_validation/1202_reference_validation.sql
\ir 1200_validation/1203_catalog_validation.sql
\ir 1200_validation/1204_definition_validation.sql
\ir 1200_validation/1205_collection_validation.sql
\ir 1200_validation/1206_wanted_validation.sql
\ir 1200_validation/1207_moc_validation.sql
\ir 1200_validation/1208_import_validation.sql
\ir 1200_validation/1209_audit_validation.sql
\ir 1200_validation/1210_function_validation.sql
\ir 1200_validation/1211_security_validation.sql
\ir 1200_validation/1212_integrity_validation.sql
\ir 1200_validation/1214_extended_architecture_validation.sql
\ir 1200_validation/1215_security_contract_validation.sql
\echo '[1216] Running adversarial authorization tests...'
\ir 1200_validation/1216_adversarial_authorization_validation.sql
\echo '[1217] Validating PgBouncer transaction context...'
\ir 1200_validation/1217_pgbouncer_transaction_context_validation.sql
\echo '[1218] Validating runtime API surface...'
\ir 1200_validation/1218_api_surface_validation.sql
\echo '[1219] Validating migration framework...'
\ir 1200_validation/1219_migration_framework_validation.sql
\echo '[1220] Validating financial readiness invariants...'
\ir 1200_validation/1220_financial_readiness_validation.sql
\echo '[1221] Validating operational integrity and critical indexes...'
\ir 1200_validation/1221_operational_integrity_validation.sql
\echo '[1222] Validating role and ownership separation...'
\ir 1200_validation/1222_role_separation_validation.sql

\ir 1200_validation/1213_dependency_validation.sql

\echo '[FINAL] Cross-domain validation passed.'


/* =============================================================================
 * COMMIT
 * ========================================================================== */

COMMIT;


/* =============================================================================
 * SUCCESS
 * ========================================================================== */

\echo ''
\echo '==============================================================================='
\echo ' SUCCESS'
\echo '==============================================================================='
\echo ' LEGO Collection Platform schema installation completed successfully.'
\echo ''
\echo ' Installed domains:'
\echo '   [0000] Bootstrap infrastructure'
\echo '   [0100] Identity and authentication'
\echo '   [0200] Reference data'
\echo '   [0300] Canonical catalog'
\echo '   [0400] Inventory definitions'
\echo '   [0500] Collections'
\echo '   [0600] Wishlists and build goals'
\echo '   [0700] MOCs'
\echo '   [0800] Imports and source runs'
\echo '   [0900] Audit'
\echo '   [1000] Runtime functions'
\echo '   [1100] Security'
\echo ''
\echo ' All 1200_validation checks passed.'
\echo '==============================================================================='
\echo ''