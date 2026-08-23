/*
===============================================================================
 File:           1100_security/1107_grants.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Apply explicit least-privilege grants. RLS remains the row-level
                 authorization layer; grants define the maximum operation set.
 Depends On:     1100_security/1100_roles.sql
                 1100_security/1101_rls_identity.sql
                 1100_security/1102_rls_collections.sql
                 1100_security/1103_rls_wanted.sql
                 1100_security/1104_rls_mocs.sql
                 1100_security/1105_rls_imports.sql
                 1100_security/1106_rls_audit.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1107_grants.sql', ARRAY['1100_security/1100_roles.sql', '1100_security/1101_rls_identity.sql', '1100_security/1102_rls_collections.sql', '1100_security/1103_rls_wanted.sql', '1100_security/1104_rls_mocs.sql', '1100_security/1105_rls_imports.sql', '1100_security/1106_rls_audit.sql']::text[]);



/* Remove ambient PUBLIC access, including helper/app schema. */
REVOKE ALL ON SCHEMA
    app,
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit,
    api,
    admin,
    marketplace,
    finance,
    operations,
    reporting
FROM PUBLIC;

REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA
    app,
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit,
    api,
    admin,
    marketplace,
    finance,
    operations,
    reporting
FROM PUBLIC;


/* ==========================================================================
 * Application group role
 * ========================================================================== */

GRANT USAGE ON SCHEMA
    app,
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    api
TO lego_app;

/* Public/reference catalog data is filtered by catalog/definition RLS where
 * owner-private unresolved items are involved. */
GRANT SELECT
ON ALL TABLES IN SCHEMA
    reference,
    catalog,
    definition
TO lego_app;

/* Collection DML. Transfer history is intentionally INSERT + SELECT only. */
GRANT SELECT, INSERT, UPDATE, DELETE
ON
    collection.storage_locations,
    collection.entries,
    collection.instances,
    collection.instance_adjustments,
    collection.storage_allocations,
    collection.acquisitions,
    collection.acquisition_items,
    collection.tags,
    collection.entry_tags
TO lego_app;

GRANT SELECT, INSERT
ON collection.transfers
TO lego_app;

/* Wanted/build-goal DML. */
GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA wanted
TO lego_app;

/* MOC DML; RLS and immutability triggers narrow it further. */
GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA moc
TO lego_app;

/* Authentication resources only; ordinary user/profile tables are not exposed. */
GRANT SELECT, INSERT, UPDATE, DELETE
ON
    identity.user_credentials,
    identity.user_sessions,
    identity.one_time_tokens
TO lego_app;

/* User-facing imports only. Authoritative source-run tables remain importer-only. */
GRANT SELECT, INSERT, UPDATE, DELETE
ON
    import.jobs,
    import.raw_records,
    import.normalized_records,
    import.matches,
    import.user_mapping_suggestions,
    import.applications,
    import.application_changes
TO lego_app;


/* Runtime function surface required by defaults, RLS, and read helpers. */
GRANT EXECUTE ON FUNCTION app.uuid_v7()
TO lego_app;

GRANT EXECUTE ON FUNCTION
    identity.current_user_id(),
    identity.has_family_capability(uuid, uuid, text, text),
    identity.can_manage_user(uuid, uuid, text),
    identity.can_view_owner(uuid, uuid, text),
    identity.can_manage_owner(uuid, uuid, text),
    identity.can_view_family_shared_owner(uuid, uuid, text),
    identity.can_transfer_between(uuid, uuid, uuid)
TO lego_app;

GRANT EXECUTE ON FUNCTION
    definition.effective_inventory_version(uuid),
    collection.explicit_part_balance(uuid, uuid),
    wanted.build_goal_requirements(uuid),
    wanted.build_goal_summary(uuid),
    api.get_moc_by_id(uuid),
    api.get_moc_revisions(uuid),
    api.get_moc_assets(uuid, uuid),
    api.get_moc_licenses(uuid, uuid),
    api.get_moc_subassemblies(uuid, uuid)
TO lego_app;


