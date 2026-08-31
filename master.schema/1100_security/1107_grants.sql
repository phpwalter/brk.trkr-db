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
                 5000_function/5000_importer/5012_importer_fail_source_run.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1107_grants.sql', ARRAY['1100_security/1100_roles.sql', '1100_security/1101_rls_identity.sql', '1100_security/1102_rls_collections.sql', '1100_security/1103_rls_wanted.sql', '1100_security/1104_rls_mocs.sql', '1100_security/1105_rls_imports.sql', '1100_security/1106_rls_audit.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql']::text[]);



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
TO brktrkr_api;

/* Public/reference catalog data is filtered by catalog/definition RLS where
 * owner-private unresolved items are involved. */
GRANT SELECT
ON ALL TABLES IN SCHEMA
    reference,
    catalog,
    definition
TO brktrkr_api;

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
TO brktrkr_api;

GRANT SELECT, INSERT
ON collection.transfers
TO brktrkr_api;

/* Wanted/build-goal DML. */
GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA wanted
TO brktrkr_api;

/* MOC DML; RLS and immutability triggers narrow it further. */
GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA moc
TO brktrkr_api;

/* Authentication resources only; ordinary user/profile tables are not exposed. */
GRANT SELECT, INSERT, UPDATE, DELETE
ON
    identity.user_credentials,
    identity.user_sessions,
    identity.one_time_tokens
TO brktrkr_api;

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
TO brktrkr_api;


/* Runtime function surface required by defaults, RLS, and read helpers. */
GRANT EXECUTE ON FUNCTION app.uuid_v7()
TO brktrkr_api;

GRANT EXECUTE ON FUNCTION
    identity.current_user_id(),
    identity.has_family_capability(uuid, uuid, text, text),
    identity.can_manage_user(uuid, uuid, text),
    identity.can_view_owner(uuid, uuid, text),
    identity.can_manage_owner(uuid, uuid, text),
    identity.can_view_family_shared_owner(uuid, uuid, text),
    identity.can_transfer_between(uuid, uuid, uuid)
TO brktrkr_api;

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
TO brktrkr_api;


/* Application sequences used by identity-backed bigint tables. */
GRANT USAGE, SELECT
ON ALL SEQUENCES IN SCHEMA
    collection,
    wanted,
    import
TO brktrkr_api;


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
TO brktrkr_admin;

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
TO brktrkr_admin;

GRANT USAGE, SELECT
ON ALL SEQUENCES IN SCHEMA
    reference,
    catalog,
    definition,
    collection,
    wanted,
    import,
    audit
TO brktrkr_admin;

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
TO brktrkr_admin;


/* ==========================================================================
 * Authoritative importer
 * ==========================================================================
 * Security contract:
 *   - brktrkr_import is a NOLOGIN capability role used only by dedicated
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
FROM brktrkr_import;

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
FROM brktrkr_import;

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
FROM brktrkr_import;

/* Importer needs only these schemas for Phase-1 source-run staging. */
GRANT USAGE ON SCHEMA
    app,
    reference,
    import
TO brktrkr_import;

/* Source registry lookup only. No canonical reference DML. */
GRANT SELECT
ON reference.external_sources
TO brktrkr_import;

/* Source-run lifecycle/provenance. */
GRANT SELECT, INSERT, UPDATE
ON
    import.source_runs,
    import.source_run_datasets
TO brktrkr_import;

/* Run-scoped authoritative staging.
 * DELETE is intentionally permitted only here so a failed/retried dataset can
 * be restaged idempotently within the same source run.
 */
GRANT SELECT, INSERT, DELETE
ON import.source_stage_records
TO brktrkr_import;

/* Identity sequences used by the staging/control tables. */
GRANT USAGE, SELECT
ON SEQUENCE
    import.source_run_datasets_source_run_dataset_id_seq,
    import.source_stage_records_source_stage_record_id_seq
TO brktrkr_import;

