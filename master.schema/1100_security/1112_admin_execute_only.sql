/*
===============================================================================
 File:           1100_security/1112_admin_execute_only.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Convert lego_admin from direct-table administration to an
                 execute-only, explicitly granted stored-procedure boundary.
 Depends On:     5000_function/5100_admin/5100_admin_common.sql
                 5000_function/5100_admin/5110_admin_catalog_lifecycle.sql
                 1100_security/1111_role_ownership_separation.sql
 Key Rules:      lego_admin receives no direct table or sequence privileges.
                 lego_admin cannot CREATE in application schemas.
                 Internal catalog/audit routines are not callable by admin.
                 Only explicitly reviewed admin.* entry points are executable.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1112_admin_execute_only.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql', '1100_security/1111_role_ownership_separation.sql']::text[]);

\echo '[SECURITY] Converting lego_admin to execute-only administration...'


/*
 * Remove historical direct relation privileges from lego_admin.
 */
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
FROM lego_admin;

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
FROM lego_admin;


/*
 * Remove historical broad routine access.
 * New admin capabilities are granted by exact signature below.
 */
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
FROM lego_admin;


/*
 * lego_admin may resolve only the schemas needed to establish trusted request
 * context and call reviewed administrative entry points.
 */
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
    api,
    marketplace,
    finance,
    operations,
    reporting
FROM lego_admin;

GRANT USAGE ON SCHEMA app, admin TO lego_admin;


/*
 * Operational roles may never create application objects.
 */
DO $$
DECLARE
    v_schema text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY[
        'app','identity','reference','catalog','definition','collection',
        'wanted','moc','import','audit','api','admin','marketplace',
        'finance','operations','reporting'
    ]
    LOOP
        EXECUTE format(
            'REVOKE CREATE ON SCHEMA %I FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting',
            v_schema
        );
    END LOOP;
END;
$$;


/*
 * Context establishment is stored-procedure access, not table access.
 * app.set_authenticated_user() establishes the internal user UUID.
 * app.set_request_context() establishes request/trace correlation.
 */
GRANT EXECUTE ON FUNCTION app.set_authenticated_user(uuid)
TO lego_admin;

GRANT EXECUTE ON FUNCTION app.set_request_context(uuid,text,text)
TO lego_admin;


/*
 * Internal helpers and lifecycle engine are never directly callable by an
 * operational role.  SECURITY DEFINER admin entry points call them as owner.
 */
REVOKE EXECUTE ON FUNCTION admin.assert_system_admin()
FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting;

REVOKE EXECUTE ON FUNCTION catalog.transition_item_status(
    uuid,
    catalog.item_status,
    text,
    text
)
FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting;


/*
 * Reviewed system-administrator surface.
 */
REVOKE EXECUTE ON FUNCTION admin.retire_catalog_item(uuid,text)
FROM PUBLIC, lego_api, lego_app, lego_importer, lego_reporting;

REVOKE EXECUTE ON FUNCTION admin.archive_catalog_item(uuid,text)
FROM PUBLIC, lego_api, lego_app, lego_importer, lego_reporting;

REVOKE EXECUTE ON FUNCTION admin.restore_catalog_item(uuid,text,text)
FROM PUBLIC, lego_api, lego_app, lego_importer, lego_reporting;

GRANT EXECUTE ON FUNCTION admin.retire_catalog_item(uuid,text)
TO lego_admin;

GRANT EXECUTE ON FUNCTION admin.archive_catalog_item(uuid,text)
TO lego_admin;

GRANT EXECUTE ON FUNCTION admin.restore_catalog_item(uuid,text,text)
TO lego_admin;


/*
 * audit.capture_row_change() is trigger-only.
 */
REVOKE EXECUTE ON FUNCTION audit.capture_row_change()
FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting;


SELECT pg_temp.bt_mark_completed('1100_security/1112_admin_execute_only.sql');
