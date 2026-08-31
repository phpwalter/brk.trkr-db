\set ON_ERROR_STOP on

/*
===============================================================================
 File:           5000_function/5900_tests/5979_test_system_request_context.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Bootstrap-safe unit regression checks for the canonical
                 request-context functions.
 Depends On:     5000_function/5700_system/5709_system_request_context.sql
 Creates:        No persistent test data
===============================================================================
*/

SELECT pg_temp.bt_preflight('5000_function/5900_tests/5979_test_system_request_context.sql', ARRAY['5000_function/5700_system/5709_system_request_context.sql']::text[]);

\echo '[TEST] 5979_test_system_request_context.sql'

DO $test$
DECLARE
    v_req_a uuid := '00000000-0000-7000-8000-000000005979';
    v_req_b uuid := '00000000-0000-7000-8000-000000005980';
    v_can_system boolean;
BEGIN
    /* Start from a deterministic anonymous context. */
    PERFORM app.clear_request_context();

    IF identity.current_user_id() IS NOT NULL
       OR app.current_request_id() IS NOT NULL
       OR app.current_trace_id() IS NOT NULL
       OR app.current_actor_class() IS NOT NULL THEN
        RAISE EXCEPTION 'clear_request_context() did not establish an empty context'
            USING ERRCODE = 'P0001';
    END IF;

    /* Clear must be idempotent. */
    PERFORM app.clear_request_context();
    IF identity.current_user_id() IS NOT NULL
       OR app.current_request_id() IS NOT NULL
       OR app.current_trace_id() IS NOT NULL
       OR app.current_actor_class() IS NOT NULL THEN
        RAISE EXCEPTION 'clear_request_context() is not idempotent'
            USING ERRCODE = 'P0001';
    END IF;

    /*
     * Bootstrap sessions vary by deployment model. Exercise the actual setter
     * when the authenticated session has SYSTEM authority; the external
     * adversarial runner always tests all real login-role combinations.
     */
    v_can_system :=
        pg_catalog.pg_has_role(SESSION_USER, 'brktrkr_migrator', 'MEMBER')
        OR pg_catalog.pg_has_role(SESSION_USER, 'brktrkr_owner', 'MEMBER');

    IF v_can_system THEN
        PERFORM app.set_request_context(
            NULL,
            v_req_a,
            'bootstrap-system-a',
            'SYSTEM'
        );

        IF identity.current_user_id() IS NOT NULL
           OR app.current_request_id() <> v_req_a
           OR app.current_trace_id() <> 'bootstrap-system-a'
           OR app.current_actor_class() <> 'SYSTEM' THEN
            RAISE EXCEPTION 'SYSTEM request context was not established correctly'
                USING ERRCODE = 'P0001';
        END IF;

        /*
         * PL/pgSQL exception blocks are subtransactions. A failed inner block
         * must restore the request context that existed at its entry.
         */
        BEGIN
            PERFORM app.set_request_context(
                NULL,
                v_req_b,
                'bootstrap-system-b',
                'SYSTEM'
            );

            IF app.current_request_id() <> v_req_b THEN
                RAISE EXCEPTION 'Nested request context was not established'
                    USING ERRCODE = 'P0001';
            END IF;

            RAISE EXCEPTION 'intentional subtransaction rollback'
                USING ERRCODE = 'P5799';

        EXCEPTION
            WHEN SQLSTATE 'P5799' THEN
                NULL;
        END;

        IF app.current_request_id() <> v_req_a
           OR app.current_trace_id() <> 'bootstrap-system-a'
           OR app.current_actor_class() <> 'SYSTEM' THEN
            RAISE EXCEPTION
                'Subtransaction rollback did not restore the prior request context'
                USING ERRCODE = 'P0001';
        END IF;

        /* Invalid input must fail without replacing the valid outer context. */
        BEGIN
            PERFORM app.set_request_context(
                NULL,
                v_req_b,
                '   ',
                'SYSTEM'
            );
            RAISE EXCEPTION 'Whitespace-only trace_id was accepted'
                USING ERRCODE = 'P0001';
        EXCEPTION
            WHEN SQLSTATE '22023' THEN
                NULL;
        END;

        IF app.current_request_id() <> v_req_a
           OR app.current_trace_id() <> 'bootstrap-system-a' THEN
            RAISE EXCEPTION
                'Rejected setter call altered the prior request context'
                USING ERRCODE = 'P0001';
        END IF;

        PERFORM app.clear_request_context();
    ELSE
        RAISE NOTICE
            '5979: bootstrap session % lacks SYSTEM authority; setter role-matrix tests are delegated to tools/test_transaction_context.ps1',
            SESSION_USER;
    END IF;

    IF identity.current_user_id() IS NOT NULL
       OR app.current_request_id() IS NOT NULL
       OR app.current_trace_id() IS NOT NULL
       OR app.current_actor_class() IS NOT NULL THEN
        RAISE EXCEPTION '5979 left transaction context behind'
            USING ERRCODE = 'P0001';
    END IF;

    BEGIN
        PERFORM identity.require_current_user_id();
        RAISE EXCEPTION 'require_current_user_id() accepted absent user context'
            USING ERRCODE = 'P0001';
    EXCEPTION
        WHEN SQLSTATE '22004' THEN
            NULL;
    END;
END;
$test$;

\echo '[PASS] 5979_test_system_request_context.sql'

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5979_test_system_request_context.sql');