/* app.uuid_v7() is required by import.source_runs.source_run_id default. */
GRANT EXECUTE ON FUNCTION app.uuid_v7()
TO brktrkr_import;

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
GRANT USAGE ON SCHEMA api TO brktrkr_api;
/* Runtime EXECUTE grants are applied from the reviewed allowlist in
 * 1110_api_surface_lockdown.sql. */

/* No direct operational table privileges are granted to brktrkr_api. */
GRANT USAGE ON SCHEMA reporting TO brktrkr_reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO brktrkr_reporting;

/* Administrators receive explicit access to the extended domains. */
GRANT USAGE ON SCHEMA admin, marketplace, finance, operations, reporting TO brktrkr_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA marketplace, finance, operations TO brktrkr_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting TO brktrkr_admin;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA admin, api TO brktrkr_admin;

/* Importer may write source-attributed market observations, but not listings/orders/ledger. */
GRANT USAGE ON SCHEMA marketplace TO brktrkr_import;
GRANT SELECT, INSERT, UPDATE ON marketplace.market_price_observations TO brktrkr_import;

GRANT USAGE ON SCHEMA app TO brktrkr_api;
GRANT EXECUTE ON FUNCTION app.set_authenticated_user(uuid) TO brktrkr_api;
GRANT EXECUTE ON FUNCTION app.set_request_context(uuid,text,text) TO brktrkr_api;


/* ==========================================================================
 * Runtime execute-only hardening
 * ==========================================================================
 * Security contract:
 *   - brktrkr_api is the sole application runtime capability role.
 *   - brktrkr_api may not directly read or mutate application relations.
 *
 * These revokes establish the deny-by-default direct-table runtime boundary.
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
FROM brktrkr_api;

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
FROM brktrkr_api;

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
FROM brktrkr_api;

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
FROM brktrkr_api;

/* The runtime API role exposes only the reviewed API surface plus
 * non-authorizing request-correlation context. */
GRANT USAGE ON SCHEMA api TO brktrkr_api;
/* Deliberately no GRANT EXECUTE ON ALL ROUTINES here.  The runtime callable
 * surface is granted explicitly by 1110_api_surface_lockdown.sql. */

GRANT USAGE ON SCHEMA app TO brktrkr_api;
GRANT EXECUTE ON FUNCTION app.set_authenticated_user(uuid)
TO brktrkr_api;

GRANT EXECUTE ON FUNCTION app.set_request_context(uuid,text,text)
TO brktrkr_api;


/* ==========================================================================
 * Rebrickable Phase 2 canonical reconciliation
 * ==========================================================================
 * brktrkr_import remains unable to modify canonical reference/catalog/
 * definition tables directly.  Reconciliation is exposed only through this
 * reviewed SECURITY DEFINER function.
 * ========================================================================== */

