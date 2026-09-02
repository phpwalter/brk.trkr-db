/*
===============================================================================
 File:           1200_validation/1227_api_v3_validation.sql
 Project:        BrickTrackr
 Schema Version: 1.3.1
 PostgreSQL:     16+
 Purpose:        Validate the complete v3 database API contract, additive
                 lifecycle state, concurrency helpers, public visibility reads,
                 and privileged administrator separation.
 Depends On:     1100_security/1114_api_v3_execute.sql
                 1100_security/1113_api_v3_rls.sql
                 1100_security/1110_api_surface_lockdown.sql
                 5000_function/5700_system/5710_system_anonymous_request_context.sql
 Creates:        Validation assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '1200_validation/1227_api_v3_validation.sql',
    ARRAY[
        '1100_security/1114_api_v3_execute.sql',
        '1100_security/1113_api_v3_rls.sql',
        '1100_security/1110_api_surface_lockdown.sql',
        '5000_function/5700_system/5710_system_anonymous_request_context.sql'
    ]::text[]
);

SELECT app.assert_table_exists('collection','collections');
SELECT app.assert_table_exists('collection','collection_memberships');
SELECT app.assert_table_exists('definition','custom_minifigs');

SELECT app.assert_true(
    to_regprocedure('api.catalog_reference_operation(text,jsonb)') IS NOT NULL
    AND to_regprocedure('api.collection_inventory_operation(text,jsonb,jsonb,text)') IS NOT NULL
    AND to_regprocedure('api.wanted_operation(text,jsonb,jsonb,text)') IS NOT NULL
    AND to_regprocedure('api.moc_minifig_operation(text,jsonb,jsonb,text)') IS NOT NULL
    AND to_regprocedure('api.identity_activity_operation(text,jsonb,jsonb,text)') IS NOT NULL
    AND to_regprocedure('api.market_reporting_operation(text,jsonb)') IS NOT NULL
    AND to_regprocedure('api.visibility_read_operation(text,jsonb)') IS NOT NULL
    AND to_regprocedure('api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)') IS NOT NULL,
    'One or more v3 API dispatcher routines are missing'
);

SELECT app.assert_true(
    to_regprocedure('api.etag_for_revision(bigint)') IS NOT NULL
    AND to_regprocedure('api.assert_if_match(text,bigint)') IS NOT NULL,
    'v3 optimistic-concurrency helpers are missing'
);

SELECT app.assert_true(
    to_regprocedure('app.set_anonymous_request_context(uuid,text)') IS NOT NULL,
    'Anonymous public-read request context routine is missing'
);

SELECT app.assert_true(
    has_function_privilege('brktrkr_api','api.catalog_reference_operation(text,jsonb)','EXECUTE')
    AND has_function_privilege('brktrkr_api','api.collection_inventory_operation(text,jsonb,jsonb,text)','EXECUTE')
    AND has_function_privilege('brktrkr_api','api.wanted_operation(text,jsonb,jsonb,text)','EXECUTE')
    AND has_function_privilege('brktrkr_api','api.moc_minifig_operation(text,jsonb,jsonb,text)','EXECUTE')
    AND has_function_privilege('brktrkr_api','api.identity_activity_operation(text,jsonb,jsonb,text)','EXECUTE')
    AND has_function_privilege('brktrkr_api','api.market_reporting_operation(text,jsonb)','EXECUTE')
    AND has_function_privilege('brktrkr_api','api.visibility_read_operation(text,jsonb)','EXECUTE'),
    'brktrkr_api lacks one or more reviewed v3 dispatcher grants'
);

SELECT app.assert_true(
    NOT has_function_privilege('brktrkr_api','api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)','EXECUTE')
    AND has_function_privilege('brktrkr_admin','api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)','EXECUTE')
    AND NOT has_function_privilege('brktrkr_admin','api.admin_finance_operation(text,jsonb,jsonb)','EXECUTE'),
    'Privileged administrator API separation is incorrect'
);

SELECT app.assert_true(
    NOT has_function_privilege('PUBLIC','api.catalog_reference_operation(text,jsonb)','EXECUTE')
    AND NOT has_function_privilege('PUBLIC','api.collection_inventory_operation(text,jsonb,jsonb,text)','EXECUTE')
    AND NOT has_function_privilege('PUBLIC','api.visibility_read_operation(text,jsonb)','EXECUTE')
    AND NOT has_function_privilege('PUBLIC','api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)','EXECUTE'),
    'PUBLIC can execute a v3 API dispatcher'
);

SELECT app.assert_true(
    (SELECT anonymous_safe FROM app.runtime_api_allowlist WHERE routine_signature='api.visibility_read_operation(text,jsonb)')
    AND NOT (SELECT anonymous_safe FROM app.runtime_api_allowlist WHERE routine_signature='api.moc_minifig_operation(text,jsonb,jsonb,text)'),
    'Anonymous-safe API classification is incorrect for authored-resource read/mutation dispatchers'
);

SELECT app.assert_true(
    EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='collection' AND tablename='collections')
    AND EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='collection' AND tablename='collection_memberships')
    AND EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='definition' AND tablename='custom_minifigs'),
    'v3 additive lifecycle tables are missing RLS policies'
);

SELECT app.assert_true(
    (SELECT count(*) FROM app.runtime_api_allowlist)=28,
    'v3 runtime API allowlist cardinality is not 28'
);

\echo '[PASS] 1227_api_v3_validation.sql v1.3.1'
SELECT pg_temp.bt_mark_completed('1200_validation/1227_api_v3_validation.sql');
