/*
===============================================================================
 File:           1200_validation/1216_adversarial_authorization_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Exercise hostile authorization scenarios so future schema or
                 API changes cannot silently weaken caller isolation.
 Depends On:     1200_validation/1215_security_contract_validation.sql
                 identity.current_user_id()
                 identity.can_manage_user()
                 identity.has_family_capability()
                 api.mark_notification_read(uuid)
 Creates:        Validation assertions only
 Key Rules:      Caller identity comes only from app.current_user_id.
                 Frontend/JWT role hints are never database authorization input.
                 Cross-user access fails.
                 Revoked guardianship fails immediately.
                 Runtime roles cannot execute admin routines.
                 Test fixtures leave no persistent rows.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1216_adversarial_authorization_validation.sql', ARRAY['1200_validation/1215_security_contract_validation.sql', 'identity.current_user_id()', 'identity.can_manage_user()', 'identity.has_family_capability()', 'api.mark_notification_read(uuid)']::text[]);

\echo '[VALIDATE] 1216_adversarial_authorization_validation.sql'

/*
 * Static guard: database authorization must not consume JWT/frontend role
 * claims. Role claims may be used by the UI, but PostgreSQL authorizes from
 * current database state.
 */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('api','identity')
          AND (
              lower(coalesce(p.prosrc,'')) LIKE '%app.jwt_role%'
              OR lower(coalesce(p.prosrc,'')) LIKE '%app.jwt_roles%'
              OR lower(coalesce(p.prosrc,'')) LIKE '%app.frontend_role%'
              OR lower(coalesce(p.prosrc,'')) LIKE '%app.frontend_roles%'
          )
    ),
    'Database authorization routines must not consume JWT/frontend role claims'
);

/* Runtime roles must never cross into the administrative routine surface. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'admin'
          AND (
              has_function_privilege('brktrkr_api', p.oid, 'EXECUTE')
              OR has_function_privilege('brktrkr_api', p.oid, 'EXECUTE')
          )
    ),
    'Runtime roles must not execute admin.* routines'
);

/*
 * Behavioral hostile-path tests.
 *
 * The inner PL/pgSQL block is intentionally rolled back using a private
 * SQLSTATE after all assertions pass. PostgreSQL exception blocks are
 * subtransactions, so users, family records, notifications, audit rows and
 * configuration changes created here do not survive validation.
 */
DO $adversarial$
DECLARE
    v_user_a uuid := '00000000-0000-7000-8000-0000000000a1';
    v_user_b uuid := '00000000-0000-7000-8000-0000000000b2';
    v_child  uuid := '00000000-0000-7000-8000-0000000000c3';
    v_family uuid := '00000000-0000-7000-8000-0000000000f1';
    v_membership_a uuid := '00000000-0000-7000-8000-0000000000d1';
    v_membership_child uuid := '00000000-0000-7000-8000-0000000000d2';
    v_guardianship uuid := '00000000-0000-7000-8000-0000000000e1';
    v_notification uuid := '00000000-0000-7000-8000-0000000000e2';
    v_result boolean;
BEGIN
    BEGIN
        /*
         * Establish actor A before fixture writes because audited identity
         * tables require authenticated actor context.
         */
        PERFORM set_config('app.current_user_id', v_user_a::text, true);

        INSERT INTO identity.users(
            user_id, username, display_name, account_management_type,
            account_status, activated_at
        )
        VALUES
            (v_user_a, 'bt_security_test_a', 'Security Test A',
             'INDEPENDENT', 'ACTIVE', now()),
            (v_user_b, 'bt_security_test_b', 'Security Test B',
             'INDEPENDENT', 'ACTIVE', now()),
            (v_child, 'bt_security_test_child', 'Security Test Child',
             'MANAGED_CHILD', 'ACTIVE', now());

        INSERT INTO identity.families(
            family_id, family_name, created_by_user_id
        )
        VALUES (v_family, 'Security Contract Test Family', v_user_a);

        INSERT INTO identity.family_memberships(
            family_membership_id, family_id, user_id, member_role,
            membership_status, added_by_user_id
        )
        VALUES
            (v_membership_a, v_family, v_user_a, 'PARENT', 'ACTIVE', v_user_a),
            (v_membership_child, v_family, v_child, 'CHILD', 'ACTIVE', v_user_a);

        INSERT INTO identity.guardianships(
            guardianship_id, family_id, guardian_user_id, child_user_id,
            created_by_user_id
        )
        VALUES (
            v_guardianship, v_family, v_user_a, v_child, v_user_a
        );

        /* A may manage self but not unrelated B. */
        PERFORM app.assert_true(
            identity.can_manage_user(v_user_a, v_user_a, 'PROFILE'),
            'Authenticated user must be able to manage their own profile'
        );
        PERFORM app.assert_true(
            NOT identity.can_manage_user(v_user_a, v_user_b, 'PROFILE'),
            'User A must not be able to manage unrelated User B'
        );

        /* Active guardianship grants managed-child authority. */
        PERFORM app.assert_true(
            identity.can_manage_user(v_user_a, v_child, 'PROFILE'),
            'Active guardian must be able to manage managed child'
        );

        /* Revocation must take effect immediately. */
        UPDATE identity.guardianships
           SET revoked_at = now(),
               revoked_by_user_id = v_user_a
         WHERE guardianship_id = v_guardianship;

        PERFORM app.assert_true(
            NOT identity.can_manage_user(v_user_a, v_child, 'PROFILE'),
            'Revoked guardianship must deny managed-child authority immediately'
        );

        /*
         * A forged/stale frontend role hint must not alter DB authorization.
         * The database intentionally ignores this GUC.
         */
        PERFORM set_config('app.jwt_roles', '["admin"]', true);
        PERFORM app.assert_true(
            NOT identity.can_manage_user(v_user_a, v_user_b, 'PROFILE'),
            'Frontend/JWT admin role hint must not authorize User A over User B'
        );

        /*
         * Cross-user API test: A cannot mark B's notification read because the
         * stored routine derives caller identity from the trusted DB context.
         */
        INSERT INTO operations.notifications(
            notification_id, user_id, notification_type, title
        )
        VALUES (
            v_notification, v_user_b, 'SECURITY_TEST',
            'Cross-user authorization test'
        );

        v_result := api.mark_notification_read(v_notification);

        PERFORM app.assert_true(
            v_result IS FALSE,
            'User A must not mark User B notification as read'
        );

        PERFORM app.assert_true(
            NOT (SELECT is_read
                 FROM operations.notifications
                 WHERE notification_id = v_notification),
            'Cross-user API attempt changed User B notification'
        );

        /* Missing identity must fail closed at a protected API boundary. */
        PERFORM set_config('app.current_user_id', '', true);
        BEGIN
            PERFORM api.mark_notification_read(v_notification);
            RAISE EXCEPTION
                'Protected API call unexpectedly accepted missing identity';
        EXCEPTION
            WHEN SQLSTATE '28000' THEN
                NULL;
        END;

        /* Roll back all adversarial fixtures and their audit rows. */
        RAISE EXCEPTION 'BT adversarial fixture rollback'
            USING ERRCODE = 'ZX003';

    EXCEPTION
        WHEN SQLSTATE 'ZX003' THEN
            NULL;
    END;
END;
$adversarial$;

\echo '[VALIDATE PASS] 1216_adversarial_authorization_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1216_adversarial_authorization_validation.sql');
