/*
===============================================================================
 File:           0100_identity/0104_family_permissions.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define configurable family-scoped capabilities for individual
                 family memberships.
 Depends On:     identity.users
                 identity.families
                 identity.family_memberships
 Creates:        identity.family_member_permissions
 Key Rules:      Authorization is capability-based and must not be inferred
                 solely from family membership role.
                 Each family membership may have at most one configurable
                 permission record.
                 Permissions belong to a membership, not directly to a user,
                 so permissions cannot accidentally cross family boundaries.
                 Management capabilities imply the corresponding visibility
                 capability where applicable.
                 Guardianship and managed-child authority remain separate from
                 these family-scoped permissions.
                 Permission changes identify the user who last changed them.
                 Application authorization must also require an active family
                 membership at runtime.
 Validation:     Verifies the permission table, primary key, foreign keys,
                 named CHECK constraints, and membership uniqueness.
                 Verifies no duplicate permission record can exist for a
                 membership.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0100_identity/0104_family_permissions.sql', ARRAY['identity.users', 'identity.families', 'identity.family_memberships']::text[]);



\echo '[0104] Creating family permissions...'


/* -------------------------------------------------------------------------- */
/* Family member permissions                                                  */
/* -------------------------------------------------------------------------- */

CREATE TABLE identity.family_member_permissions (
    family_membership_id uuid NOT NULL,

    /*
     * Family administration.
     *
     * These permissions govern administration of the family itself. They do
     * not replace guardianship/delegated-management rules for another user's
     * personal resources.
     */
    can_manage_family boolean NOT NULL DEFAULT false,
    can_manage_members boolean NOT NULL DEFAULT false,
    can_manage_permissions boolean NOT NULL DEFAULT false,

    /*
     * Shared family collection.
     */
    can_view_family_collection boolean NOT NULL DEFAULT true,
    can_manage_family_collection boolean NOT NULL DEFAULT false,

    /*
     * Shared family wishlists and build goals.
     */
    can_view_family_wanted boolean NOT NULL DEFAULT true,
    can_manage_family_wanted boolean NOT NULL DEFAULT false,

    /*
     * Shared family MOCs.
     */
    can_view_family_mocs boolean NOT NULL DEFAULT true,
    can_manage_family_mocs boolean NOT NULL DEFAULT false,

    /*
     * Shared storage hierarchy.
     */
    can_view_family_storage boolean NOT NULL DEFAULT true,
    can_manage_family_storage boolean NOT NULL DEFAULT false,

    /*
     * Acquisition and purchase information.
     *
     * Purchase visibility is intentionally independent from general
     * collection visibility because pricing and seller information may be
     * considered more sensitive.
     */
    can_view_family_purchases boolean NOT NULL DEFAULT false,
    can_manage_family_purchases boolean NOT NULL DEFAULT false,

    /*
     * Transfers.
     *
     * This capability permits initiating transfers involving family-owned
     * resources. Transfer business rules are enforced by the collection
     * domain and its runtime functions.
     */
    can_transfer_to_family boolean NOT NULL DEFAULT false,
    can_transfer_from_family boolean NOT NULL DEFAULT false,

    /*
     * Family audit/history visibility.
     */
    can_view_family_audit boolean NOT NULL DEFAULT false,

    /*
     * Administrative metadata.
     */
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    updated_by_user_id uuid,

    CONSTRAINT pk_family_member_permissions
        PRIMARY KEY (family_membership_id),

    CONSTRAINT fk_family_member_permissions_membership
        FOREIGN KEY (family_membership_id)
        REFERENCES identity.family_memberships(family_membership_id)
        ON UPDATE RESTRICT
        ON DELETE CASCADE,

    CONSTRAINT fk_family_member_permissions_updated_by
        FOREIGN KEY (updated_by_user_id)
        REFERENCES identity.users(user_id)
        ON UPDATE RESTRICT
        ON DELETE SET NULL,

    CONSTRAINT ck_family_member_permissions_collection
        CHECK (
            NOT can_manage_family_collection
            OR can_view_family_collection
        ),

    CONSTRAINT ck_family_member_permissions_wanted
        CHECK (
            NOT can_manage_family_wanted
            OR can_view_family_wanted
        ),

    CONSTRAINT ck_family_member_permissions_mocs
        CHECK (
            NOT can_manage_family_mocs
            OR can_view_family_mocs
        ),

    CONSTRAINT ck_family_member_permissions_storage
        CHECK (
            NOT can_manage_family_storage
            OR can_view_family_storage
        ),

    CONSTRAINT ck_family_member_permissions_purchases
        CHECK (
            NOT can_manage_family_purchases
            OR can_view_family_purchases
        ),

    CONSTRAINT ck_family_member_permissions_timestamps
        CHECK (
            updated_at >= created_at
        )
);


