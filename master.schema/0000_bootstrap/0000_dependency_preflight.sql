/*
===============================================================================
 File:           0000_bootstrap/0000_dependency_preflight.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Establish a session-local dependency manifest and preflight gate
                 used by every subsequent schema file before executable DDL.
 Depends On:     PostgreSQL 16+
 Creates:        pg_temp.bt_expected_files
                 pg_temp.bt_completed_files
                 pg_temp.bt_file_preflights
                 pg_temp.bt_dependency_checks
                 pg_temp.bt_preflight(...)
                 pg_temp.bt_mark_completed(...)
===============================================================================
*/
\set ON_ERROR_STOP on

DO $$
BEGIN
    IF current_setting('server_version_num')::integer < 160000 THEN
        RAISE EXCEPTION 'BrickTrackr requires PostgreSQL 16 or later; server_version_num=%',
            current_setting('server_version_num');
    END IF;
END;
$$;

CREATE TEMP TABLE bt_expected_files (
    ordinal integer PRIMARY KEY,
    file_path text NOT NULL UNIQUE,
    dependencies text[] NOT NULL
) ON COMMIT PRESERVE ROWS;

CREATE TEMP TABLE bt_completed_files (
    file_path text PRIMARY KEY,
    completed_at timestamptz NOT NULL DEFAULT clock_timestamp()
) ON COMMIT PRESERVE ROWS;

CREATE TEMP TABLE bt_file_preflights (
    file_path text PRIMARY KEY,
    checked_at timestamptz NOT NULL DEFAULT clock_timestamp()
) ON COMMIT PRESERVE ROWS;

CREATE TEMP TABLE bt_dependency_checks (
    file_path text NOT NULL,
    dependency text NOT NULL,
    satisfied boolean NOT NULL,
    checked_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (file_path, dependency)
) ON COMMIT PRESERVE ROWS;