/* Application sequences used by identity-backed bigint tables. */
GRANT USAGE, SELECT
ON ALL SEQUENCES IN SCHEMA
    collection,
    wanted,
    import
TO lego_app;


/* ==========================================================================
 * Administrator
 * ========================================================================== */

GRANT USAGE ON SCHEMA
    app,
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit,
    api
TO lego_admin;

GRANT ALL PRIVILEGES
ON ALL TABLES IN SCHEMA
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit
TO lego_admin;

GRANT USAGE, SELECT
ON ALL SEQUENCES IN SCHEMA
    reference,
    catalog,
    definition,
    collection,
    wanted,
    import,
    audit
TO lego_admin;

GRANT EXECUTE
ON ALL FUNCTIONS IN SCHEMA
    app,
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit,
    api
TO lego_admin;


/* ==========================================================================
 * Authoritative importer
 * ==========================================================================
 * Security contract:
 *   - lego_importer is a NOLOGIN capability role used only by dedicated
 *     import-service logins.
 *   - authoritative importers may stage/retry source data and maintain
 *     source-run provenance.
 *   - authoritative importers may READ only the source registry required to
 *     identify the upstream source.
 *   - authoritative importers receive ZERO direct DML on canonical
 *     reference/catalog/definition tables.
 *   - canonical reconciliation must be exposed later through explicitly
 *     reviewed SECURITY DEFINER routines; never through broad table grants.
 * ========================================================================== */

/* Reconcile any historical/broader importer privileges first. */
REVOKE ALL PRIVILEGES
ON ALL TABLES IN SCHEMA
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    audit,
    finance,
    operations,
    reporting
FROM lego_importer;

REVOKE ALL PRIVILEGES
ON ALL SEQUENCES IN SCHEMA
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    audit,
    finance,
    operations,
    reporting
FROM lego_importer;

REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    audit,
    finance,
    operations,
    reporting
FROM lego_importer;

/* Importer needs only these schemas for Phase-1 source-run staging. */
GRANT USAGE ON SCHEMA
    app,
    reference,
    import
TO lego_importer;

/* Source registry lookup only. No canonical reference DML. */
GRANT SELECT
ON reference.external_sources
TO lego_importer;

/* Source-run lifecycle/provenance. */
GRANT SELECT, INSERT, UPDATE
ON
    import.source_runs,
    import.source_run_datasets
TO lego_importer;

/* Run-scoped authoritative staging.
 * DELETE is intentionally permitted only here so a failed/retried dataset can
 * be restaged idempotently within the same source run.
 */
GRANT SELECT, INSERT, DELETE
ON import.source_stage_records
TO lego_importer;

/* Identity sequences used by the staging/control tables. */
GRANT USAGE, SELECT
ON SEQUENCE
    import.source_run_datasets_source_run_dataset_id_seq,
    import.source_stage_records_source_stage_record_id_seq
TO lego_importer;

/* app.uuid_v7() is required by import.source_runs.source_run_id default. */
GRANT EXECUTE ON FUNCTION app.uuid_v7()
TO lego_importer;

/* Deliberately no:
 *   GRANT ... ON ALL TABLES IN SCHEMA reference/catalog/definition
 *   GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ...
 *
 * Future canonical reconciliation functions must be granted by exact
 * signature after review.
 */


/* ==========================================================================
 * Controlled application API role (preferred runtime boundary)
 * ========================================================================== */
GRANT USAGE ON SCHEMA api TO lego_api;
/* Runtime EXECUTE grants are applied from the reviewed allowlist in
 * 1110_api_surface_lockdown.sql. */

/* No direct operational table privileges are granted to lego_api. */
GRANT USAGE ON SCHEMA reporting TO lego_reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO lego_reporting;

/* Administrators receive explicit access to the extended domains. */
GRANT USAGE ON SCHEMA admin, marketplace, finance, operations, reporting TO lego_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA marketplace, finance, operations TO lego_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO lego_admin;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA admin, api TO lego_admin;

