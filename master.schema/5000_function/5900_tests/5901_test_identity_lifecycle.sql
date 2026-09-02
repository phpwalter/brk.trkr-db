/*
===============================================================================
 File:           5000_function/5900_tests/5901_test_identity_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for identity resolution, family capability
                 checks, guardianship-based managed-child access, and owner
                 authorization.
 Depends On:     5000_function/5700_system/5700_system_identity.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5901_test_identity_lifecycle.sql', ARRAY['5000_function/5700_system/5700_system_identity.sql']::text[]);

\echo '[TEST] 5901_test_identity_lifecycle.sql'

BEGIN;

/*
 * Establish fixtures for a family (f1) with a PARENT, an ADULT with
 * delegated collection/transfer permissions, and a guardian-managed CHILD,
 * plus an unrelated outsider user and a second unrelated family (f2).
 *
 * identity.users, identity.family_memberships, identity.family_member_permissions
 * and identity.guardianships are all audited, and no request context has
 * been established yet at fixture-insertion time, so their audit triggers
 * are disabled only for this fixture block. This entire test runs inside a
 * transaction and rolls back.
 */
ALTER TABLE identity.users DISABLE TRIGGER trg_audit_users;
ALTER TABLE identity.family_memberships DISABLE TRIGGER trg_audit_family_memberships;
ALTER TABLE identity.family_member_permissions DISABLE TRIGGER trg_audit_family_permissions;
ALTER TABLE identity.guardianships DISABLE TRIGGER trg_audit_guardianships;

INSERT INTO identity.users (
    user_id, username, display_name, account_status, account_management_type, activated_at
)
VALUES
    ('00000000-0000-4000-8000-000000005911'::uuid, 'bt_test_id_parent_5901', 'BrickTrackr Identity Test Parent', 'ACTIVE', 'INDEPENDENT', clock_timestamp()),
    ('00000000-0000-4000-8000-000000005912'::uuid, 'bt_test_id_adult_5901', 'BrickTrackr Identity Test Adult', 'ACTIVE', 'INDEPENDENT', clock_timestamp()),
    ('00000000-0000-4000-8000-000000005913'::uuid, 'bt_test_id_child_5901', 'BrickTrackr Identity Test Child', 'ACTIVE', 'MANAGED_CHILD', clock_timestamp()),
    ('00000000-0000-4000-8000-000000005914'::uuid, 'bt_test_id_outsider_5901', 'BrickTrackr Identity Test Outsider', 'ACTIVE', 'INDEPENDENT', clock_timestamp()),
    ('00000000-0000-4000-8000-000000005915'::uuid, 'bt_test_id_other_5901', 'BrickTrackr Identity Test Other Family', 'ACTIVE', 'INDEPENDENT', clock_timestamp());

INSERT INTO identity.families (family_id, family_name, created_by_user_id)
VALUES
    ('00000000-0000-4000-8000-000000005921'::uuid, 'BrickTrackr Test Family 5901', '00000000-0000-4000-8000-000000005911'::uuid),
    ('00000000-0000-4000-8000-000000005922'::uuid, 'BrickTrackr Test Family 5901b', '00000000-0000-4000-8000-000000005915'::uuid);

INSERT INTO identity.family_memberships (
    family_membership_id, family_id, user_id, member_role, membership_status
)
VALUES
    ('00000000-0000-4000-8000-000000005931'::uuid, '00000000-0000-4000-8000-000000005921'::uuid, '00000000-0000-4000-8000-000000005911'::uuid, 'PARENT', 'ACTIVE'),
    ('00000000-0000-4000-8000-000000005932'::uuid, '00000000-0000-4000-8000-000000005921'::uuid, '00000000-0000-4000-8000-000000005912'::uuid, 'ADULT', 'ACTIVE'),
    ('00000000-0000-4000-8000-000000005933'::uuid, '00000000-0000-4000-8000-000000005921'::uuid, '00000000-0000-4000-8000-000000005913'::uuid, 'CHILD', 'ACTIVE'),
    ('00000000-0000-4000-8000-000000005934'::uuid, '00000000-0000-4000-8000-000000005922'::uuid, '00000000-0000-4000-8000-000000005915'::uuid, 'PARENT', 'ACTIVE');

