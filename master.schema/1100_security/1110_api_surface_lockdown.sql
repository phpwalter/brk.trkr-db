/*
===============================================================================
 File:           1100_security/1110_api_surface_lockdown.sql
 Project:        BrickTrackr
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Make the runtime stored-procedure/API surface explicit,
                 deny-by-default, mechanically reviewable, and safe to rerun.
 Depends On:     1100_security/1107_grants.sql
                 5000_function/5700_system/5700_system_identity.sql
                 5000_function/5700_system/5701_system_hierarchy.sql
                 5000_function/5700_system/5702_system_catalog.sql
                 5000_function/5700_system/5703_system_definition.sql
                 5000_function/5700_system/5704_system_collection.sql
                 5000_function/5700_system/5705_system_wanted.sql
                 5000_function/5700_system/5706_system_moc.sql
                 5000_function/5700_system/5707_system_audit.sql
                 5000_function/5700_system/5708_system_integrity_hardening.sql
                 5000_function/5700_system/5709_system_request_context.sql
                 5000_function/5700_system/5710_system_anonymous_request_context.sql
                 5000_function/5200_api/5200_api_moc_access.sql
                 5000_function/5200_api/5210_api_operational.sql
                 5000_function/5200_api/5220_api_contract_common.sql
                 5000_function/5200_api/5221_api_catalog_reference.sql
                 5000_function/5200_api/5222_api_definition_helpers.sql
                 5000_function/5200_api/5230_api_collection_inventory.sql
                 5000_function/5200_api/5240_api_wanted.sql
                 5000_function/5200_api/5250_api_moc_minifig.sql
                 5000_function/5200_api/5260_api_identity_activity.sql
                 5000_function/5200_api/5270_api_market_reporting.sql
                 5000_function/5100_admin/5120_admin_definition_graph.sql
                 5000_function/5100_admin/5130_admin_finance.sql
                 5000_function/5000_importer/5000_importer_common.sql
                 5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql
                 5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql
                 5000_function/5000_importer/5012_importer_fail_source_run.sql
                 5000_function/5100_admin/5100_admin_common.sql
                 5000_function/5100_admin/5110_admin_catalog_lifecycle.sql
 Creates:        app.runtime_api_allowlist
 Key Rules:      PUBLIC receives no api.* EXECUTE.
                 brktrkr_api receives EXECUTE only for allowlisted routines.
                 Privileged api.admin_finance_operation is intentionally absent
                 and is granted only to brktrkr_admin by 1114.
                 New api.* routines receive no PUBLIC/runtime EXECUTE by default.
                 The allowlist is reconciled idempotently on every run.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '1100_security/1110_api_surface_lockdown.sql',
    ARRAY[
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
        '5000_function/5200_api/5240_api_wanted.sql',
        '5000_function/5200_api/5250_api_moc_minifig.sql',
        '5000_function/5200_api/5260_api_identity_activity.sql',
        '5000_function/5200_api/5270_api_market_reporting.sql',
        '5000_function/5100_admin/5120_admin_definition_graph.sql',
        '5000_function/5100_admin/5130_admin_finance.sql',
        '5000_function/5000_importer/5000_importer_common.sql',
        '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql',
        '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql',
        '5000_function/5000_importer/5012_importer_fail_source_run.sql',
        '5000_function/5100_admin/5100_admin_common.sql',
        '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql'
    ]::text[]
);

CREATE TABLE IF NOT EXISTS app.runtime_api_allowlist (
    routine_signature text PRIMARY KEY,
    purpose text NOT NULL,
    anonymous_safe boolean NOT NULL DEFAULT false,
    CONSTRAINT ck_runtime_api_signature_schema CHECK (routine_signature LIKE 'api.%')
);

COMMENT ON TABLE app.runtime_api_allowlist IS
    'Canonical reviewed allowlist of api.* routines executable by brktrkr_api.';

WITH authoritative_allowlist(routine_signature,purpose,anonymous_safe) AS (
    VALUES
        ('api.get_moc_by_id(uuid)', 'Read one MOC subject to visibility rules.', true),
        ('api.get_moc_revisions(uuid)', 'Read MOC revision metadata subject to visibility rules.', true),
        ('api.get_moc_assets(uuid,uuid)', 'Read MOC assets subject to visibility rules.', true),
        ('api.get_moc_licenses(uuid,uuid)', 'Read MOC license data subject to visibility rules.', true),
        ('api.get_moc_subassemblies(uuid,uuid)', 'Read MOC subassemblies subject to visibility rules.', true),
        ('api.search_catalog(text,integer)', 'Search the catalog through the reviewed API boundary.', false),
        ('api.search_catalog_public(text,text,integer)', 'Anonymous-safe public catalog search by stable item number.', true),
        ('api.get_catalog_item_by_item_num(text)', 'Anonymous-safe public catalog lookup.', true),
        ('api.get_set_by_item_num(text)', 'Anonymous-safe canonical set lookup.', true),
        ('api.get_set_manifest_by_item_num(text)', 'Anonymous-safe current set manifest lookup.', true),
        ('api.get_set_manifest_versions_by_item_num(text)', 'Anonymous-safe set manifest version history.', true),
        ('api.get_set_manifest_version_by_item_num(text,integer)', 'Anonymous-safe immutable set manifest snapshot.', true),
        ('api.get_set_instruction_assets_by_item_num(text)', 'Anonymous-safe instruction-asset listing.', true),
        ('api.get_set_market_by_item_num(text,text)', 'Anonymous-safe set market observations.', true),
        ('api.get_part_by_part_num(text)', 'Anonymous-safe canonical part lookup.', true),
        ('api.get_part_where_used(text,integer,text)', 'Anonymous-safe part where-used lookup.', true),
        ('api.get_part_sources(text)', 'Anonymous-safe part provenance lookup.', true),
        ('api.get_part_market(text,text)', 'Anonymous-safe part market observations.', true),
        ('api.get_part_inventory_links(text)', 'Authenticated part-to-owned-inventory links.', false),
        ('api.mark_notification_read(uuid)', 'Mark an authenticated caller-owned notification as read.', false),
        ('api.transfer_collection_quantity(uuid,uuid,app.quantity,text)', 'Transfer collection quantity after authorization checks.', false),
        ('api.catalog_reference_operation(text,jsonb)', 'Public/reference catalog dispatcher with operation-level read controls.', true),
        ('api.collection_inventory_operation(text,jsonb,jsonb,text)', 'Authenticated collection, physical inventory and storage lifecycle dispatcher.', false),
        ('api.wanted_operation(text,jsonb,jsonb,text)', 'Authenticated wishlist and build-goal lifecycle dispatcher.', false),
        ('api.moc_minifig_operation(text,jsonb,jsonb,text)', 'MOC/custom-minifig lifecycle dispatcher with internal visibility enforcement.', true),
        ('api.identity_activity_operation(text,jsonb,jsonb,text)', 'Authenticated profile, family, notification, activity and dashboard dispatcher.', false),
        ('api.market_reporting_operation(text,jsonb)', 'Market history, authorized valuation and reporting dispatcher.', true)
)
INSERT INTO app.runtime_api_allowlist(routine_signature,purpose,anonymous_safe)
SELECT routine_signature,purpose,anonymous_safe FROM authoritative_allowlist
ON CONFLICT (routine_signature) DO UPDATE
SET purpose=EXCLUDED.purpose,anonymous_safe=EXCLUDED.anonymous_safe;

WITH authoritative(routine_signature) AS (
    VALUES
        ('api.get_moc_by_id(uuid)'),
        ('api.get_moc_revisions(uuid)'),
        ('api.get_moc_assets(uuid,uuid)'),
        ('api.get_moc_licenses(uuid,uuid)'),
        ('api.get_moc_subassemblies(uuid,uuid)'),
        ('api.search_catalog(text,integer)'),
        ('api.search_catalog_public(text,text,integer)'),
        ('api.get_catalog_item_by_item_num(text)'),
        ('api.get_set_by_item_num(text)'),
        ('api.get_set_manifest_by_item_num(text)'),
        ('api.get_set_manifest_versions_by_item_num(text)'),
        ('api.get_set_manifest_version_by_item_num(text,integer)'),
        ('api.get_set_instruction_assets_by_item_num(text)'),
        ('api.get_set_market_by_item_num(text,text)'),
        ('api.get_part_by_part_num(text)'),
        ('api.get_part_where_used(text,integer,text)'),
        ('api.get_part_sources(text)'),
        ('api.get_part_market(text,text)'),
        ('api.get_part_inventory_links(text)'),
        ('api.mark_notification_read(uuid)'),
        ('api.transfer_collection_quantity(uuid,uuid,app.quantity,text)'),
        ('api.catalog_reference_operation(text,jsonb)'),
        ('api.collection_inventory_operation(text,jsonb,jsonb,text)'),
        ('api.wanted_operation(text,jsonb,jsonb,text)'),
        ('api.moc_minifig_operation(text,jsonb,jsonb,text)'),
        ('api.identity_activity_operation(text,jsonb,jsonb,text)'),
        ('api.market_reporting_operation(text,jsonb)')
)
DELETE FROM app.runtime_api_allowlist existing
WHERE NOT EXISTS (SELECT 1 FROM authoritative a WHERE a.routine_signature=existing.routine_signature);

REVOKE ALL PRIVILEGES ON TABLE app.runtime_api_allowlist FROM PUBLIC, brktrkr_api;
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA api FROM PUBLIC, brktrkr_api;

ALTER DEFAULT PRIVILEGES FOR ROLE brktrkr_owner REVOKE EXECUTE ON ROUTINES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE brktrkr_owner IN SCHEMA api REVOKE EXECUTE ON ROUTINES FROM brktrkr_api;

GRANT USAGE ON SCHEMA api TO brktrkr_api;
REVOKE CREATE ON SCHEMA api FROM PUBLIC, brktrkr_api;

DO $api_surface$
DECLARE
    v_signature text;
    v_oid oid;
BEGIN
    FOR v_signature IN SELECT routine_signature FROM app.runtime_api_allowlist ORDER BY routine_signature LOOP
        v_oid:=pg_catalog.to_regprocedure(v_signature);
        IF v_oid IS NULL THEN
            RAISE EXCEPTION 'Approved runtime API routine does not exist: %',v_signature;
        END IF;
        EXECUTE pg_catalog.format('GRANT EXECUTE ON ROUTINE %s TO brktrkr_api',v_oid::regprocedure);
    END LOOP;
END
$api_surface$;

DO $verify_api_surface$
DECLARE
    v_signature text;
    v_oid oid;
    v_count integer;
BEGIN
    SELECT count(*) INTO v_count FROM app.runtime_api_allowlist;
    IF v_count<>27 THEN
        RAISE EXCEPTION 'Runtime API allowlist cardinality mismatch: expected 27, found %.',v_count;
    END IF;

    FOR v_signature IN SELECT routine_signature FROM app.runtime_api_allowlist ORDER BY routine_signature LOOP
        v_oid:=pg_catalog.to_regprocedure(v_signature);
        IF v_oid IS NULL THEN RAISE EXCEPTION 'Allowlisted API routine cannot be resolved: %',v_signature; END IF;
        IF NOT pg_catalog.has_function_privilege('brktrkr_api',v_oid,'EXECUTE') THEN
            RAISE EXCEPTION 'brktrkr_api lacks EXECUTE on allowlisted routine %.',v_signature;
        END IF;
    END LOOP;

    IF pg_catalog.has_table_privilege('brktrkr_api','app.runtime_api_allowlist','SELECT')
       OR pg_catalog.has_table_privilege('brktrkr_api','app.runtime_api_allowlist','INSERT')
       OR pg_catalog.has_table_privilege('brktrkr_api','app.runtime_api_allowlist','UPDATE')
       OR pg_catalog.has_table_privilege('brktrkr_api','app.runtime_api_allowlist','DELETE') THEN
        RAISE EXCEPTION 'Security contract failure: brktrkr_api must not have direct table privileges on app.runtime_api_allowlist.';
    END IF;
END
$verify_api_surface$;

\echo '[PASS] 1110_api_surface_lockdown.sql v1.3.0'
SELECT pg_temp.bt_mark_completed('1100_security/1110_api_surface_lockdown.sql');