/* Importer may write source-attributed market observations, but not listings/orders/ledger. */
GRANT USAGE ON SCHEMA marketplace TO lego_importer;
GRANT SELECT, INSERT, UPDATE ON marketplace.market_price_observations TO lego_importer;

/* Compatibility runtime may call the new safe API without direct access to new base tables. */
GRANT USAGE ON SCHEMA api TO lego_app;
/* Runtime EXECUTE grants are applied from the reviewed allowlist in
 * 1110_api_surface_lockdown.sql. */

GRANT USAGE ON SCHEMA app TO lego_api;
GRANT EXECUTE ON FUNCTION app.set_authenticated_user(uuid) TO lego_api;
GRANT EXECUTE ON FUNCTION app.set_request_context(uuid,text,text) TO lego_api;


/* ==========================================================================
 * Runtime execute-only hardening
 * ==========================================================================
 * Security contract:
 *   - lego_api is the preferred runtime group role.
 *   - lego_app is retained only as an execute-only compatibility group role.
 *   - neither role may directly read or mutate application relations.
 *
 * These revokes intentionally override the historical direct-table grants
 * above. Keep this block until the legacy grants are removed in a dedicated
 * cleanup migration, so the effective privilege state remains safe.
 * ========================================================================== */

REVOKE ALL PRIVILEGES
ON ALL TABLES IN SCHEMA
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit,
    marketplace,
    finance,
    operations,
    reporting
FROM lego_app;

REVOKE ALL PRIVILEGES
ON ALL SEQUENCES IN SCHEMA
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit,
    marketplace,
    finance,
    operations,
    reporting
FROM lego_app;

REVOKE USAGE ON SCHEMA
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit,
    admin,
    marketplace,
    finance,
    operations,
    reporting
FROM lego_app;

REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA
    app,
    identity,
    reference,
    catalog,
    definition,
    collection,
    wanted,
    moc,
    import,
    audit,
    admin,
    marketplace,
    finance,
    operations,
    reporting
FROM lego_app;

/* Both runtime group roles expose only the reviewed API surface plus
 * non-authorizing request-correlation context. */
GRANT USAGE ON SCHEMA api TO lego_api, lego_app;
/* Deliberately no GRANT EXECUTE ON ALL ROUTINES here.  The runtime callable
 * surface is granted explicitly by 1110_api_surface_lockdown.sql. */

GRANT USAGE ON SCHEMA app TO lego_api, lego_app;
GRANT EXECUTE ON FUNCTION app.set_authenticated_user(uuid)
TO lego_api, lego_app;

GRANT EXECUTE ON FUNCTION app.set_request_context(uuid,text,text)
TO lego_api, lego_app;


/* ==========================================================================
 * Rebrickable Phase 2 canonical reconciliation
 * ==========================================================================
 * lego_importer remains unable to modify canonical reference/catalog/
 * definition tables directly.  Reconciliation is exposed only through this
 * reviewed SECURITY DEFINER function.
 * ========================================================================== */

