/*
===============================================================================
 File:           0100_identity/0106_owners.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define durable ownership principals for user-owned and
                 family-owned application resources.
 Depends On:     app.uuid_v7()
                 identity.users
                 identity.families
 Creates:        identity.owner_type
                 identity.owners
 Key Rules:      Every ownership principal represents exactly one USER or one
                 FAMILY.
                 User and family identifiers are never simultaneously present.
                 A user may have at most one USER ownership principal.
                 A family may have at most one FAMILY ownership principal.
                 Ownership principals use internal UUIDv7 identifiers so
                 downstream domains do not need polymorphic user/family
                 foreign keys.
                 Ownership is distinct from authorization: family membership,
                 guardianship, and delegated permissions determine who may act
                 upon an owner's resources.
                 Ownership principals are durable and must not be reused for a
                 different user or family.
 Validation:     Verifies enum values, table existence, primary and foreign
                 keys, target exclusivity constraints, partial unique indexes,
                 required column types, and one-target ownership invariants.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0100_identity/0106_owners.sql', ARRAY['app.uuid_v7()', 'identity.users', 'identity.families']::text[]);



\echo '[0106] Creating ownership principals...'


/* ==========================================================================
 * Ownership principal type
 * ========================================================================== */

CREATE TYPE identity.owner_type AS ENUM (
    'USER',
    'FAMILY'
);

COMMENT ON TYPE identity.owner_type IS
    'Identifies whether an ownership principal represents an individual user '
    'or a family. Authorization to act for that principal is modeled '
    'separately through memberships, permissions, and guardianships.';


/* ==========================================================================
 * Ownership principals
 * ========================================================================== */

