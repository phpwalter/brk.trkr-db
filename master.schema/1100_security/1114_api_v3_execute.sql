/*
===============================================================================
 File:           1100_security/1114_api_v3_execute.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Grant the v3 stored-routine API surface to the correct runtime
                 database capability roles without granting direct business-table
                 access.
 Depends On:     api.catalog_reference_operation()
                 api.collection_inventory_operation()
                 api.wanted_operation()
                 api.moc_minifig_operation()
                 api.identity_activity_operation()
                 api.market_reporting_operation()
                 api.admin_finance_operation()
                 brktrkr_api role
                 brktrkr_admin role
 Key Rules:      Normal application operations execute as brktrkr_api. Privileged
                 administration/finance operations execute only as brktrkr_admin.
                 PUBLIC receives no execute authority.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '1100_security/1114_api_v3_execute.sql',
    ARRAY[
        'api.catalog_reference_operation()',
        'api.collection_inventory_operation()',
        'api.wanted_operation()',
        'api.moc_minifig_operation()',
        'api.identity_activity_operation()',
        'api.market_reporting_operation()',
        'api.admin_finance_operation()',
        'brktrkr_api role',
        'brktrkr_admin role'
    ]::text[]
);

REVOKE ALL ON FUNCTION api.catalog_reference_operation(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.collection_inventory_operation(text,jsonb,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.wanted_operation(text,jsonb,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.moc_minifig_operation(text,jsonb,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.identity_activity_operation(text,jsonb,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.market_reporting_operation(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_finance_operation(text,jsonb,jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.catalog_reference_operation(text,jsonb) TO brktrkr_api, brktrkr_admin;
GRANT EXECUTE ON FUNCTION api.collection_inventory_operation(text,jsonb,jsonb,text) TO brktrkr_api, brktrkr_admin;
GRANT EXECUTE ON FUNCTION api.wanted_operation(text,jsonb,jsonb,text) TO brktrkr_api, brktrkr_admin;
GRANT EXECUTE ON FUNCTION api.moc_minifig_operation(text,jsonb,jsonb,text) TO brktrkr_api, brktrkr_admin;
GRANT EXECUTE ON FUNCTION api.identity_activity_operation(text,jsonb,jsonb,text) TO brktrkr_api, brktrkr_admin;
GRANT EXECUTE ON FUNCTION api.market_reporting_operation(text,jsonb) TO brktrkr_api, brktrkr_admin;
GRANT EXECUTE ON FUNCTION api.admin_finance_operation(text,jsonb,jsonb) TO brktrkr_admin;

GRANT EXECUTE ON FUNCTION api.etag_for_revision(bigint) TO brktrkr_api, brktrkr_admin;
GRANT EXECUTE ON FUNCTION api.assert_if_match(text,bigint) TO brktrkr_api, brktrkr_admin;
GRANT EXECUTE ON FUNCTION api.current_user_owner_id() TO brktrkr_api, brktrkr_admin;

\echo '[PASS] 1114_api_v3_execute.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1114_api_v3_execute.sql');