INSERT INTO identity.family_member_permissions (
    family_membership_id,
    can_manage_family_collection,
    can_view_family_purchases,
    can_transfer_to_family,
    can_transfer_from_family
)
VALUES (
    '00000000-0000-4000-8000-000000005932'::uuid,
    true,
    false,
    true,
    true
);

INSERT INTO identity.guardianships (
    guardianship_id, family_id, guardian_user_id, child_user_id, created_by_user_id
)
VALUES (
    '00000000-0000-4000-8000-000000005941'::uuid,
    '00000000-0000-4000-8000-000000005921'::uuid,
    '00000000-0000-4000-8000-000000005912'::uuid,
    '00000000-0000-4000-8000-000000005913'::uuid,
    '00000000-0000-4000-8000-000000005911'::uuid
);

ALTER TABLE identity.users ENABLE TRIGGER trg_audit_users;
ALTER TABLE identity.family_memberships ENABLE TRIGGER trg_audit_family_memberships;
ALTER TABLE identity.family_member_permissions ENABLE TRIGGER trg_audit_family_permissions;
ALTER TABLE identity.guardianships ENABLE TRIGGER trg_audit_guardianships;

DO $$
DECLARE
    v_parent uuid := '00000000-0000-4000-8000-000000005911'::uuid;
    v_adult uuid := '00000000-0000-4000-8000-000000005912'::uuid;
    v_child uuid := '00000000-0000-4000-8000-000000005913'::uuid;
    v_outsider uuid := '00000000-0000-4000-8000-000000005914'::uuid;
    v_other uuid := '00000000-0000-4000-8000-000000005915'::uuid;
    v_family1 uuid := '00000000-0000-4000-8000-000000005921'::uuid;
    v_family2 uuid := '00000000-0000-4000-8000-000000005922'::uuid;

    v_owner_parent uuid;
    v_owner_parent_again uuid;
    v_owner_family1 uuid;
    v_owner_family1_again uuid;
    v_owner_child uuid;
    v_failed boolean;
