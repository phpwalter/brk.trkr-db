/*
===============================================================================
 File:           0100_identity/0105_guardianships.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Model explicit lifecycle authority over managed child accounts.
 Depends On:     identity.users
                 identity.families
 Creates:        identity.guardianships
 Key Rules:      Guardianship is distinct from ordinary delegated permissions.
                 Guardian and managed child must be different users.
                 Runtime logic verifies both users are active members of the same
                 family and that the target is a MANAGED_CHILD account.
 Validation:     Enforces active-pair uniqueness and consistent revocation
                 metadata; deeper membership semantics are validated by trigger.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0100_identity/0105_guardianships.sql', ARRAY['identity.users', 'identity.families']::text[]);



CREATE TABLE identity.guardianships (
    guardianship_id uuid NOT NULL DEFAULT app.uuid_v7(),

    family_id uuid NOT NULL,
    guardian_user_id uuid NOT NULL,
    child_user_id uuid NOT NULL,

    created_by_user_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    revoked_at timestamptz,
    revoked_by_user_id uuid,

    CONSTRAINT pk_guardianships
        PRIMARY KEY (guardianship_id),

    CONSTRAINT fk_guardianships_family
        FOREIGN KEY (family_id)
        REFERENCES identity.families(family_id),

    CONSTRAINT fk_guardianships_guardian
        FOREIGN KEY (guardian_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_guardianships_child
        FOREIGN KEY (child_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_guardianships_created_by
        FOREIGN KEY (created_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_guardianships_revoked_by
        FOREIGN KEY (revoked_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_guardianships_distinct
        CHECK (guardian_user_id <> child_user_id),

    CONSTRAINT ck_guardianships_revocation
        CHECK (
            (
                revoked_at IS NULL
                AND revoked_by_user_id IS NULL
            )
            OR
            (
                revoked_at IS NOT NULL
                AND revoked_by_user_id IS NOT NULL
                AND revoked_at >= created_at
            )
        )
);

CREATE UNIQUE INDEX uq_active_guardianship
    ON identity.guardianships(
        family_id,
        guardian_user_id,
        child_user_id
    )
    WHERE revoked_at IS NULL;

CREATE INDEX ix_guardianships_child
    ON identity.guardianships(child_user_id)
    WHERE revoked_at IS NULL;

CREATE INDEX ix_guardianships_guardian
    ON identity.guardianships(guardian_user_id)
    WHERE revoked_at IS NULL;

SELECT app.assert_table_exists('identity', 'guardianships');
SELECT app.assert_index_exists('identity', 'uq_active_guardianship');

\echo '[PASS] 0105_guardianships.sql'
SELECT pg_temp.bt_mark_completed('0100_identity/0105_guardianships.sql');
