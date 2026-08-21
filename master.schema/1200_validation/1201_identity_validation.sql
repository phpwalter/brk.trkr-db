/*
===============================================================================
 File:           1200_validation/1201_identity_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Validate the identity/authentication/ownership domain against
                 the actual 1.0 schema contract.
 Depends On:     Complete 0100_identity domain
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1201_identity_validation.sql', ARRAY['Complete 0100_identity domain']::text[]);



\echo '[1201] Validating identity domain...'

/* Required tables */
SELECT app.assert_table_exists('identity', 'users');
SELECT app.assert_table_exists('identity', 'user_credentials');
SELECT app.assert_table_exists('identity', 'user_sessions');
SELECT app.assert_table_exists('identity', 'one_time_tokens');
SELECT app.assert_table_exists('identity', 'families');
SELECT app.assert_table_exists('identity', 'family_memberships');
SELECT app.assert_table_exists('identity', 'family_member_permissions');
SELECT app.assert_table_exists('identity', 'guardianships');
SELECT app.assert_table_exists('identity', 'owners');

/* Required types */
DO $$
DECLARE
    v_type text;
BEGIN
    FOREACH v_type IN ARRAY ARRAY[
        'identity.account_management_type',
        'identity.account_status',
        'identity.credential_type',
        'identity.one_time_token_purpose',
        'identity.family_status',
        'identity.family_member_role',
        'identity.family_membership_status',
        'identity.owner_type'
    ]
    LOOP
        PERFORM app.assert_true(
            to_regtype(v_type) IS NOT NULL,
            format('Required type "%s" does not exist', v_type)
        );
    END LOOP;
END;
$$;

/* Authentication uniqueness and lifecycle enforcement */
SELECT app.assert_index_exists('identity', 'uq_active_password_per_user');
SELECT app.assert_index_exists('identity', 'uq_active_passkey_identifier');
SELECT app.assert_constraint_exists('identity', 'user_sessions', 'uq_user_sessions_hash');
SELECT app.assert_constraint_exists('identity', 'one_time_tokens', 'uq_one_time_tokens_hash');

/* Families */
SELECT app.assert_constraint_exists('identity', 'families', 'pk_families');
SELECT app.assert_constraint_exists('identity', 'families', 'fk_families_created_by');
SELECT app.assert_constraint_exists('identity', 'families', 'ck_families_name');
SELECT app.assert_constraint_exists('identity', 'families', 'ck_families_archived');
SELECT app.assert_index_exists('identity', 'ix_families_created_by');

/* Memberships: at most one active family per user. */
DO $$
BEGIN
    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT user_id
            FROM identity.family_memberships
            WHERE membership_status = 'ACTIVE'
            GROUP BY user_id
            HAVING count(*) > 1
        ),
        'A user has more than one active family membership'
    );
END;
$$;

/* Permission record is 1:1 with membership; manage implies view. */
SELECT app.assert_constraint_exists(
    'identity', 'family_member_permissions', 'pk_family_member_permissions'
);
SELECT app.assert_constraint_exists(
    'identity', 'family_member_permissions', 'fk_family_member_permissions_membership'
);
SELECT app.assert_constraint_exists(
    'identity', 'family_member_permissions', 'fk_family_member_permissions_updated_by'
);

DO $$
BEGIN
    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT 1
            FROM identity.family_member_permissions
            WHERE (can_manage_family_collection AND NOT can_view_family_collection)
               OR (can_manage_family_wanted AND NOT can_view_family_wanted)
               OR (can_manage_family_mocs AND NOT can_view_family_mocs)
               OR (can_manage_family_storage AND NOT can_view_family_storage)
               OR (can_manage_family_purchases AND NOT can_view_family_purchases)
        ),
        'A family manage permission exists without the corresponding view permission'
    );
END;
$$;

/* Active guardianships must remain valid even if memberships later change. */
DO $$
BEGIN
    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT 1
            FROM identity.guardianships g
            JOIN identity.users child
              ON child.user_id = g.child_user_id
            WHERE g.revoked_at IS NULL
              AND (
                  g.guardian_user_id = g.child_user_id
                  OR child.account_management_type <> 'MANAGED_CHILD'
                  OR NOT EXISTS (
                      SELECT 1
                      FROM identity.family_memberships gm
                      WHERE gm.family_id = g.family_id
                        AND gm.user_id = g.guardian_user_id
                        AND gm.membership_status = 'ACTIVE'
                        AND gm.member_role IN ('PARENT', 'ADULT')
                  )
                  OR NOT EXISTS (
                      SELECT 1
                      FROM identity.family_memberships cm
                      WHERE cm.family_id = g.family_id
                        AND cm.user_id = g.child_user_id
                        AND cm.membership_status = 'ACTIVE'
                        AND cm.member_role = 'CHILD'
                  )
              )
        ),
        'An active guardianship violates family membership or managed-child rules'
    );
END;
$$;

/* Owner principal integrity */
SELECT app.assert_constraint_exists('identity', 'owners', 'pk_owners');
SELECT app.assert_constraint_exists('identity', 'owners', 'fk_owners_user');
SELECT app.assert_constraint_exists('identity', 'owners', 'fk_owners_family');
SELECT app.assert_constraint_exists('identity', 'owners', 'ck_owners_target');
SELECT app.assert_index_exists('identity', 'uq_owners_user');
SELECT app.assert_index_exists('identity', 'uq_owners_family');

DO $$
BEGIN
    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT 1
            FROM identity.owners
            WHERE NOT (
                (owner_type = 'USER' AND user_id IS NOT NULL AND family_id IS NULL)
                OR
                (owner_type = 'FAMILY' AND family_id IS NOT NULL AND user_id IS NULL)
            )
        ),
        'identity.owners contains an invalid owner target'
    );

    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT user_id
            FROM identity.owners
            WHERE owner_type = 'USER'
            GROUP BY user_id
            HAVING count(*) > 1
        ),
        'A user has more than one USER owner principal'
    );

    PERFORM app.assert_true(
        NOT EXISTS (
            SELECT family_id
            FROM identity.owners
            WHERE owner_type = 'FAMILY'
            GROUP BY family_id
            HAVING count(*) > 1
        ),
        'A family has more than one FAMILY owner principal'
    );
END;
$$;

\echo '[PASS] 1201_identity_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1201_identity_validation.sql');
