/*
===============================================================================
 File:           0100_identity/0103_family_memberships.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store current and historical family memberships.
 Depends On:     identity.users
                 identity.families
 Creates:        identity.family_member_role
                 identity.family_membership_status
                 identity.family_memberships
 Key Rules:      A user may have at most one ACTIVE family membership.
                 Membership role and delegated authorization are separate.
                 Membership history is retained after leaving/removal.
 Validation:     Partial unique indexes enforce one active family per user and
                 one active membership per family/user pair.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0100_identity/0103_family_memberships.sql', ARRAY['identity.users', 'identity.families']::text[]);



CREATE TYPE identity.family_member_role AS ENUM (
    'PARENT',
    'ADULT',
    'CHILD'
);

CREATE TYPE identity.family_membership_status AS ENUM (
    'ACTIVE',
    'LEFT',
    'REMOVED'
);

CREATE TABLE identity.family_memberships (
    family_membership_id uuid NOT NULL DEFAULT app.uuid_v7(),
    family_id uuid NOT NULL,
    user_id uuid NOT NULL,

    member_role identity.family_member_role NOT NULL,

    membership_status identity.family_membership_status
        NOT NULL DEFAULT 'ACTIVE',

    added_by_user_id uuid,

    joined_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz,

    CONSTRAINT pk_family_memberships
        PRIMARY KEY (family_membership_id),

    CONSTRAINT fk_family_memberships_family
        FOREIGN KEY (family_id)
        REFERENCES identity.families(family_id),

    CONSTRAINT fk_family_memberships_user
        FOREIGN KEY (user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_family_memberships_added_by
        FOREIGN KEY (added_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_family_memberships_dates
        CHECK (
            (
                membership_status = 'ACTIVE'
                AND ended_at IS NULL
            )
            OR
            (
                membership_status <> 'ACTIVE'
                AND ended_at IS NOT NULL
                AND ended_at >= joined_at
            )
        )
);

CREATE UNIQUE INDEX uq_active_family_membership_user
    ON identity.family_memberships(user_id)
    WHERE membership_status = 'ACTIVE';

CREATE UNIQUE INDEX uq_active_family_membership_pair
    ON identity.family_memberships(family_id, user_id)
    WHERE membership_status = 'ACTIVE';

CREATE INDEX ix_family_memberships_family
    ON identity.family_memberships(
        family_id,
        membership_status
    );

CREATE INDEX ix_family_memberships_user_history
    ON identity.family_memberships(
        user_id,
        joined_at DESC
    );

SELECT app.assert_table_exists('identity', 'family_memberships');
SELECT app.assert_index_exists(
    'identity',
    'uq_active_family_membership_user'
);

\echo '[PASS] 0103_family_memberships.sql'
SELECT pg_temp.bt_mark_completed('0100_identity/0103_family_memberships.sql');