CREATE TABLE identity.owners (
    owner_id uuid NOT NULL DEFAULT app.uuid_v7(),

    owner_type identity.owner_type NOT NULL,

    user_id uuid,
    family_id uuid,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_owners
        PRIMARY KEY (owner_id),

    CONSTRAINT fk_owners_user
        FOREIGN KEY (user_id)
        REFERENCES identity.users(user_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,

    CONSTRAINT fk_owners_family
        FOREIGN KEY (family_id)
        REFERENCES identity.families(family_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,

    /*
     * The discriminator and target columns must agree exactly:
     *
     * USER   -> user_id present, family_id absent
     * FAMILY -> family_id present, user_id absent
     */
    CONSTRAINT ck_owners_target
        CHECK (
            (
                owner_type = 'USER'
                AND user_id IS NOT NULL
                AND family_id IS NULL
            )
            OR
            (
                owner_type = 'FAMILY'
                AND family_id IS NOT NULL
                AND user_id IS NULL
            )
        )
);


COMMENT ON TABLE identity.owners IS
    'Durable ownership principals used by owner-scoped application domains. '
    'Each row represents exactly one user or one family, allowing downstream '
    'tables to reference a single owner_id instead of maintaining separate '
    'user_id and family_id foreign keys.';


COMMENT ON COLUMN identity.owners.owner_id IS
    'Internal UUIDv7 identifier for the ownership principal. Downstream '
    'owner-scoped resources reference this value.';

COMMENT ON COLUMN identity.owners.owner_type IS
    'Discriminator identifying whether this owner represents a USER or FAMILY.';

COMMENT ON COLUMN identity.owners.user_id IS
    'User represented by this ownership principal when owner_type is USER. '
    'NULL for FAMILY ownership principals.';

COMMENT ON COLUMN identity.owners.family_id IS
    'Family represented by this ownership principal when owner_type is FAMILY. '
    'NULL for USER ownership principals.';

COMMENT ON COLUMN identity.owners.created_at IS
    'Timestamp when the ownership principal was created.';


/* ==========================================================================
 * Uniqueness
 *
 * Each user and each family receives at most one ownership principal.
 *
 * Partial unique indexes express the polymorphic uniqueness directly and
 * avoid relying upon nullable UNIQUE constraints whose intent is less clear.
 * ========================================================================== */

CREATE UNIQUE INDEX uq_owners_user
    ON identity.owners(user_id)
    WHERE owner_type = 'USER'
      AND user_id IS NOT NULL;


CREATE UNIQUE INDEX uq_owners_family
    ON identity.owners(family_id)
    WHERE owner_type = 'FAMILY'
      AND family_id IS NOT NULL;


/* ==========================================================================
 * Foreign-key support indexes
 *
 * The unique partial indexes above already provide efficient access paths for
 * the two foreign-key columns, so separate duplicate indexes are unnecessary.
 * ========================================================================== */


/* ==========================================================================
 * File-local validation
 * ========================================================================== */

DO $$
DECLARE
    v_enum_values text[];
BEGIN
    /* ----------------------------------------------------------------------
     * Enum existence and exact value ordering.
     * ---------------------------------------------------------------------- */

    IF to_regtype('identity.owner_type') IS NULL THEN
        RAISE EXCEPTION
            'Required enum identity.owner_type was not created';
    END IF;

    SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
    INTO v_enum_values
    FROM pg_type t
    JOIN pg_namespace n
      ON n.oid = t.typnamespace
    JOIN pg_enum e
      ON e.enumtypid = t.oid
    WHERE n.nspname = 'identity'
      AND t.typname = 'owner_type';

    IF v_enum_values IS DISTINCT FROM ARRAY[
        'USER',
        'FAMILY'
    ]::text[] THEN
        RAISE EXCEPTION
            'identity.owner_type contains unexpected values: %',
            v_enum_values;
    END IF;


    /* ----------------------------------------------------------------------
     * Table existence.
     * ---------------------------------------------------------------------- */

    IF to_regclass('identity.owners') IS NULL THEN
        RAISE EXCEPTION
            'Required table identity.owners was not created';
    END IF;
END;
$$;


/* --------------------------------------------------------------------------
 * Required constraint validation
 * -------------------------------------------------------------------------- */

DO $$
DECLARE
    v_constraint text;
BEGIN
    FOREACH v_constraint IN ARRAY ARRAY[
        'pk_owners',
        'fk_owners_user',
        'fk_owners_family',
        'ck_owners_target'
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
              AND t.relname = 'owners'
              AND c.conname = v_constraint
        ) THEN
            RAISE EXCEPTION
                'Required constraint "%" is missing from identity.owners',
                v_constraint;
        END IF;
    END LOOP;
END;
$$;


/* --------------------------------------------------------------------------
 * Primary-key validation
 * -------------------------------------------------------------------------- */

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t
          ON t.oid = c.conrelid
        JOIN pg_namespace n
          ON n.oid = t.relnamespace
        WHERE n.nspname = 'identity'
          AND t.relname = 'owners'
          AND c.conname = 'pk_owners'
          AND c.contype = 'p'
          AND array_length(c.conkey, 1) = 1
          AND (
              SELECT a.attname
              FROM pg_attribute a
              WHERE a.attrelid = t.oid
                AND a.attnum = c.conkey[1]
          ) = 'owner_id'
    ) THEN
        RAISE EXCEPTION
            'identity.owners must use owner_id as its single-column primary key';
    END IF;
END;
$$;


/* --------------------------------------------------------------------------
 * Foreign-key validation
 * -------------------------------------------------------------------------- */

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class src
          ON src.oid = c.conrelid
        JOIN pg_namespace src_ns
          ON src_ns.oid = src.relnamespace
        JOIN pg_class dst
          ON dst.oid = c.confrelid
        JOIN pg_namespace dst_ns
          ON dst_ns.oid = dst.relnamespace
        WHERE src_ns.nspname = 'identity'
          AND src.relname = 'owners'
          AND c.conname = 'fk_owners_user'
          AND c.contype = 'f'
          AND dst_ns.nspname = 'identity'
          AND dst.relname = 'users'
    ) THEN
        RAISE EXCEPTION
            'identity.owners.fk_owners_user must reference identity.users';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class src
          ON src.oid = c.conrelid
        JOIN pg_namespace src_ns
          ON src_ns.oid = src.relnamespace
        JOIN pg_class dst
          ON dst.oid = c.confrelid
        JOIN pg_namespace dst_ns
          ON dst_ns.oid = dst.relnamespace
        WHERE src_ns.nspname = 'identity'
          AND src.relname = 'owners'
          AND c.conname = 'fk_owners_family'
          AND c.contype = 'f'
          AND dst_ns.nspname = 'identity'
          AND dst.relname = 'families'
    ) THEN
        RAISE EXCEPTION
            'identity.owners.fk_owners_family must reference identity.families';
    END IF;
END;
$$;


