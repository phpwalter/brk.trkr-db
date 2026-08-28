/*
===============================================================================
 File:           1100_security/1110_api_surface_lockdown.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.2.0
 PostgreSQL:     16+
 Purpose:        Make the runtime stored-procedure/API surface explicit,
                 deny-by-default, and mechanically reviewable.
 Depends On:     1100_security/1107_grants.sql
                 5000_function/5700_system/5700_system_identity.sql
                 5000_function/5700_system/5701_system_hierarchy.sql
                 5000_function/5700_system/5702_system_catalog.sql
                 5000_function/5700_system/5703_system_definition.sql
                 5000_function/5700_system/5704_system_collection.sql
                 5000_function/5700_system/5705_system_wanted.sql
                 5000_function/5700_system/5706_system_moc.sql
                 5000_function/5000_importer/5000_importer_common.sql
                 5000_function/5700_system/5707_system_audit.sql
                 5000_function/5700_system/5708_system_integrity_hardening.sql
                 5000_function/5200_api/5200_api_moc_access.sql
                 5000_function/5700_system/5709_system_request_context.sql
                 5000_function/5100_admin/5120_admin_definition_graph.sql
                 5000_function/5200_api/5210_api_operational.sql
                 5000_function/5100_admin/5130_admin_finance.sql
                 5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql
                 5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql
                 5000_function/5000_importer/5012_importer_fail_source_run.sql
                 5000_function/5100_admin/5100_admin_common.sql
                 5000_function/5100_admin/5110_admin_catalog_lifecycle.sql
 Creates:        app.runtime_api_allowlist
 Key Rules:      PUBLIC receives no api.* EXECUTE.
                 lego_api/lego_app receive EXECUTE only for allowlisted routines.
                 New api.* routines receive no PUBLIC/runtime EXECUTE by default.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1110_api_surface_lockdown.sql', ARRAY['1100_security/1107_grants.sql', '5000_function/5700_system/5700_system_identity.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5702_system_catalog.sql', '5000_function/5700_system/5703_system_definition.sql', '5000_function/5700_system/5704_system_collection.sql', '5000_function/5700_system/5705_system_wanted.sql', '5000_function/5700_system/5706_system_moc.sql', '5000_function/5000_importer/5000_importer_common.sql', '5000_function/5700_system/5707_system_audit.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql', '5000_function/5200_api/5200_api_moc_access.sql', '5000_function/5700_system/5709_system_request_context.sql', '5000_function/5100_admin/5120_admin_definition_graph.sql', '5000_function/5200_api/5210_api_operational.sql', '5000_function/5100_admin/5130_admin_finance.sql', '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql', '5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql']::text[]);

CREATE TABLE app.runtime_api_allowlist (
    routine_signature text PRIMARY KEY,
    purpose text NOT NULL,
    anonymous_safe boolean NOT NULL DEFAULT false,
    CONSTRAINT ck_runtime_api_signature_schema
        CHECK (routine_signature LIKE 'api.%')
);

COMMENT ON TABLE app.runtime_api_allowlist IS
    'Canonical reviewed allowlist of api.* routines executable by runtime roles.';

INSERT INTO app.runtime_api_allowlist(
    routine_signature,
    purpose,
    anonymous_safe
)
VALUES
    ('api.get_moc_by_id(uuid)',
     'Read one MOC subject to PUBLIC/UNLISTED/owner visibility rules.', true),
    ('api.get_moc_revisions(uuid)',
     'Read MOC revision metadata subject to MOC visibility rules.', true),
    ('api.get_moc_assets(uuid,uuid)',
     'Read MOC assets subject to MOC visibility rules.', true),
    ('api.get_moc_licenses(uuid,uuid)',
     'Read MOC license data subject to MOC visibility rules.', true),
    ('api.get_moc_subassemblies(uuid,uuid)',
     'Read MOC subassemblies subject to MOC visibility rules.', true),
    ('api.search_catalog(text,integer)',
     'Legacy internal search retained for compatibility.', false),
    ('api.search_catalog_public(text,text,integer)',
     'Search public catalog objects by stable item number and selectable domain.', true),
    ('api.get_catalog_item_by_item_num(text)',
     'Read one canonical public catalog item by stable item number.', true),
    ('api.get_set_by_item_num(text)',
     'Read canonical set metadata by stable public item number.', true),
    ('api.get_set_manifest_by_item_num(text)',
     'Read the effective finalized set manifest.', true),
    ('api.get_set_manifest_versions_by_item_num(text)',
     'List immutable finalized set manifest versions.', true),
    ('api.get_set_manifest_version_by_item_num(text,integer)',
     'Read one immutable finalized set manifest version.', true),
    ('api.get_set_instruction_assets_by_item_num(text)',
     'Read set instruction metadata and object-storage keys.', true),
    ('api.get_set_market_by_item_num(text,text)',
     'Read latest source-attributed set market observations.', true),
    ('api.get_part_by_part_num(text)',
     'Read canonical part metadata by stable public part number.', true),
    ('api.get_part_where_used(text,integer,text)',
     'List finalized set manifests that use a canonical part.', true),
    ('api.get_part_sources(text)',
     'Read source/provenance mappings for a canonical part.', true),
    ('api.get_part_market(text,text)',
     'Read latest source-attributed part market observations.', true),
    ('api.get_part_inventory_links(text)',
     'Read authenticated caller-visible inventory links for a canonical part.', false),
    ('api.mark_notification_read(uuid)',
     'Mark an authenticated caller-owned notification as read.', false),
    ('api.transfer_collection_quantity(uuid,uuid,app.quantity,text)',
     'Transfer collection quantity after database authorization checks.', false);

REVOKE ALL PRIVILEGES ON app.runtime_api_allowlist
FROM PUBLIC, lego_api, lego_app;

REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA api
FROM PUBLIC, lego_api, lego_app;

ALTER DEFAULT PRIVILEGES
    REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

ALTER DEFAULT PRIVILEGES
    REVOKE EXECUTE ON ROUTINES FROM lego_api, lego_app;

GRANT USAGE ON SCHEMA api TO lego_api, lego_app;
REVOKE CREATE ON SCHEMA api FROM PUBLIC, lego_api, lego_app;

DO $api_surface$
DECLARE
    v_signature text;
    v_oid oid;
BEGIN
    FOR v_signature IN
        SELECT routine_signature
        FROM app.runtime_api_allowlist
        ORDER BY routine_signature
    LOOP
        v_oid := to_regprocedure(v_signature);

        IF v_oid IS NULL THEN
            RAISE EXCEPTION
                'Approved runtime API routine does not exist: %',
                v_signature;
        END IF;

        EXECUTE format(
            'GRANT EXECUTE ON ROUTINE %s TO lego_api, lego_app',
            v_oid::regprocedure
        );
    END LOOP;
END
$api_surface$;

SELECT pg_temp.bt_mark_completed('1100_security/1110_api_surface_lockdown.sql');