BEGIN
    /* -----------------------------------------------------------------
     * identity.current_user_id() / identity.current_user_id_optional()
     * ----------------------------------------------------------------- */
    PERFORM app.clear_request_context();

    PERFORM app.assert_true(
        identity.current_user_id_optional() IS NULL,
        'current_user_id_optional() returned a value with no context established'
    );

    v_failed := false;
    BEGIN
        PERFORM identity.current_user_id();
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '28000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'current_user_id() did not fail closed with no context established');

    PERFORM app.set_request_context(v_parent, gen_random_uuid(), '5901-current-user', 'USER');

    PERFORM app.assert_true(
        identity.current_user_id() = v_parent,
        'current_user_id() did not reflect the established USER context'
    );
    PERFORM app.assert_true(
        identity.current_user_id_optional() = v_parent,
        'current_user_id_optional() did not reflect the established USER context'
    );

    /* Malformed raw GUC content is rejected rather than silently ignored. */
    PERFORM pg_catalog.set_config('app.current_user_id', 'not-a-uuid', true);
    v_failed := false;
    BEGIN
        PERFORM identity.current_user_id();
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '28000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'current_user_id() accepted a malformed user-id GUC');

    v_failed := false;
    BEGIN
        PERFORM identity.current_user_id_optional();
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '28000' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'current_user_id_optional() accepted a malformed user-id GUC');

    PERFORM app.set_request_context(v_parent, gen_random_uuid(), '5901-current-user-2', 'USER');

    /* -----------------------------------------------------------------
     * identity.require_current_user_id()
     * ----------------------------------------------------------------- */
    PERFORM app.assert_true(
        identity.require_current_user_id() = v_parent,
        'require_current_user_id() did not return the established user id'
    );

    PERFORM app.clear_request_context();

    v_failed := false;
    BEGIN
        PERFORM identity.require_current_user_id();
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = '22004' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'require_current_user_id() accepted absent user context');

    /* -----------------------------------------------------------------
     * identity.ensure_owner_for_user() / identity.ensure_owner_for_family()
     * ----------------------------------------------------------------- */
    v_owner_parent := identity.ensure_owner_for_user(v_parent);
    v_owner_parent_again := identity.ensure_owner_for_user(v_parent);

    PERFORM app.assert_true(v_owner_parent IS NOT NULL, 'ensure_owner_for_user() returned NULL');
    PERFORM app.assert_true(
        v_owner_parent = v_owner_parent_again,
        'ensure_owner_for_user() is not idempotent for the same user'
    );

    v_owner_family1 := identity.ensure_owner_for_family(v_family1);
    v_owner_family1_again := identity.ensure_owner_for_family(v_family1);

    PERFORM app.assert_true(v_owner_family1 IS NOT NULL, 'ensure_owner_for_family() returned NULL');
    PERFORM app.assert_true(
        v_owner_family1 = v_owner_family1_again,
        'ensure_owner_for_family() is not idempotent for the same family'
    );

    v_owner_child := identity.ensure_owner_for_user(v_child);

    /* -----------------------------------------------------------------
     * identity.has_family_capability()
     * ----------------------------------------------------------------- */
    PERFORM app.assert_true(
        identity.has_family_capability(v_parent, v_family1, 'COLLECTION', 'MANAGE'),
        'PARENT was denied MANAGE capability it always holds'
    );
    PERFORM app.assert_true(
        identity.has_family_capability(v_parent, v_family1, 'BOGUS', 'MANAGE'),
        'PARENT was denied an unrecognized capability that PARENT role should bypass'
    );

    PERFORM app.assert_true(
        identity.has_family_capability(v_adult, v_family1, 'COLLECTION', 'MANAGE'),
        'ADULT with can_manage_family_collection was denied MANAGE COLLECTION'
    );
    PERFORM app.assert_true(
        NOT identity.has_family_capability(v_adult, v_family1, 'PURCHASES', 'VIEW'),
        'ADULT without can_view_family_purchases was granted VIEW PURCHASES'
    );
    PERFORM app.assert_true(
        NOT identity.has_family_capability(v_adult, v_family1, 'BOGUS', 'MANAGE'),
        'ADULT was granted an unrecognized capability'
    );

    PERFORM app.assert_true(
        NOT identity.has_family_capability(v_outsider, v_family1, 'COLLECTION', 'VIEW'),
        'Non-member was granted family capability'
    );

    /* -----------------------------------------------------------------
     * identity.can_manage_user()
     * ----------------------------------------------------------------- */
    PERFORM app.assert_true(
        identity.can_manage_user(v_parent, v_parent, 'PROFILE'),
        'can_manage_user() denied a user managing themself'
    );
    PERFORM app.assert_true(
        identity.can_manage_user(v_adult, v_child, 'PROFILE'),
        'Active guardian was denied management of a managed child'
    );
    PERFORM app.assert_true(
        NOT identity.can_manage_user(v_adult, v_child, 'FAMILY'),
        'Guardian authority was incorrectly extended to FAMILY capability'
    );
    PERFORM app.assert_true(
        NOT identity.can_manage_user(v_parent, v_child, 'PROFILE'),
        'A non-guardian PARENT family member was granted managed-child authority'
    );
    PERFORM app.assert_true(
        NOT identity.can_manage_user(v_outsider, v_child, 'PROFILE'),
        'An outsider was granted managed-child authority'
    );
    PERFORM app.assert_true(
        NOT identity.can_manage_user(NULL, v_child, 'PROFILE'),
        'can_manage_user() accepted a NULL actor'
    );

    /* -----------------------------------------------------------------
     * identity.can_view_owner() / identity.can_manage_owner()
     * ----------------------------------------------------------------- */
    PERFORM app.assert_true(
        identity.can_manage_owner(v_adult, v_owner_child, 'PROFILE'),
        'Guardian was denied MANAGE on the managed child USER owner'
    );
    PERFORM app.assert_true(
        NOT identity.can_view_owner(v_outsider, v_owner_child, 'PROFILE'),
        'Outsider was granted VIEW on the managed child USER owner'
    );

    PERFORM app.assert_true(
        identity.can_view_owner(v_adult, v_owner_family1, 'COLLECTION'),
        'ADULT with default view collection permission was denied VIEW on the FAMILY owner'
    );
    PERFORM app.assert_true(
        identity.can_manage_owner(v_adult, v_owner_family1, 'COLLECTION'),
        'ADULT with can_manage_family_collection was denied MANAGE on the FAMILY owner'
    );
    PERFORM app.assert_true(
        NOT identity.can_manage_owner(v_adult, v_owner_family1, 'PURCHASES'),
        'ADULT without purchase management was granted MANAGE PURCHASES on the FAMILY owner'
    );
    PERFORM app.assert_true(
        NOT identity.can_view_owner(v_outsider, v_owner_family1, 'COLLECTION'),
        'Outsider was granted VIEW on the FAMILY owner'
    );

    /* -----------------------------------------------------------------
     * identity.can_view_family_shared_owner()
     * ----------------------------------------------------------------- */
    PERFORM app.assert_true(
        identity.can_view_family_shared_owner(v_adult, v_owner_parent, 'COLLECTION'),
        'Family member was denied shared visibility of a co-member''s USER owner'
    );
    PERFORM app.assert_true(
        NOT identity.can_view_family_shared_owner(v_outsider, v_owner_parent, 'COLLECTION'),
        'Outsider was granted shared visibility of a USER owner outside their family'
    );
    PERFORM app.assert_true(
        identity.can_view_family_shared_owner(v_adult, v_owner_family1, 'COLLECTION'),
        'can_view_family_shared_owner() did not delegate to can_view_owner() for a FAMILY owner'
    );

    /* -----------------------------------------------------------------
     * identity.can_transfer_between()
     * ----------------------------------------------------------------- */
    PERFORM app.assert_true(
        identity.can_transfer_between(v_adult, v_owner_family1, v_owner_child),
        'ADULT with transfer-from-family permission and managed-child authority was denied a valid transfer'
    );
    PERFORM app.assert_true(
        NOT identity.can_transfer_between(v_outsider, v_owner_family1, v_owner_child),
        'Outsider was permitted to authorize a transfer involving a family they do not belong to'
    );

    /* -----------------------------------------------------------------
     * identity.validate_guardianship() trigger
     * ----------------------------------------------------------------- */
    v_failed := false;
    BEGIN
        INSERT INTO identity.guardianships (
            family_id, guardian_user_id, child_user_id, created_by_user_id
        )
        VALUES (v_family1, v_outsider, v_child, v_parent);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'validate_guardianship() accepted a guardian with no active PARENT/ADULT membership');

    v_failed := false;
    BEGIN
        INSERT INTO identity.guardianships (
            family_id, guardian_user_id, child_user_id, created_by_user_id
        )
        VALUES (v_family1, v_adult, v_parent, v_parent);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(v_failed, 'validate_guardianship() accepted a non-MANAGED_CHILD guardianship target');

    /* Cross-family membership never leaks family capability. */
    PERFORM app.assert_true(
        NOT identity.has_family_capability(v_other, v_family1, 'COLLECTION', 'VIEW'),
        'A member of an unrelated family was granted capability in family1'
    );
    PERFORM app.assert_true(
        v_family2 IS NOT NULL,
        'Second fixture family was not created'
    );
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5901_test_identity_lifecycle.sql');