/* --------------------------------------------------------------------------
 * Column validation
 * -------------------------------------------------------------------------- */

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'identity'
          AND table_name = 'owners'
          AND column_name = 'owner_id'
          AND data_type = 'uuid'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'identity.owners.owner_id must be NOT NULL uuid';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'identity'
          AND table_name = 'owners'
          AND column_name = 'owner_type'
          AND udt_schema = 'identity'
          AND udt_name = 'owner_type'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'identity.owners.owner_type must be NOT NULL identity.owner_type';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'identity'
          AND table_name = 'owners'
          AND column_name = 'user_id'
          AND data_type = 'uuid'
          AND is_nullable = 'YES'
    ) THEN
        RAISE EXCEPTION
            'identity.owners.user_id must be nullable uuid';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'identity'
          AND table_name = 'owners'
          AND column_name = 'family_id'
          AND data_type = 'uuid'
          AND is_nullable = 'YES'
    ) THEN
        RAISE EXCEPTION
            'identity.owners.family_id must be nullable uuid';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'identity'
          AND table_name = 'owners'
          AND column_name = 'created_at'
          AND data_type = 'timestamp with time zone'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'identity.owners.created_at must be NOT NULL timestamptz';
    END IF;
END;
$$;


/* --------------------------------------------------------------------------
 * Index validation
 * -------------------------------------------------------------------------- */

DO $$
BEGIN
    IF to_regclass('identity.uq_owners_user') IS NULL THEN
        RAISE EXCEPTION
            'Required index identity.uq_owners_user was not created';
    END IF;

    IF to_regclass('identity.uq_owners_family') IS NULL THEN
        RAISE EXCEPTION
            'Required index identity.uq_owners_family was not created';
    END IF;
END;
$$;


/* --------------------------------------------------------------------------
 * Partial unique-index predicate validation
 *
 * This confirms that user/family uniqueness applies specifically to the
 * correct ownership discriminator rather than accidentally becoming global
 * uniqueness with different semantics.
 * -------------------------------------------------------------------------- */

DO $$
DECLARE
    v_user_predicate text;
    v_family_predicate text;
BEGIN
    SELECT pg_get_expr(i.indpred, i.indrelid)
    INTO v_user_predicate
    FROM pg_index i
    JOIN pg_class idx
      ON idx.oid = i.indexrelid
    JOIN pg_namespace n
      ON n.oid = idx.relnamespace
    WHERE n.nspname = 'identity'
      AND idx.relname = 'uq_owners_user';

    IF v_user_predicate IS NULL THEN
        RAISE EXCEPTION
            'identity.uq_owners_user must be a partial unique index';
    END IF;


    SELECT pg_get_expr(i.indpred, i.indrelid)
    INTO v_family_predicate
    FROM pg_index i
    JOIN pg_class idx
      ON idx.oid = i.indexrelid
    JOIN pg_namespace n
      ON n.oid = idx.relnamespace
    WHERE n.nspname = 'identity'
      AND idx.relname = 'uq_owners_family';

    IF v_family_predicate IS NULL THEN
        RAISE EXCEPTION
            'identity.uq_owners_family must be a partial unique index';
    END IF;
END;
$$;


/* --------------------------------------------------------------------------
 * Stored-data semantic validation
 * -------------------------------------------------------------------------- */

DO $$
BEGIN
    /*
     * No owner may have a discriminator/target mismatch.
     *
     * The CHECK constraint enforces this for future writes; the explicit
     * assertion makes the intended invariant visible during bootstrap and
     * later schema validation.
     */
    IF EXISTS (
        SELECT 1
        FROM identity.owners
        WHERE NOT (
            (
                owner_type = 'USER'
                AND user_id IS NOT NULL
                AND family_id IS NULL
            )
            OR
            (
                owner_type = 'FAMILY'
                AND family_id IS NOT NULL
                AND user_id IS NULL
            )
        )
    ) THEN
        RAISE EXCEPTION
            'identity.owners contains an invalid ownership target';
    END IF;


    /*
     * Each user may have at most one ownership principal.
     */
    IF EXISTS (
        SELECT user_id
        FROM identity.owners
        WHERE owner_type = 'USER'
          AND user_id IS NOT NULL
        GROUP BY user_id
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION
            'A user has more than one USER ownership principal';
    END IF;


    /*
     * Each family may have at most one ownership principal.
     */
    IF EXISTS (
        SELECT family_id
        FROM identity.owners
        WHERE owner_type = 'FAMILY'
          AND family_id IS NOT NULL
        GROUP BY family_id
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION
            'A family has more than one FAMILY ownership principal';
    END IF;
END;
$$;


\echo '[PASS] 0106_owners.sql'
SELECT pg_temp.bt_mark_completed('0100_identity/0106_owners.sql');
