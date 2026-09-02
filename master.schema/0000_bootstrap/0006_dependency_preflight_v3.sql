/*
===============================================================================
 File:           0000_bootstrap/0006_dependency_preflight_v3.sql
 Project:        BrickTrackr
 Schema Version: 1.3.2
 PostgreSQL:     16+
 Purpose:        Extend the generated dependency gate with additive v3 files
                 without rewriting the stable base dependency manifest.
 Depends On:     0000_bootstrap/0000_dependency_preflight.sql
 Creates:        Supplemental pg_temp.bt_expected_files rows for v3
 Key Rules:      The base manifest remains authoritative for existing files.
                 This supplement may add rows and explicitly override a base row
                 only when that existing file's dependency header changed in v3.
===============================================================================
*/

\set ON_ERROR_STOP on

INSERT INTO pg_temp.bt_expected_files(ordinal,file_path,dependencies)
VALUES
    (1001,'0000_bootstrap/0006_dependency_preflight_v3.sql',ARRAY['0000_bootstrap/0000_dependency_preflight.sql']::text[]),
    (1002,'0100_identity/0107_identity_api_state.sql',ARRAY['identity.users','identity.families']::text[]),
    (1003,'0400_definitions/0407_custom_minifig_lifecycle.sql',ARRAY['catalog.minifigures','identity.owners','identity.users']::text[]),
    (1004,'0500_collections/0508_collection_groups.sql',ARRAY['identity.owners','collection.entries','collection.storage_locations','collection.instances']::text[]),
    (1005,'0600_wanted/0605_wanted_api_state.sql',ARRAY['wanted.wishlists','wanted.wishlist_entries','wanted.build_goals']::text[]),
    (1006,'0700_mocs/0706_moc_api_state.sql',ARRAY['moc.mocs','moc.revisions']::text[]),
    (1007,'5000_function/5200_api/5220_api_contract_common.sql',ARRAY['api schema','identity.current_user_id()','identity.owners']::text[]),
    (1008,'5000_function/5200_api/5221_api_catalog_reference.sql',ARRAY['reference.colors','reference.themes','reference.categories','reference.minifig_roles','catalog.items','catalog.item_images','catalog.external_identifiers','catalog.part_variants','catalog.lego_elements','catalog.part_molds','catalog.part_mold_revisions','catalog.part_mold_substitutions','definition.inventory_definitions','definition.inventory_versions','definition.requirement_groups','definition.requirement_options','definition.minifig_compositions','definition.minifig_structural_components','definition.minifig_accessories']::text[]),
    (1009,'5000_function/5200_api/5222_api_definition_helpers.sql',ARRAY['definition.inventory_versions','definition.requirement_groups','definition.requirement_options','catalog.items','catalog.part_variants','pgcrypto']::text[]),
    (1010,'5000_function/5200_api/5230_api_collection_inventory.sql',ARRAY['api.current_user_owner_id()','api.assert_if_match()','identity.current_user_id()','identity.can_view_owner()','identity.can_manage_owner()','collection.collections','collection.collection_memberships','collection.entries','collection.instances','collection.instance_adjustments','collection.storage_locations','collection.storage_allocations','collection.acquisitions','collection.acquisition_items','catalog.items','catalog.part_variants','definition.inventory_versions','definition.requirement_groups','definition.requirement_options']::text[]),
    (1024,'5000_function/5200_api/5231_api_inventory_import.sql',ARRAY['5000_function/5200_api/5230_api_collection_inventory.sql','identity.current_user_id()','catalog.items','catalog.parts','catalog.part_variants']::text[]),
    (1011,'5000_function/5200_api/5240_api_wanted.sql',ARRAY['api.current_user_owner_id()','api.assert_if_match()','identity.current_user_id()','identity.can_view_owner()','identity.can_manage_owner()','identity.can_view_family_shared_owner()','wanted.wishlists','wanted.wishlist_entries','wanted.wishlist_reservations','wanted.build_goals','wanted.build_allocations','collection.entries','catalog.items','catalog.part_variants','definition.inventory_versions','definition.requirement_groups','definition.requirement_options']::text[]),
    (1012,'5000_function/5200_api/5250_api_moc_minifig.sql',ARRAY['api.current_user_owner_id()','api.assert_if_match()','api.inventory_graph_json()','api.replace_inventory_graph()','api.copy_inventory_graph()','api.finalize_inventory_version()','identity.current_user_id()','identity.can_view_owner()','identity.can_manage_owner()','identity.can_view_family_shared_owner()','catalog.items','catalog.mocs','catalog.minifigures','definition.custom_minifigs','definition.inventory_definitions','definition.inventory_versions','definition.minifig_compositions','definition.minifig_structural_components','definition.minifig_accessories','moc.mocs','moc.revisions','moc.forks','moc.subassemblies','moc.licenses','moc.assets','marketplace.market_price_observations']::text[]),
    (1013,'5000_function/5200_api/5260_api_identity_activity.sql',ARRAY['api.assert_if_match()','identity.current_user_id()','identity.users','identity.families','identity.family_memberships','identity.family_member_permissions','identity.owners','operations.notifications','audit.events','collection.entries','marketplace.market_price_observations']::text[]),
    (1014,'5000_function/5200_api/5270_api_market_reporting.sql',ARRAY['identity.current_user_id()','identity.can_view_owner()','catalog.items','catalog.part_variants','marketplace.market_price_observations','reference.external_sources','collection.entries','import.source_runs']::text[]),
    (1015,'5000_function/5700_system/5710_system_anonymous_request_context.sql',ARRAY['5000_function/5700_system/5709_system_request_context.sql','brktrkr_api role']::text[]),
    (1016,'5000_function/5200_api/5280_api_admin_finance.sql',ARRAY['admin.assert_system_admin()','admin.set_catalog_item_image()','admin.remove_catalog_item_image()','admin.set_instruction_asset()','admin.remove_instruction_asset()','admin.post_financial_transaction()','identity.current_user_id_optional()','reference.external_sources','catalog.items','catalog.sets','catalog.parts','catalog.minifigures','catalog.mocs','catalog.admin_overrides','import.jobs','import.source_runs','audit.events','audit.changes','finance.transactions','finance.ledger_entries','finance.source_events']::text[]),
    (1021,'5000_function/5100_admin/5131_admin_finance_actor.sql',ARRAY['5000_function/5100_admin/5130_admin_finance.sql','identity.users','finance.accounts','finance.transactions','finance.ledger_entries','pgcrypto']::text[]),
    (1022,'5000_function/5200_api/5281_api_admin_finance_actor.sql',ARRAY['5000_function/5200_api/5280_api_admin_finance.sql','5000_function/5100_admin/5131_admin_finance_actor.sql','admin.assert_system_admin()','identity.users','identity.owners','reference.external_sources','catalog.items','catalog.admin_overrides','import.jobs','finance.transactions','finance.ledger_entries']::text[]),
    (1023,'5000_function/5200_api/5290_api_visibility_reads.sql',ARRAY['identity.current_user_id_optional()','identity.can_view_owner()','identity.can_view_family_shared_owner()','catalog.items','catalog.minifigures','definition.custom_minifigs','definition.inventory_definitions','definition.inventory_versions','definition.minifig_compositions','definition.minifig_structural_components','definition.minifig_accessories','api.inventory_graph_json()','moc.mocs','moc.revisions','moc.assets','moc.licenses','moc.subassemblies','moc.forks','wanted.wishlists','wanted.wishlist_entries','marketplace.market_price_observations']::text[]),
    (1017,'1100_security/1113_api_v3_rls.sql',ARRAY['collection.collections','collection.collection_memberships','definition.custom_minifigs','identity.current_user_id()','identity.can_view_owner()','identity.can_manage_owner()','identity.can_view_family_shared_owner()']::text[]),
    (1018,'1100_security/1114_api_v3_execute.sql',ARRAY['1100_security/1110_api_surface_lockdown.sql','api.admin_finance_actor_operation()','brktrkr_admin role']::text[]),
    (1019,'1200_validation/1227_api_v3_validation.sql',ARRAY['1100_security/1114_api_v3_execute.sql','1100_security/1113_api_v3_rls.sql','1100_security/1110_api_surface_lockdown.sql','5000_function/5700_system/5710_system_anonymous_request_context.sql']::text[]),
    (1020,'5000_function/5900_tests/5914_test_api_v3.sql',ARRAY['1200_validation/1227_api_v3_validation.sql','5000_function/5200_api/5230_api_collection_inventory.sql','5000_function/5200_api/5240_api_wanted.sql','5000_function/5200_api/5250_api_moc_minifig.sql','5000_function/5200_api/5260_api_identity_activity.sql']::text[])