/* -------------------------------------------------------------------------- */
/* Documentation                                                              */
/* -------------------------------------------------------------------------- */

COMMENT ON TABLE identity.family_member_permissions IS
    'Configurable capabilities attached to a specific family membership. '
    'Membership roles describe family relationships; this table describes '
    'family-scoped authorization. Guardianship and delegated management of '
    'another user remain separate concerns.';

COMMENT ON COLUMN identity.family_member_permissions.family_membership_id IS
    'Family membership receiving these configurable permissions. Also serves '
    'as the table primary key so each membership has at most one permission '
    'record.';

COMMENT ON COLUMN identity.family_member_permissions.can_manage_family IS
    'Allows administrative changes to family-level configuration, subject to '
    'runtime authorization rules.';

COMMENT ON COLUMN identity.family_member_permissions.can_manage_members IS
    'Allows management of family membership operations permitted by runtime '
    'identity rules.';

COMMENT ON COLUMN identity.family_member_permissions.can_manage_permissions IS
    'Allows modification of configurable family-member permissions. This does '
    'not independently grant guardianship authority.';

COMMENT ON COLUMN identity.family_member_permissions.can_view_family_collection IS
    'Allows visibility of resources owned by the family collection owner.';

COMMENT ON COLUMN identity.family_member_permissions.can_manage_family_collection IS
    'Allows modification of family-owned collection resources. Requires family '
    'collection visibility.';

COMMENT ON COLUMN identity.family_member_permissions.can_view_family_wanted IS
    'Allows visibility of family-owned wishlists and build goals.';

COMMENT ON COLUMN identity.family_member_permissions.can_manage_family_wanted IS
    'Allows modification of family-owned wishlists and build goals. Requires '
    'family wanted-resource visibility.';

COMMENT ON COLUMN identity.family_member_permissions.can_view_family_mocs IS
    'Allows visibility of MOCs owned by the family, subject to MOC visibility '
    'and lifecycle rules.';

COMMENT ON COLUMN identity.family_member_permissions.can_manage_family_mocs IS
    'Allows modification of family-owned MOCs where permitted by MOC lifecycle '
    'rules. Requires family MOC visibility.';

COMMENT ON COLUMN identity.family_member_permissions.can_view_family_storage IS
    'Allows visibility of the family storage-location hierarchy and family '
    'storage allocations.';

COMMENT ON COLUMN identity.family_member_permissions.can_manage_family_storage IS
    'Allows modification of family storage locations and allocations. Requires '
    'family storage visibility.';

COMMENT ON COLUMN identity.family_member_permissions.can_view_family_purchases IS
    'Allows visibility of family acquisition, seller, pricing, and related '
    'purchase information.';

COMMENT ON COLUMN identity.family_member_permissions.can_manage_family_purchases IS
    'Allows modification of family acquisition records where permitted by '
    'collection business rules. Requires purchase visibility.';

COMMENT ON COLUMN identity.family_member_permissions.can_transfer_to_family IS
    'Allows initiating an authorized transfer of eligible personally owned '
    'resources into family ownership. Ownership and guardianship checks remain '
    'enforced separately.';

COMMENT ON COLUMN identity.family_member_permissions.can_transfer_from_family IS
    'Allows initiating an authorized transfer of eligible family-owned '
    'resources out of family ownership. Destination ownership and runtime '
    'authorization rules still apply.';

COMMENT ON COLUMN identity.family_member_permissions.can_view_family_audit IS
    'Allows access to family-scoped audit history where security policies and '
    'audit visibility rules permit it.';

COMMENT ON COLUMN identity.family_member_permissions.created_at IS
    'Timestamp when the configurable permission record was created.';

COMMENT ON COLUMN identity.family_member_permissions.updated_at IS
    'Timestamp of the most recent permission-record modification. Runtime '
    'identity functions are responsible for maintaining this value.';