INSERT INTO pg_temp.bt_expected_files(ordinal,file_path,dependencies)
VALUES
    (1, '0000_bootstrap/0000_dependency_preflight.sql', ARRAY['PostgreSQL 16+']::text[]),
    (2, '0000_bootstrap/0000_extensions.sql', ARRAY['PostgreSQL extension installation privileges']::text[]),
    (3, '0000_bootstrap/0001_schemas.sql', ARRAY['0000_bootstrap/0000_extensions.sql']::text[]),
    (4, '0000_bootstrap/0002_types.sql', ARRAY['app schema']::text[]),
    (5, '0000_bootstrap/0003_uuid.sql', ARRAY['app schema', 'pgcrypto']::text[]),
    (6, '0000_bootstrap/0004_validation_helpers.sql', ARRAY['app schema']::text[]),
    (7, '0000_bootstrap/0005_migration_framework.sql', ARRAY['0000_bootstrap/0004_validation_helpers.sql', 'app schema']::text[]),
    (8, '1200_validation/1200_bootstrap_validation.sql', ARRAY['0000_bootstrap/0000_extensions.sql', '0000_bootstrap/0001_schemas.sql', '0000_bootstrap/0002_types.sql', '0000_bootstrap/0003_uuid.sql', '0000_bootstrap/0004_validation_helpers.sql', '0000_bootstrap/0005_migration_framework.sql']::text[]),
    (9, '0100_identity/0100_users.sql', ARRAY['app.uuid_v7()', 'citext']::text[]),
    (10, '0100_identity/0101_authentication.sql', ARRAY['identity.users', 'app.sha256_digest']::text[]),
    (11, '0100_identity/0102_families.sql', ARRAY['identity.users']::text[]),
    (12, '0100_identity/0103_family_memberships.sql', ARRAY['identity.users', 'identity.families']::text[]),
    (13, '0100_identity/0104_family_permissions.sql', ARRAY['identity.users', 'identity.families', 'identity.family_memberships']::text[]),
    (14, '0100_identity/0105_guardianships.sql', ARRAY['identity.users', 'identity.families']::text[]),
    (15, '0100_identity/0106_owners.sql', ARRAY['app.uuid_v7()', 'identity.users', 'identity.families']::text[]),
    (16, '1200_validation/1201_identity_validation.sql', ARRAY['Complete 0100_identity domain']::text[]),
    (17, '0200_reference/0200_external_sources.sql', ARRAY['reference schema']::text[]),
    (18, '0200_reference/0201_colors.sql', ARRAY['reference.external_sources']::text[]),
    (19, '0200_reference/0202_themes.sql', ARRAY['reference.external_sources']::text[]),
    (20, '0200_reference/0203_categories.sql', ARRAY['reference.external_sources']::text[]),
    (21, '0200_reference/0204_minifig_roles.sql', ARRAY['reference schema']::text[]),
    (22, '1200_validation/1202_reference_validation.sql', ARRAY['0200_reference/0200_external_sources.sql', '0200_reference/0201_colors.sql', '0200_reference/0202_themes.sql', '0200_reference/0203_categories.sql', '0200_reference/0204_minifig_roles.sql']::text[]),
    (23, '0300_catalog/0300_catalog_items.sql', ARRAY['identity.owners']::text[]),
    (24, '0300_catalog/0301_catalog_sets.sql', ARRAY['catalog.items', 'reference.themes']::text[]),
    (25, '0300_catalog/0302_catalog_parts.sql', ARRAY['catalog.items', 'reference.categories']::text[]),
    (26, '0300_catalog/0303_catalog_minifigures.sql', ARRAY['catalog.items', 'reference.themes']::text[]),
    (27, '0300_catalog/0304_catalog_books.sql', ARRAY['catalog.items']::text[]),
    (28, '0300_catalog/0305_catalog_mocs.sql', ARRAY['catalog.items']::text[]),
    (29, '0300_catalog/0306_catalog_sticker_sheets.sql', ARRAY['catalog.items']::text[]),
    (30, '0300_catalog/0307_catalog_instructions.sql', ARRAY['catalog.items']::text[]),
    (31, '0300_catalog/0308_catalog_packaging.sql', ARRAY['catalog.items']::text[]),
    (32, '0300_catalog/0309_catalog_gear.sql', ARRAY['catalog.items', 'reference.categories']::text[]),
    (33, '0300_catalog/0310_catalog_accessories.sql', ARRAY['catalog.items']::text[]),
    (34, '0300_catalog/0311_catalog_polybags.sql', ARRAY['catalog.items']::text[]),
    (35, '0300_catalog/0312_catalog_promotional_items.sql', ARRAY['catalog.items']::text[]),
    (36, '0300_catalog/0313_catalog_publications.sql', ARRAY['catalog.items']::text[]),
    (37, '0300_catalog/0314_catalog_other.sql', ARRAY['catalog.items']::text[]),
    (38, '0300_catalog/0315_part_variants.sql', ARRAY['catalog.parts', 'reference.colors']::text[]),
    (39, '0300_catalog/0316_lego_elements.sql', ARRAY['catalog.part_variants']::text[]),
    (40, '0300_catalog/0317_external_identifiers.sql', ARRAY['reference.external_sources', 'catalog.items', 'catalog.part_variants']::text[]),
    (41, '0300_catalog/0318_catalog_authority.sql', ARRAY['catalog.items', 'reference.external_sources', 'identity.users']::text[]),
    (42, '0300_catalog/0319_part_tooling.sql', ARRAY['catalog.parts', 'catalog.part_variants', 'reference.external_sources']::text[]),
    (43, '0300_catalog/0320_catalog_search_media.sql', ARRAY['catalog.items', 'reference.external_sources', 'pg_trgm']::text[]),
    (44, '1200_validation/1203_catalog_validation.sql', ARRAY['Complete 0300_catalog domain']::text[]),
    (45, '0400_definitions/0400_inventory_definitions.sql', ARRAY['catalog.items']::text[]),
    (46, '0400_definitions/0401_inventory_versions.sql', ARRAY['definition.inventory_definitions', 'reference.external_sources', 'identity.users']::text[]),
    (47, '0400_definitions/0402_requirement_groups.sql', ARRAY['definition.inventory_versions']::text[]),
    (48, '0400_definitions/0403_requirement_options.sql', ARRAY['definition.requirement_groups', 'catalog.items', 'catalog.part_variants', 'reference.minifig_roles']::text[]),
    (49, '0400_definitions/0404_definition_authority.sql', ARRAY['definition.inventory_definitions', 'definition.inventory_versions']::text[]),
    (50, '0400_definitions/0405_manifest_graph.sql', ARRAY['definition.inventory_versions', 'definition.requirement_groups']::text[]),
    (51, '0400_definitions/0406_minifig_compositions.sql', ARRAY['definition.inventory_versions', 'catalog.part_variants', 'catalog.decorated_variants', 'reference.minifig_roles']::text[]),
    (52, '0400_definitions/0410_set_manifest_components.sql', ARRAY['0300_catalog/0300_catalog_items.sql', '0000_bootstrap/0003_uuid.sql']::text[]),
    (53, '1200_validation/1204_definition_validation.sql', ARRAY['0400_definitions/0400_inventory_definitions.sql', '0400_definitions/0401_inventory_versions.sql', '0400_definitions/0402_requirement_groups.sql', '0400_definitions/0403_requirement_options.sql', '0400_definitions/0404_definition_authority.sql']::text[]),
    (54, '0500_collections/0500_storage_locations.sql', ARRAY['identity.owners']::text[]),
    (55, '0500_collections/0501_collection_entries.sql', ARRAY['identity.owners', 'catalog.items', 'catalog.part_variants']::text[]),
    (56, '0500_collections/0502_collection_instances.sql', ARRAY['collection.entries', 'definition.inventory_versions']::text[]),
    (57, '0500_collections/0503_instance_adjustments.sql', ARRAY['collection.instances', 'definition.requirement_groups', 'catalog.items', 'catalog.part_variants']::text[]),
    (58, '0500_collections/0504_storage_allocations.sql', ARRAY['collection.entries', 'collection.instances', 'collection.storage_locations']::text[]),
    (59, '0500_collections/0505_transfers.sql', ARRAY['collection.entries', 'identity.owners', 'identity.users']::text[]),
    (60, '0500_collections/0506_acquisitions.sql', ARRAY['identity.owners', 'collection.entries', 'collection.instances', 'app.currency_code', 'app.money_amount']::text[]),
    (61, '0500_collections/0507_tags.sql', ARRAY['identity.owners', 'collection.entries', 'citext']::text[]),
    (62, '1200_validation/1205_collection_validation.sql', ARRAY['Complete 0500_collections domain']::text[]),
    (63, '0600_wanted/0600_wishlists.sql', ARRAY['identity.owners']::text[]),
    (64, '0600_wanted/0601_wishlist_entries.sql', ARRAY['wanted.wishlists', 'catalog.items', 'catalog.part_variants', 'definition.inventory_versions']::text[]),
    (65, '0600_wanted/0602_wishlist_reservations.sql', ARRAY['wanted.wishlist_entries', 'identity.users']::text[]),
    (66, '0600_wanted/0603_build_goals.sql', ARRAY['identity.owners', 'catalog.items', 'definition.inventory_versions', 'collection.instances']::text[]),
    (67, '0600_wanted/0604_build_allocations.sql', ARRAY['wanted.build_goals', 'collection.entries', 'definition.requirement_groups']::text[]),
    (68, '1200_validation/1206_wanted_validation.sql', ARRAY['Complete 0600_wanted domain', 'collection.entries', 'collection.instances', 'definition.inventory_versions']::text[]),
    (69, '0700_mocs/0700_mocs.sql', ARRAY['catalog.mocs', 'identity.owners', 'identity.users']::text[]),
    (70, '0700_mocs/0701_moc_revisions.sql', ARRAY['moc.mocs', 'definition.inventory_versions', 'identity.users']::text[]),
    (71, '0700_mocs/0702_moc_forks.sql', ARRAY['moc.mocs', 'moc.revisions', 'identity.users']::text[]),
    (72, '0700_mocs/0703_moc_subassemblies.sql', ARRAY['moc.revisions']::text[]),
    (73, '0700_mocs/0704_moc_licenses.sql', ARRAY['moc.revisions']::text[]),
    (74, '0700_mocs/0705_moc_assets.sql', ARRAY['moc.revisions', 'app.sha256_digest']::text[]),
    (75, '1200_validation/1207_moc_validation.sql', ARRAY['Complete 0700_mocs domain', 'catalog.mocs', 'definition.inventory_versions']::text[]),
    (76, '0750_marketplace/0750_market_prices.sql', ARRAY['catalog.items', 'catalog.part_variants', 'reference.external_sources', 'app.money_amount']::text[]),
    (77, '0750_marketplace/0751_marketplace.sql', ARRAY['identity.owners', 'identity.users', 'collection.entries', 'marketplace.market_price_observations']::text[]),
    (78, '0760_finance/0760_financial_ledger.sql', ARRAY['identity.owners', 'identity.users', 'marketplace.orders', 'app.money_amount', 'app.idempotency_key', 'app.sha256_digest']::text[]),
    (79, '0760_finance/0761_financial_readiness_anchors.sql', ARRAY['0760_finance/0760_financial_ledger.sql', 'pgcrypto', 'app.idempotency_key', 'app.sha256_digest']::text[]),
    (80, '0800_imports/0800_import_jobs.sql', ARRAY['reference.external_sources', 'identity.owners', 'identity.users']::text[]),
    (81, '0800_imports/0801_source_runs.sql', ARRAY['reference.external_sources']::text[]),
    (82, '0800_imports/0802_raw_staging.sql', ARRAY['import.jobs', 'import.source_runs']::text[]),
    (83, '0800_imports/0803_source_run_datasets.sql', ARRAY['import.source_runs']::text[]),
    (84, '0800_imports/0804_normalized_records.sql', ARRAY['import.jobs', 'import.raw_records']::text[]),
    (85, '0800_imports/0805_import_matches.sql', ARRAY['import.normalized_records', 'catalog.items', 'catalog.part_variants', 'identity.users']::text[]),
    (86, '0800_imports/0806_user_mapping_suggestions.sql', ARRAY['identity.users', 'reference.external_sources', 'catalog.items', 'catalog.part_variants']::text[]),
    (87, '0800_imports/0807_import_applications.sql', ARRAY['import.jobs', 'identity.users']::text[]),
    (88, '1200_validation/1208_import_validation.sql', ARRAY['Complete 0800_imports domain', 'reference.external_sources', 'catalog']::text[]),
    (89, '0850_operations/0850_jobs_notifications.sql', ARRAY['identity.users', 'identity.owners']::text[]),
    (90, '0900_audit/0900_audit_events.sql', ARRAY['identity.users', 'identity.owners', 'import.jobs', 'import.source_runs']::text[]),
    (91, '0900_audit/0901_audit_changes.sql', ARRAY['audit.events']::text[]),
    (92, '1200_validation/1209_audit_validation.sql', ARRAY['0900_audit/0900_audit_events.sql', '0900_audit/0901_audit_changes.sql']::text[]),
    (93, '5000_function/5700_system/5700_system_identity.sql', ARRAY['identity.users', 'identity.families', 'identity.family_memberships', 'identity.family_member_permissions', 'identity.guardianships', 'identity.owners']::text[]),
    (94, '5000_function/5700_system/5701_system_hierarchy.sql', ARRAY['reference.themes', 'reference.categories', 'collection.storage_locations', 'moc.subassemblies']::text[]),
    (95, '5000_function/5700_system/5702_system_catalog.sql', ARRAY['Complete 0300_catalog domain']::text[]),
    (96, '5000_function/5700_system/5703_system_definition.sql', ARRAY['definition.inventory_definitions', 'definition.inventory_versions', 'definition.requirement_groups', 'definition.requirement_options', 'definition.definition_authority']::text[]),
    (97, '5000_function/5700_system/5704_system_collection.sql', ARRAY['collection.entries', 'collection.instances', 'collection.storage_locations', 'collection.storage_allocations', 'wanted.build_allocations']::text[]),
    (98, '5000_function/5700_system/5705_system_wanted.sql', ARRAY['wanted.build_goals', 'definition.requirement_groups', 'definition.requirement_options', 'collection.explicit_part_balance()']::text[]),
    (99, '5000_function/5700_system/5706_system_moc.sql', ARRAY['moc.mocs', 'moc.revisions', 'moc.forks']::text[]),
    (100, '5000_function/5000_importer/5000_importer_common.sql', ARRAY['import.source_runs', 'import.source_run_datasets', 'import.source_stage_records', 'catalog.source_values', 'catalog.source_value_history', 'definition.inventory_versions', 'reference.external_sources']::text[]),
    (101, '5000_function/5700_system/5707_system_audit.sql', ARRAY['audit.events', 'audit.changes', 'identity.current_user_id()', 'Complete 0500_collections domain', 'Complete 0600_wanted domain', 'Complete 0700_mocs domain', 'Complete 0800_imports domain']::text[]),
    (102, '5000_function/5700_system/5708_system_integrity_hardening.sql', ARRAY['identity.users', 'identity.families', 'identity.guardianships', 'reference.themes', 'reference.categories', 'collection.storage_locations', 'collection.entries', 'collection.instances', 'collection.storage_allocations', 'collection.acquisition_items', 'wanted.wishlist_entries', 'wanted.build_goals', 'wanted.build_allocations', 'moc.revisions', 'moc.subassemblies', 'moc.forks', 'import.normalized_records', 'definition.definition_authority']::text[]),
    (103, '5000_function/5200_api/5200_api_moc_access.sql', ARRAY['api schema', 'moc.mocs', 'moc.revisions', 'moc.assets', 'moc.licenses', 'moc.subassemblies', 'identity.current_user_id()']::text[]),
    (112, '5000_function/5700_system/5709_system_request_context.sql', ARRAY['0000_bootstrap/0001_schemas.sql', '0100_identity/0100_users.sql', '1100_security/1100_roles.sql', 'audit.events']::text[]),
    (104, '5000_function/5100_admin/5120_admin_definition_graph.sql', ARRAY['definition.manifest_subassemblies']::text[]),
    (105, '5000_function/5200_api/5210_api_operational.sql', ARRAY['catalog.item_search', 'catalog.items', 'catalog.item_images', 'catalog.instruction_assets', 'operations.notifications', 'collection.transfers', 'collection.entries', 'collection.storage_allocations', 'collection.entry_tags', 'wanted.build_allocations', 'identity.current_user_id()', 'identity.can_manage_owner()']::text[]),
    (106, '5000_function/5100_admin/5130_admin_finance.sql', ARRAY['finance.accounts', 'finance.transactions', 'finance.ledger_entries', 'finance.source_events', 'pgcrypto']::text[]),
    (107, '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', ARRAY['5000_function/5000_importer/5000_importer_common.sql', 'reference.external_sources', 'reference.external_color_mappings', 'reference.external_theme_mappings', 'reference.external_category_mappings', 'reference.colors', 'reference.themes', 'reference.categories']::text[]),
    (108, '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql', ARRAY['5000_function/5000_importer/5000_importer_common.sql', 'catalog.items', 'catalog.parts', 'catalog.sets', 'catalog.minifigures', 'catalog.external_identifiers', 'catalog.source_values', 'catalog.source_value_history', 'reference.external_theme_mappings', 'reference.external_category_mappings', 'reference.external_color_mappings', 'catalog.part_variants', 'catalog.lego_elements', '0300_catalog/0320_catalog_search_media.sql', '0800_imports/0802_raw_staging.sql']::text[]),
    (109, '5000_function/5000_importer/5012_importer_fail_source_run.sql', ARRAY['5000_function/5000_importer/5000_importer_common.sql']::text[]),
    (113, '5000_function/5100_admin/5100_admin_common.sql', ARRAY['5000_function/5700_system/5707_system_audit.sql', '5000_function/5700_system/5709_system_request_context.sql', 'identity.current_user_id()']::text[]),
    (114, '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', 'catalog.items']::text[]),
    (115, '1200_validation/1210_function_validation.sql', ARRAY['5000_function/5700_system/5700_system_identity.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5702_system_catalog.sql', '5000_function/5700_system/5703_system_definition.sql', '5000_function/5700_system/5704_system_collection.sql', '5000_function/5700_system/5705_system_wanted.sql', '5000_function/5700_system/5706_system_moc.sql', '5000_function/5000_importer/5000_importer_common.sql', '5000_function/5700_system/5707_system_audit.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql', '5000_function/5200_api/5200_api_moc_access.sql', '5000_function/5700_system/5709_system_request_context.sql', '5000_function/5100_admin/5120_admin_definition_graph.sql', '5000_function/5200_api/5210_api_operational.sql', '5000_function/5100_admin/5130_admin_finance.sql', '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql', '5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql']::text[]),
    (110, '1000_reporting/1000_reporting_views.sql', ARRAY['catalog.items', 'collection.entries', 'collection.instances', 'wanted.wishlist_entries', 'moc.mocs', 'moc.revisions', 'import.jobs', 'marketplace.listings', 'marketplace.orders', 'finance.transactions', 'operations.notifications']::text[]),
    (111, '1100_security/1100_roles.sql', ARRAY['PostgreSQL role-creation privileges']::text[]),
    (116, '1100_security/1101_rls_identity.sql', ARRAY['identity.user_credentials', 'identity.user_sessions', 'identity.one_time_tokens', 'identity.current_user_id()', 'identity.can_manage_user()']::text[]),
    (117, '1100_security/1102_rls_collections.sql', ARRAY['Complete 0500_collections domain', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]),
    (118, '1100_security/1103_rls_wanted.sql', ARRAY['Complete 0600_wanted domain', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]),
    (119, '1100_security/1104_rls_mocs.sql', ARRAY['Complete 0700_mocs domain', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]),
    (120, '1100_security/1105_rls_imports.sql', ARRAY['Complete 0800_imports domain', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]),
    (121, '1100_security/1106_rls_audit.sql', ARRAY['1100_security/1100_roles.sql', 'audit.events', 'audit.changes']::text[]),
    (122, '1100_security/1108_rls_catalog_definition.sql', ARRAY['Complete 0300_catalog domain', 'Complete 0400_definitions domain', 'identity.current_user_id()', 'identity.can_view_owner()']::text[]),
    (123, '1100_security/1109_rls_extended.sql', ARRAY['marketplace.listings', 'marketplace.orders', 'operations.notifications', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]),
    (124, '1100_security/1107_grants.sql', ARRAY['1100_security/1100_roles.sql', '1100_security/1101_rls_identity.sql', '1100_security/1102_rls_collections.sql', '1100_security/1103_rls_wanted.sql', '1100_security/1104_rls_mocs.sql', '1100_security/1105_rls_imports.sql', '1100_security/1106_rls_audit.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql']::text[]),
    (125, '1100_security/1110_api_surface_lockdown.sql', ARRAY['1100_security/1107_grants.sql', '5000_function/5700_system/5700_system_identity.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5702_system_catalog.sql', '5000_function/5700_system/5703_system_definition.sql', '5000_function/5700_system/5704_system_collection.sql', '5000_function/5700_system/5705_system_wanted.sql', '5000_function/5700_system/5706_system_moc.sql', '5000_function/5000_importer/5000_importer_common.sql', '5000_function/5700_system/5707_system_audit.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql', '5000_function/5200_api/5200_api_moc_access.sql', '5000_function/5700_system/5709_system_request_context.sql', '5000_function/5100_admin/5120_admin_definition_graph.sql', '5000_function/5200_api/5210_api_operational.sql', '5000_function/5100_admin/5130_admin_finance.sql', '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql', '5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql']::text[]),
    (126, '1000_reporting/1010_reporting_system_summary.sql', ARRAY['catalog.items', 'import.source_runs', 'reference.external_sources', '1100_security/1110_api_surface_lockdown.sql']::text[]),
    (127, '1000_reporting/1011_reporting_aggregate_tables.sql', ARRAY['1000_reporting/1010_reporting_system_summary.sql', 'catalog.items', 'identity.owners', 'collection.entries', 'collection.instances', 'wanted.wishlists', 'wanted.wishlist_entries', 'wanted.build_goals', 'import.source_runs', 'import.source_run_steps', 'reference.external_sources']::text[]),
    (128, '5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql', ARRAY['0400_definitions/0410_set_manifest_components.sql', '1100_security/1100_roles.sql', '0300_catalog/0317_external_identifiers.sql', '0300_catalog/0302_catalog_parts.sql', '0300_catalog/0306_catalog_sticker_sheets.sql', '5000_function/5700_system/5702_system_catalog.sql', 'import.source_stage_records', 'reference.categories', 'app.set_import_context(uuid)']::text[]),
    (129, '5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql', ARRAY['0400_definitions/0410_set_manifest_components.sql', '1100_security/1100_roles.sql']::text[]),
    (130, '1100_security/1111_role_ownership_separation.sql', ARRAY['1100_security/1100_roles.sql', '1100_security/1110_api_surface_lockdown.sql']::text[]),
    (131, '5000_function/5100_admin/5140_users.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', '0100_identity/0100_users.sql', '1100_security/1100_roles.sql']::text[]),
    (132, '5000_function/5100_admin/5150_audit.sql', ARRAY['5000_function/5100_admin/5140_users.sql', '0900_audit/0900_audit_events.sql', '0900_audit/0901_audit_changes.sql', '1100_security/1100_roles.sql']::text[]),
    (133, '1100_security/1112_admin_execute_only.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql', '5000_function/5100_admin/5140_users.sql', '5000_function/5100_admin/5150_audit.sql', '1100_security/1111_role_ownership_separation.sql']::text[]),
    (134, '1200_validation/1211_security_validation.sql', ARRAY['Complete 1100_security domain']::text[]),
    (135, '1200_validation/1212_integrity_validation.sql', ARRAY['5000_function/5700_system/5708_system_integrity_hardening.sql', '1100_security/1108_rls_catalog_definition.sql']::text[]),
    (136, '1200_validation/1214_extended_architecture_validation.sql', ARRAY['catalog.part_molds', 'catalog.item_search', 'definition.manifest_subassemblies', 'definition.minifig_compositions', 'marketplace.listings', 'finance.transactions', 'operations.notifications', 'reporting.catalog_items', 'api.search_catalog()', 'admin.post_financial_transaction()', '1100_security/1107_grants.sql']::text[]),
    (137, '1200_validation/1215_security_contract_validation.sql', ARRAY['1100_security/1107_grants.sql', '1100_security/1110_api_surface_lockdown.sql', '5000_function/5700_system/5700_system_identity.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5702_system_catalog.sql', '5000_function/5700_system/5703_system_definition.sql', '5000_function/5700_system/5704_system_collection.sql', '5000_function/5700_system/5705_system_wanted.sql', '5000_function/5700_system/5706_system_moc.sql', '5000_function/5000_importer/5000_importer_common.sql', '5000_function/5700_system/5707_system_audit.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql', '5000_function/5200_api/5200_api_moc_access.sql', '5000_function/5700_system/5709_system_request_context.sql', '5000_function/5100_admin/5120_admin_definition_graph.sql', '5000_function/5200_api/5210_api_operational.sql', '5000_function/5100_admin/5130_admin_finance.sql', '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql', '5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql']::text[]),
    (138, '1200_validation/1216_adversarial_authorization_validation.sql', ARRAY['1200_validation/1215_security_contract_validation.sql', 'identity.current_user_id()', 'identity.can_manage_user()', 'identity.has_family_capability()', 'api.mark_notification_read(uuid)']::text[]),
    (139, '1200_validation/1217_pgbouncer_transaction_context_validation.sql', ARRAY['5000_function/5700_system/5709_system_request_context.sql']::text[]),
    (140, '1200_validation/1218_api_surface_validation.sql', ARRAY['1100_security/1110_api_surface_lockdown.sql', '1200_validation/1217_pgbouncer_transaction_context_validation.sql']::text[]),
    (141, '1200_validation/1219_migration_framework_validation.sql', ARRAY['0000_bootstrap/0005_migration_framework.sql', '1100_security/1107_grants.sql']::text[]),
    (142, '1200_validation/1220_financial_readiness_validation.sql', ARRAY['0760_finance/0761_financial_readiness_anchors.sql', '5000_function/5100_admin/5130_admin_finance.sql', '1100_security/1107_grants.sql', '1200_validation/1219_migration_framework_validation.sql']::text[]),
    (143, '1200_validation/1221_operational_integrity_validation.sql', ARRAY['1200_validation/1220_financial_readiness_validation.sql']::text[]),
    (144, '1200_validation/1222_role_separation_validation.sql', ARRAY['1100_security/1111_role_ownership_separation.sql', '1200_validation/1221_operational_integrity_validation.sql']::text[]),
    (145, '1200_validation/1223_admin_catalog_lifecycle_validation.sql', ARRAY['1100_security/1112_admin_execute_only.sql', '1200_validation/1222_role_separation_validation.sql']::text[]),
    (146, '1200_validation/1224_system_summary_validation.sql', ARRAY['1000_reporting/1010_reporting_system_summary.sql']::text[]),
    (147, '1200_validation/1225_aggregate_tables_validation.sql', ARRAY['1000_reporting/1011_reporting_aggregate_tables.sql', '1200_validation/1224_system_summary_validation.sql']::text[]),
    (148, '1200_validation/1226_set_manifest_enrichment_validation.sql', ARRAY['0400_definitions/0410_set_manifest_components.sql', '5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql', '5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql', '1100_security/1111_role_ownership_separation.sql']::text[]),
    (149, '5000_function/5900_tests/5900_test_app_lifecycle.sql', ARRAY['5000_function/5700_system/5709_system_request_context.sql', '0000_bootstrap/0005_migration_framework.sql']::text[]),
    (150, '5000_function/5900_tests/5901_test_identity_lifecycle.sql', ARRAY['5000_function/5700_system/5700_system_identity.sql']::text[]),
    (151, '5000_function/5900_tests/5902_test_reference_lifecycle.sql', ARRAY['5000_function/5700_system/5701_system_hierarchy.sql']::text[]),
    (152, '5000_function/5900_tests/5903_test_catalog_lifecycle.sql', ARRAY['5000_function/5700_system/5702_system_catalog.sql', '0300_catalog/0320_catalog_search_media.sql']::text[]),
    (153, '5000_function/5900_tests/5904_test_definition_lifecycle.sql', ARRAY['5000_function/5700_system/5703_system_definition.sql', '5000_function/5100_admin/5120_admin_definition_graph.sql', '0400_definitions/0405_manifest_graph.sql']::text[]),
    (154, '5000_function/5900_tests/5905_test_collection_lifecycle.sql', ARRAY['5000_function/5700_system/5704_system_collection.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql']::text[]),
    (155, '5000_function/5900_tests/5906_test_wanted_lifecycle.sql', ARRAY['5000_function/5700_system/5705_system_wanted.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql']::text[]),
    (156, '5000_function/5900_tests/5907_test_moc_lifecycle.sql', ARRAY['5000_function/5700_system/5706_system_moc.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql']::text[]),
    (157, '5000_function/5900_tests/5908_test_audit_lifecycle.sql', ARRAY['5000_function/5700_system/5707_system_audit.sql']::text[]),
    (158, '5000_function/5900_tests/5909_test_import_lifecycle.sql', ARRAY['5000_function/5000_importer/5000_importer_common.sql', '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql', '5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql', '5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql', '5000_function/5700_system/5709_system_request_context.sql']::text[]),
    (159, '5000_function/5900_tests/5910_test_api_lifecycle.sql', ARRAY['5000_function/5200_api/5200_api_moc_access.sql', '5000_function/5200_api/5210_api_operational.sql']::text[]),
    (160, '5000_function/5900_tests/5911_test_admin_lifecycle.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql', '5000_function/5100_admin/5130_admin_finance.sql', '5000_function/5200_api/5210_api_operational.sql', '1100_security/1112_admin_execute_only.sql']::text[]),
    (161, '5000_function/5900_tests/5912_test_finance_lifecycle.sql', ARRAY['5000_function/5100_admin/5130_admin_finance.sql', '0760_finance/0761_financial_readiness_anchors.sql']::text[]),
    (162, '5000_function/5900_tests/5913_test_reporting_lifecycle.sql', ARRAY['1000_reporting/1010_reporting_system_summary.sql', '1000_reporting/1011_reporting_aggregate_tables.sql', '5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql']::text[]),
    (163, '1200_validation/1213_dependency_validation.sql', ARRAY['1200_validation/1212_integrity_validation.sql', '1200_validation/1214_extended_architecture_validation.sql', '1200_validation/1215_security_contract_validation.sql', '1200_validation/1216_adversarial_authorization_validation.sql', '1200_validation/1217_pgbouncer_transaction_context_validation.sql', '1200_validation/1218_api_surface_validation.sql', '1200_validation/1219_migration_framework_validation.sql', '1200_validation/1220_financial_readiness_validation.sql', '1200_validation/1221_operational_integrity_validation.sql', '1200_validation/1222_role_separation_validation.sql', '1200_validation/1223_admin_catalog_lifecycle_validation.sql', '1200_validation/1224_system_summary_validation.sql', '1200_validation/1225_aggregate_tables_validation.sql', '1200_validation/1226_set_manifest_enrichment_validation.sql', '5000_function/5900_tests/5900_test_app_lifecycle.sql', '5000_function/5900_tests/5901_test_identity_lifecycle.sql', '5000_function/5900_tests/5902_test_reference_lifecycle.sql', '5000_function/5900_tests/5903_test_catalog_lifecycle.sql', '5000_function/5900_tests/5904_test_definition_lifecycle.sql', '5000_function/5900_tests/5905_test_collection_lifecycle.sql', '5000_function/5900_tests/5906_test_wanted_lifecycle.sql', '5000_function/5900_tests/5907_test_moc_lifecycle.sql', '5000_function/5900_tests/5908_test_audit_lifecycle.sql', '5000_function/5900_tests/5909_test_import_lifecycle.sql', '5000_function/5900_tests/5910_test_api_lifecycle.sql', '5000_function/5900_tests/5911_test_admin_lifecycle.sql', '5000_function/5900_tests/5912_test_finance_lifecycle.sql', '5000_function/5900_tests/5913_test_reporting_lifecycle.sql']::text[]);

