/*
===============================================================================
 File:           5000_function/5900_tests/5910_test_admin_common.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for shared admin helpers and audit metadata.
 Depends On:     5000_function/5100_admin/5100_admin_common.sql
                 1100_security/1112_admin_execute_only.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5910_test_admin_common.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', '1100_security/1112_admin_execute_only.sql']::text[]);

\echo '[TEST] 5910_test_admin_common.sql'

BEGIN;

/* Non-admin runtime roles must not pass the system-admin guard. */
DO $$
DECLARE
    v_role name;
    v_failed boolean;
BEGIN
    FOR v_role IN
        SELECT rolname
          FROM pg_roles
         WHERE rolname IN ('lego_app','lego_api','lego_importer','lego_reporting')
         ORDER BY rolname
    LOOP
        v_failed := false;
        EXECUTE format('SET LOCAL ROLE %I', v_role);

        BEGIN
            PERFORM admin.assert_system_admin();
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLSTATE IN ('42501','42883') THEN
                    v_failed := true;
                ELSE
                    RESET ROLE;
                    RAISE;
                END IF;
        END;

        RESET ROLE;

        PERFORM app.assert_true(
            v_failed,
            format('%s was not rejected by admin.assert_system_admin()', v_role)
        );
    END LOOP;
END;
$$;

/*
 * lego_admin must not execute the internal guard directly. Positive admin
 * authorization is exercised through the approved SECURITY DEFINER lifecycle
 * entry points in 5911_test_admin_catalog_lifecycle.sql.
 */
DO $$
DECLARE
    v_failed boolean := false;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lego_admin') THEN
        SET LOCAL ROLE lego_admin;

        BEGIN
            PERFORM admin.assert_system_admin();
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLSTATE IN ('42501','42883') THEN
                    v_failed := true;
                ELSE
                    RESET ROLE;
                    RAISE;
                END IF;
        END;

        RESET ROLE;

        PERFORM app.assert_true(
            v_failed,
            'lego_admin unexpectedly executed internal admin.assert_system_admin() directly'
        );
    END IF;
END;
$$;

/* Installed audit trigger must support lifecycle operation/reason metadata. */
SELECT app.assert_true(
    pg_get_functiondef('audit.capture_row_change()'::regprocedure)
        LIKE '%app.audit_reason%'
    AND
    pg_get_functiondef('audit.capture_row_change()'::regprocedure)
        LIKE '%app.audit_operation%',
    'audit.capture_row_change() is missing admin audit metadata support'
);

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5910_test_admin_common.sql');