COMMENT ON COLUMN identity.family_member_permissions.updated_by_user_id IS
    'User responsible for the most recent permission change when known. '
    'Detailed immutable history is recorded by the audit domain.';


/* -------------------------------------------------------------------------- */
/* Supporting indexes                                                         */
/* -------------------------------------------------------------------------- */

/*
 * family_membership_id is already indexed by the primary key.
 *
 * updated_by_user_id requires a supporting index because PostgreSQL does not
 * automatically create indexes for referencing foreign-key columns.
 */
CREATE INDEX ix_family_member_permissions_updated_by
    ON identity.family_member_permissions(updated_by_user_id)
    WHERE updated_by_user_id IS NOT NULL;


/* -------------------------------------------------------------------------- */
/* File-local validation                                                      */
/* -------------------------------------------------------------------------- */

DO $$
DECLARE
    v_constraint text;
BEGIN
    /*
     * Table existence.
     */
    IF to_regclass('identity.family_member_permissions') IS NULL THEN
        RAISE EXCEPTION
            'Required table identity.family_member_permissions was not created';
    END IF;


    /*
     * Required primary-key and foreign-key/check constraints.
     */
    FOREACH v_constraint IN ARRAY ARRAY[
        'pk_family_member_permissions',
        'fk_family_member_permissions_membership',
        'fk_family_member_permissions_updated_by',
        'ck_family_member_permissions_collection',
        'ck_family_member_permissions_wanted',
        'ck_family_member_permissions_mocs',
        'ck_family_member_permissions_storage',
        'ck_family_member_permissions_purchases',
        'ck_family_member_permissions_timestamps'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class t
              ON t.oid = c.conrelid
            JOIN pg_namespace n
              ON n.oid = t.relnamespace
            WHERE n.nspname = 'identity'
              AND t.relname = 'family_member_permissions'
              AND c.conname = v_constraint
        ) THEN
            RAISE EXCEPTION
                'Required constraint "%" is missing from '
                'identity.family_member_permissions',
                v_constraint;
        END IF;
    END LOOP;


    /*
     * Ensure family_membership_id is actually the single-column primary key.
     */
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t
          ON t.oid = c.conrelid
        JOIN pg_namespace n
          ON n.oid = t.relnamespace
        WHERE n.nspname = 'identity'
          AND t.relname = 'family_member_permissions'
          AND c.conname = 'pk_family_member_permissions'
          AND c.contype = 'p'
          AND array_length(c.conkey, 1) = 1
          AND (
              SELECT a.attname
              FROM pg_attribute a
              WHERE a.attrelid = t.oid
                AND a.attnum = c.conkey[1]
          ) = 'family_membership_id'
    ) THEN
        RAISE EXCEPTION
            'identity.family_member_permissions must use '
            'family_membership_id as its single-column primary key';
    END IF;


    /*
     * Supporting FK index.
     */
    IF to_regclass(
        'identity.ix_family_member_permissions_updated_by'
    ) IS NULL THEN
        RAISE EXCEPTION
            'Required index '
            'identity.ix_family_member_permissions_updated_by was not created';
    END IF;
END;
$$;


/* -------------------------------------------------------------------------- */
/* Behavioral validation                                                      */
/* -------------------------------------------------------------------------- */

DO $$
BEGIN
    /*
     * These are metadata-level assertions. No test rows are inserted here
     * because the permission table depends upon real family memberships and
     * the bootstrap must remain deterministic on an otherwise empty database.
     */

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'identity'
          AND table_name = 'family_member_permissions'
          AND column_name = 'can_manage_permissions'
          AND data_type = 'boolean'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'identity.family_member_permissions.can_manage_permissions '
            'must be NOT NULL boolean';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'identity'
          AND table_name = 'family_member_permissions'
          AND column_name = 'can_manage_family_collection'
          AND data_type = 'boolean'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'identity.family_member_permissions.can_manage_family_collection '
            'must be NOT NULL boolean';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'identity'
          AND table_name = 'family_member_permissions'
          AND column_name = 'can_view_family_purchases'
          AND data_type = 'boolean'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'identity.family_member_permissions.can_view_family_purchases '
            'must be NOT NULL boolean';
    END IF;
END;
$$;


\echo '[PASS] 0104_family_permissions.sql'
SELECT pg_temp.bt_mark_completed('0100_identity/0104_family_permissions.sql');