CREATE OR REPLACE FUNCTION pg_temp.bt_dependency_exists(p_dependency text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_dep text := btrim(p_dependency);
    v_schema text;
    v_object text;
    v_prefix text;
    v_proc_count bigint;
BEGIN
    IF v_dep = '' THEN
        RETURN true;
    END IF;

    IF v_dep = 'PostgreSQL 16+' THEN
        RETURN current_setting('server_version_num')::integer >= 160000;
    END IF;

    IF v_dep IN (
        'PostgreSQL extension installation privileges',
        'Permission to create extensions'
    ) THEN
        RETURN has_database_privilege(current_database(), 'CREATE')
           AND EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pgcrypto')
           AND EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='citext')
           AND EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='pg_trgm');
    END IF;

    IF v_dep IN (
        'PostgreSQL role-creation privileges',
        'Permission to create database roles'
    ) THEN
        RETURN EXISTS (
            SELECT 1 FROM pg_roles
            WHERE rolname = current_user
              AND (rolsuper OR rolcreaterole)
        );
    END IF;

    IF v_dep = 'Permission to create schemas' THEN
        RETURN has_database_privilege(current_database(), 'CREATE');
    END IF;

    IF v_dep ~ '\.sql$' THEN
        RETURN EXISTS (
            SELECT 1 FROM pg_temp.bt_completed_files
            WHERE file_path = v_dep
        );
    END IF;

    IF v_dep ~ '^Complete [0-9]{4}_[A-Za-z0-9_]+ domain$' THEN
        v_prefix := substring(v_dep FROM '^Complete ([0-9]{4}_[A-Za-z0-9_]+) domain$');
        RETURN NOT EXISTS (
            SELECT 1
            FROM pg_temp.bt_expected_files e
            LEFT JOIN pg_temp.bt_completed_files c USING (file_path)
            WHERE e.file_path LIKE v_prefix || '/%'
              AND c.file_path IS NULL
        );
    END IF;

    IF v_dep ~ ' schema$' THEN
        v_schema := regexp_replace(v_dep, ' schema$', '');
        RETURN to_regnamespace(v_schema) IS NOT NULL;
    END IF;

    IF v_dep IN ('pgcrypto','citext','pg_trgm') THEN
        RETURN EXISTS (SELECT 1 FROM pg_extension WHERE extname = v_dep);
    END IF;

    IF position('.' in v_dep) = 0
       AND to_regnamespace(v_dep) IS NOT NULL THEN
        RETURN true;
    END IF;

    /* Function dependency with omitted signature, e.g. identity.can_manage_owner(). */
    IF v_dep ~ '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\(\)$' THEN
        v_schema := split_part(v_dep, '.', 1);
        v_object := regexp_replace(split_part(v_dep, '.', 2), '\(\)$', '');
        SELECT count(*) INTO v_proc_count
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname=v_schema AND p.proname=v_object;
        RETURN v_proc_count > 0;
    END IF;

    /* Exact routine signature when one is declared. */
    IF v_dep ~ '\(.*\)$' THEN
        BEGIN
            RETURN to_regprocedure(v_dep) IS NOT NULL;
        EXCEPTION WHEN OTHERS THEN
            RETURN false;
        END;
    END IF;

    /* Relation/view/type/domain/general schema-qualified object. */
    BEGIN
        IF to_regclass(v_dep) IS NOT NULL THEN
            RETURN true;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    BEGIN
        IF to_regtype(v_dep) IS NOT NULL THEN
            RETURN true;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    IF position('.' in v_dep) > 0 THEN
        v_schema := split_part(v_dep, '.', 1);
        v_object := split_part(v_dep, '.', 2);
        SELECT count(*) INTO v_proc_count
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname=v_schema AND p.proname=v_object;
        IF v_proc_count > 0 THEN
            RETURN true;
        END IF;
    END IF;

    RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bt_preflight(
    p_file_path text,
    p_dependencies text[]
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_expected text[];
    v_dep text;
    v_ok boolean;
BEGIN
    SELECT dependencies INTO v_expected
    FROM pg_temp.bt_expected_files
    WHERE file_path = p_file_path;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'File % is not present in the generated dependency manifest', p_file_path;
    END IF;

    IF v_expected IS DISTINCT FROM p_dependencies THEN
        RAISE EXCEPTION
            'Dependency declaration mismatch for %. Expected %, file supplied %',
            p_file_path, v_expected, p_dependencies;
    END IF;

    FOREACH v_dep IN ARRAY p_dependencies LOOP
        v_ok := pg_temp.bt_dependency_exists(v_dep);

        INSERT INTO pg_temp.bt_dependency_checks(file_path, dependency, satisfied)
        VALUES (p_file_path, v_dep, v_ok)
        ON CONFLICT (file_path, dependency)
        DO UPDATE SET satisfied=EXCLUDED.satisfied, checked_at=clock_timestamp();

        IF NOT v_ok THEN
            RAISE EXCEPTION
                'Dependency preflight failed before %: required dependency "%" does not exist',
                p_file_path, v_dep
                USING ERRCODE='55000';
        END IF;
    END LOOP;

    INSERT INTO pg_temp.bt_file_preflights(file_path)
    VALUES (p_file_path)
    ON CONFLICT (file_path)
    DO UPDATE SET checked_at=clock_timestamp();
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.bt_mark_completed(p_file_path text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_temp.bt_file_preflights WHERE file_path=p_file_path
    ) AND p_file_path <> '0000_bootstrap/0000_dependency_preflight.sql' THEN
        RAISE EXCEPTION 'Cannot mark % complete: no successful preflight was recorded', p_file_path;
    END IF;

    INSERT INTO pg_temp.bt_completed_files(file_path)
    VALUES (p_file_path)
    ON CONFLICT (file_path)
    DO UPDATE SET completed_at=clock_timestamp();
END;
$$;

SELECT pg_temp.bt_mark_completed('0000_bootstrap/0000_dependency_preflight.sql');
\echo '[PASS] 0000_dependency_preflight.sql'