ON CONFLICT (file_path) DO UPDATE
SET ordinal=EXCLUDED.ordinal,
    dependencies=EXCLUDED.dependencies;

UPDATE pg_temp.bt_expected_files
SET dependencies=ARRAY[
    '1100_security/1107_grants.sql',
    '5000_function/5700_system/5700_system_identity.sql',
    '5000_function/5700_system/5701_system_hierarchy.sql',
    '5000_function/5700_system/5702_system_catalog.sql',
    '5000_function/5700_system/5703_system_definition.sql',
    '5000_function/5700_system/5704_system_collection.sql',
    '5000_function/5700_system/5705_system_wanted.sql',
    '5000_function/5700_system/5706_system_moc.sql',
    '5000_function/5700_system/5707_system_audit.sql',
    '5000_function/5700_system/5708_system_integrity_hardening.sql',
    '5000_function/5700_system/5709_system_request_context.sql',
    '5000_function/5700_system/5710_system_anonymous_request_context.sql',
    '5000_function/5200_api/5200_api_moc_access.sql',
    '5000_function/5200_api/5210_api_operational.sql',
    '5000_function/5200_api/5220_api_contract_common.sql',
    '5000_function/5200_api/5221_api_catalog_reference.sql',
    '5000_function/5200_api/5222_api_definition_helpers.sql',
    '5000_function/5200_api/5230_api_collection_inventory.sql',
    '5000_function/5200_api/5231_api_inventory_import.sql',
    '5000_function/5200_api/5240_api_wanted.sql',
    '5000_function/5200_api/5250_api_moc_minifig.sql',
    '5000_function/5200_api/5260_api_identity_activity.sql',
    '5000_function/5200_api/5270_api_market_reporting.sql',
    '5000_function/5200_api/5290_api_visibility_reads.sql',
    '5000_function/5100_admin/5120_admin_definition_graph.sql',
    '5000_function/5100_admin/5130_admin_finance.sql',
    '5000_function/5000_importer/5000_importer_common.sql',
    '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql',
    '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql',
    '5000_function/5000_importer/5012_importer_fail_source_run.sql',
    '5000_function/5100_admin/5100_admin_common.sql',
    '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql'
]::text[]
WHERE file_path='1100_security/1110_api_surface_lockdown.sql';

SELECT pg_temp.bt_preflight(
    '0000_bootstrap/0006_dependency_preflight_v3.sql',
    ARRAY['0000_bootstrap/0000_dependency_preflight.sql']::text[]
);

\echo '[PASS] 0006_dependency_preflight_v3.sql v1.3.2'
SELECT pg_temp.bt_mark_completed('0000_bootstrap/0006_dependency_preflight_v3.sql');
