@echo off
setlocal

rem Create master.schema directory structure and empty SQL files

set "ROOT=master.schema"

mkdir "%ROOT%\00_bootstrap"
mkdir "%ROOT%\10_identity"
mkdir "%ROOT%\20_reference"
mkdir "%ROOT%\30_catalog"
mkdir "%ROOT%\40_definitions"
mkdir "%ROOT%\50_collections"
mkdir "%ROOT%\60_wanted"
mkdir "%ROOT%\70_mocs"
mkdir "%ROOT%\80_imports"
mkdir "%ROOT%\90_audit"
mkdir "%ROOT%\100_logic"
mkdir "%ROOT%\110_security"
mkdir "%ROOT%\120_validation"

rem 00_bootstrap
type nul > "%ROOT%\00_bootstrap\00_extensions.sql"
type nul > "%ROOT%\00_bootstrap\01_schemas.sql"
type nul > "%ROOT%\00_bootstrap\02_types.sql"
type nul > "%ROOT%\00_bootstrap\03_uuid.sql"

rem 10_identity
type nul > "%ROOT%\10_identity\10_users.sql"
type nul > "%ROOT%\10_identity\11_families.sql"
type nul > "%ROOT%\10_identity\12_family_memberships.sql"
type nul > "%ROOT%\10_identity\13_guardianships.sql"
type nul > "%ROOT%\10_identity\14_owners.sql"

rem 20_reference
type nul > "%ROOT%\20_reference\20_external_sources.sql"
type nul > "%ROOT%\20_reference\21_colors.sql"
type nul > "%ROOT%\20_reference\22_themes.sql"
type nul > "%ROOT%\20_reference\23_categories.sql"
type nul > "%ROOT%\20_reference\24_minifig_roles.sql"

rem 30_catalog
type nul > "%ROOT%\30_catalog\30_catalog_items.sql"
type nul > "%ROOT%\30_catalog\31_sets.sql"
type nul > "%ROOT%\30_catalog\32_part_designs.sql"
type nul > "%ROOT%\30_catalog\33_part_variants.sql"
type nul > "%ROOT%\30_catalog\34_lego_elements.sql"
type nul > "%ROOT%\30_catalog\35_minifigures.sql"
type nul > "%ROOT%\30_catalog\36_books.sql"
type nul > "%ROOT%\30_catalog\37_external_identifiers.sql"
type nul > "%ROOT%\30_catalog\38_catalog_overrides.sql"

rem 40_definitions
type nul > "%ROOT%\40_definitions\40_inventory_definitions.sql"
type nul > "%ROOT%\40_definitions\41_inventory_versions.sql"
type nul > "%ROOT%\40_definitions\42_requirement_groups.sql"
type nul > "%ROOT%\40_definitions\43_requirement_options.sql"
type nul > "%ROOT%\40_definitions\44_definition_authority.sql"

rem 50_collections
type nul > "%ROOT%\50_collections\50_storage_locations.sql"
type nul > "%ROOT%\50_collections\51_collection_entries.sql"
type nul > "%ROOT%\50_collections\52_collection_instances.sql"
type nul > "%ROOT%\50_collections\53_instance_adjustments.sql"
type nul > "%ROOT%\50_collections\54_storage_allocations.sql"
type nul > "%ROOT%\50_collections\55_allocations.sql"
type nul > "%ROOT%\50_collections\56_transfers.sql"

rem 60_wanted
type nul > "%ROOT%\60_wanted\60_wishlists.sql"
type nul > "%ROOT%\60_wanted\61_wishlist_entries.sql"
type nul > "%ROOT%\60_wanted\62_wishlist_reservations.sql"
type nul > "%ROOT%\60_wanted\63_build_goals.sql"
type nul > "%ROOT%\60_wanted\64_build_allocations.sql"

rem 70_mocs
type nul > "%ROOT%\70_mocs\70_mocs.sql"
type nul > "%ROOT%\70_mocs\71_moc_revisions.sql"
type nul > "%ROOT%\70_mocs\72_moc_forks.sql"
type nul > "%ROOT%\70_mocs\73_moc_subassemblies.sql"
type nul > "%ROOT%\70_mocs\74_moc_licenses.sql"
type nul > "%ROOT%\70_mocs\75_moc_assets.sql"

rem 80_imports
type nul > "%ROOT%\80_imports\80_import_jobs.sql"
type nul > "%ROOT%\80_imports\81_source_runs.sql"
type nul > "%ROOT%\80_imports\82_source_run_datasets.sql"
type nul > "%ROOT%\80_imports\83_raw_records.sql"
type nul > "%ROOT%\80_imports\84_normalized_records.sql"
type nul > "%ROOT%\80_imports\85_import_matches.sql"
type nul > "%ROOT%\80_imports\86_user_mapping_suggestions.sql"
type nul > "%ROOT%\80_imports\87_import_applications.sql"

rem 90_audit
type nul > "%ROOT%\90_audit\90_audit_events.sql"
type nul > "%ROOT%\90_audit\91_audit_changes.sql"

rem 100_logic
type nul > "%ROOT%\100_logic\100_identity_functions.sql"
type nul > "%ROOT%\100_logic\101_definition_functions.sql"
type nul > "%ROOT%\100_logic\102_collection_functions.sql"
type nul > "%ROOT%\100_logic\103_wanted_functions.sql"
type nul > "%ROOT%\100_logic\104_import_functions.sql"
type nul > "%ROOT%\100_logic\105_audit_functions.sql"
type nul > "%ROOT%\100_logic\106_triggers.sql"

rem 110_security
type nul > "%ROOT%\110_security\110_roles.sql"
type nul > "%ROOT%\110_security\111_rls_identity.sql"
type nul > "%ROOT%\110_security\112_rls_collections.sql"
type nul > "%ROOT%\110_security\113_rls_wanted.sql"
type nul > "%ROOT%\110_security\114_rls_mocs.sql"
type nul > "%ROOT%\110_security\115_grants.sql"

rem 120_validation
type nul > "%ROOT%\120_validation\120_bootstrap_validation.sql"
type nul > "%ROOT%\120_validation\121_identity_validation.sql"
type nul > "%ROOT%\120_validation\122_catalog_validation.sql"
type nul > "%ROOT%\120_validation\123_definition_validation.sql"
type nul > "%ROOT%\120_validation\124_import_validation.sql"

rem Root bootstrap file
type nul > "%ROOT%\bootstrap.sql"

echo.
echo master.schema structure created successfully.
echo Location: "%CD%\%ROOT%"
echo.

endlocal