REVOKE ALL
ON FUNCTION import.reconcile_rebrickable_reference(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION import.reconcile_rebrickable_reference(uuid)
TO brktrkr_import;


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
 * brktrkr_import receives NO direct canonical DML on reference/catalog/definition.
 * ========================================================================== */

/* Remove any legacy broad canonical mutation rights first. */
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ALL TABLES IN SCHEMA reference
FROM brktrkr_import;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ALL TABLES IN SCHEMA catalog
FROM brktrkr_import;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ALL TABLES IN SCHEMA definition
FROM brktrkr_import;

/* Schema visibility required by the importer. */
GRANT USAGE ON SCHEMA app TO brktrkr_import;
GRANT USAGE ON SCHEMA reference TO brktrkr_import;
GRANT USAGE ON SCHEMA import TO brktrkr_import;

/* Phase 1 source/staging contract. */
GRANT SELECT
ON TABLE reference.external_sources
TO brktrkr_import;

GRANT SELECT, INSERT, UPDATE
ON TABLE import.source_runs
TO brktrkr_import;

GRANT SELECT, INSERT, UPDATE
ON TABLE import.source_run_datasets
TO brktrkr_import;

GRANT SELECT, INSERT, DELETE
ON TABLE import.source_stage_records
TO brktrkr_import;

/* UUID helper used by importer-side source-run creation where required. */
REVOKE ALL ON FUNCTION app.uuid_v7() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.uuid_v7() TO brktrkr_import;

/* Phase 2 reference reconciliation. */
REVOKE ALL
ON FUNCTION import.reconcile_rebrickable_reference(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION import.reconcile_rebrickable_reference(uuid)
TO brktrkr_import;

/* Importer transaction-local provenance context. */
REVOKE ALL ON FUNCTION app.set_import_context(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION app.set_import_context(uuid) FROM brktrkr_api;
GRANT EXECUTE ON FUNCTION app.set_import_context(uuid) TO brktrkr_import;
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
TO brktrkr_import;

GRANT EXECUTE
ON FUNCTION import.phase3b_run_checkpoint(uuid, text, text, integer)
TO brktrkr_import;

GRANT EXECUTE
ON FUNCTION import.phase3b_progress(uuid)
TO brktrkr_import;

/* Importer may not create objects in application schemas. */
REVOKE CREATE ON SCHEMA app FROM brktrkr_import;
REVOKE CREATE ON SCHEMA reference FROM brktrkr_import;
REVOKE CREATE ON SCHEMA import FROM brktrkr_import;
REVOKE CREATE ON SCHEMA catalog FROM brktrkr_import;
REVOKE CREATE ON SCHEMA definition FROM brktrkr_import;


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
TO brktrkr_import;

GRANT EXECUTE
ON FUNCTION import.phase4b_run_checkpoint(uuid,text,text,integer)
TO brktrkr_import;

GRANT EXECUTE
ON FUNCTION import.phase4b_progress(uuid)
TO brktrkr_import;


-- BRICKTRACKR_PHASE6_GRANTS_V1
ALTER TABLE catalog.external_item_relationships OWNER TO brktrkr_owner;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM PUBLIC;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM brktrkr_api;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM brktrkr_api;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM brktrkr_import;

ALTER FUNCTION import.phase6b_reconcile(uuid) OWNER TO brktrkr_owner;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM brktrkr_api;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM brktrkr_api;
GRANT EXECUTE ON FUNCTION import.phase6b_reconcile(uuid) TO brktrkr_import;

GRANT EXECUTE ON FUNCTION app.set_import_context(uuid) TO brktrkr_owner;


/* Canonical source-run completion lifecycle. */
REVOKE ALL
ON FUNCTION import.complete_source_run(uuid, jsonb)
FROM PUBLIC, brktrkr_api;

GRANT EXECUTE
ON FUNCTION import.complete_source_run(uuid, jsonb)
TO brktrkr_import;


/* Canonical source-run failure lifecycle. */
REVOKE ALL
ON FUNCTION import.fail_source_run(uuid, text)
FROM PUBLIC, brktrkr_api;

GRANT EXECUTE
ON FUNCTION import.fail_source_run(uuid, text)
TO brktrkr_import;



-- BEGIN BRICKTRACKR REBRICKABLE PHASE 5 CANONICAL: phase5b importer grants
REVOKE ALL ON FUNCTION import.phase5b_initialize(uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION import.phase5b_run_checkpoint(uuid,text,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION import.phase5b_progress(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION import.phase5b_initialize(uuid,boolean) TO brktrkr_import;
GRANT EXECUTE ON FUNCTION import.phase5b_run_checkpoint(uuid,text,text,integer) TO brktrkr_import;
GRANT EXECUTE ON FUNCTION import.phase5b_progress(uuid) TO brktrkr_import;
-- END BRICKTRACKR REBRICKABLE PHASE 5 CANONICAL: phase5b importer grants

SELECT pg_temp.bt_mark_completed('1100_security/1107_grants.sql');
