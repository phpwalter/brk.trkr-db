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
 * ========================================================================== */

GRANT USAGE ON SCHEMA
    app,
    reference,
    catalog,
    definition,
    import,
    audit
TO lego_importer;

GRANT SELECT, INSERT, UPDATE
ON ALL TABLES IN SCHEMA
    reference,
    catalog,
    definition,
    import
TO lego_importer;

GRANT INSERT
ON
    audit.events,
    audit.changes
TO lego_importer;

GRANT USAGE, SELECT
ON ALL SEQUENCES IN SCHEMA
    reference,
    catalog,
    definition,
    import,
    audit
TO lego_importer;

GRANT EXECUTE ON FUNCTION app.uuid_v7()
TO lego_importer;

GRANT EXECUTE
ON ALL FUNCTIONS IN SCHEMA
    catalog,
    definition,
    import
TO lego_importer;

\echo '[PASS] 1107_grants.sql'


/* ==========================================================================
 * Controlled application API role (preferred runtime boundary)
 * ========================================================================== */
GRANT USAGE ON SCHEMA api TO lego_api;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA api TO lego_api;

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
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA api TO lego_app;

GRANT USAGE ON SCHEMA app TO lego_api;
GRANT EXECUTE ON FUNCTION app.set_request_context(uuid,text,text) TO lego_api;
SELECT pg_temp.bt_mark_completed('1100_security/1107_grants.sql');