REVOKE ALL
ON FUNCTION import.reconcile_rebrickable_reference(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION import.reconcile_rebrickable_reference(uuid)
TO lego_importer;


/* ==========================================================================
 * Authoritative Rebrickable importer contract
 * ==========================================================================
 *
 * Phase 1:
 *   - source-run bookkeeping
 *   - validated staging writes
 *
 * Phase 2 / Phase 3:
 *   - canonical reconciliation only through reviewed SECURITY DEFINER routines
 *
 * lego_importer receives NO direct canonical DML on reference/catalog/definition.
 * ========================================================================== */

/* Remove any legacy broad canonical mutation rights first. */
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ALL TABLES IN SCHEMA reference
FROM lego_importer;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ALL TABLES IN SCHEMA catalog
FROM lego_importer;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ALL TABLES IN SCHEMA definition
FROM lego_importer;

/* Schema visibility required by the importer. */
GRANT USAGE ON SCHEMA app TO lego_importer;
GRANT USAGE ON SCHEMA reference TO lego_importer;
GRANT USAGE ON SCHEMA import TO lego_importer;

/* Phase 1 source/staging contract. */
GRANT SELECT
ON TABLE reference.external_sources
TO lego_importer;

GRANT SELECT, INSERT, UPDATE
ON TABLE import.source_runs
TO lego_importer;

GRANT SELECT, INSERT, UPDATE
ON TABLE import.source_run_datasets
TO lego_importer;

GRANT SELECT, INSERT, DELETE
ON TABLE import.source_stage_records
TO lego_importer;

/* UUID helper used by importer-side source-run creation where required. */
REVOKE ALL ON FUNCTION app.uuid_v7() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.uuid_v7() TO lego_importer;

/* Phase 2 reference reconciliation. */
REVOKE ALL
ON FUNCTION import.reconcile_rebrickable_reference(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION import.reconcile_rebrickable_reference(uuid)
TO lego_importer;

/* Importer transaction-local provenance context. */
REVOKE ALL ON FUNCTION app.set_import_context(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.set_import_context(uuid) FROM lego_api, lego_app;
GRANT EXECUTE ON FUNCTION app.set_import_context(uuid) TO lego_importer;
/* Phase 3B checkpointed catalog reconciliation. */
REVOKE ALL
ON FUNCTION import.phase3b_initialize(uuid, boolean)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION import.phase3b_run_checkpoint(uuid, text, text, integer)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION import.phase3b_progress(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION import.phase3b_initialize(uuid, boolean)
TO lego_importer;

GRANT EXECUTE
ON FUNCTION import.phase3b_run_checkpoint(uuid, text, text, integer)
TO lego_importer;

GRANT EXECUTE
ON FUNCTION import.phase3b_progress(uuid)
TO lego_importer;

/* Importer may not create objects in application schemas. */
REVOKE CREATE ON SCHEMA app FROM lego_importer;
REVOKE CREATE ON SCHEMA reference FROM lego_importer;
REVOKE CREATE ON SCHEMA import FROM lego_importer;
REVOKE CREATE ON SCHEMA catalog FROM lego_importer;
REVOKE CREATE ON SCHEMA definition FROM lego_importer;


/* ==========================================================================
 * Rebrickable Phase 4 checkpointed element reconciliation
 * ========================================================================== */
REVOKE ALL
ON FUNCTION import.phase4b_initialize(uuid,boolean)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION import.phase4b_run_checkpoint(uuid,text,text,integer)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION import.phase4b_progress(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION import.phase4b_initialize(uuid,boolean)
TO lego_importer;

GRANT EXECUTE
ON FUNCTION import.phase4b_run_checkpoint(uuid,text,text,integer)
TO lego_importer;

GRANT EXECUTE
ON FUNCTION import.phase4b_progress(uuid)
TO lego_importer;


-- BRICKTRACKR_PHASE6_GRANTS_V1
ALTER TABLE catalog.external_item_relationships OWNER TO lego_owner;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM PUBLIC;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_api;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_app;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_importer;

ALTER FUNCTION import.phase6b_reconcile(uuid) OWNER TO lego_owner;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM lego_api;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM lego_app;
GRANT EXECUTE ON FUNCTION import.phase6b_reconcile(uuid) TO lego_importer;

GRANT EXECUTE ON FUNCTION app.set_import_context(uuid) TO lego_owner;

SELECT pg_temp.bt_mark_completed('1100_security/1107_grants.sql');

-- BEGIN BRICKTRACKR REBRICKABLE PHASE 5 CANONICAL: phase5b importer grants
REVOKE ALL ON FUNCTION import.phase5b_initialize(uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION import.phase5b_run_checkpoint(uuid,text,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION import.phase5b_progress(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION import.phase5b_initialize(uuid,boolean) TO lego_importer;
GRANT EXECUTE ON FUNCTION import.phase5b_run_checkpoint(uuid,text,text,integer) TO lego_importer;
GRANT EXECUTE ON FUNCTION import.phase5b_progress(uuid) TO lego_importer;
-- END BRICKTRACKR REBRICKABLE PHASE 5 CANONICAL: phase5b importer grants
