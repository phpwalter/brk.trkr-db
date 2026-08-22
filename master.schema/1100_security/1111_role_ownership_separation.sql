/*
===============================================================================
 File:           1100_security/1111_role_ownership_separation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Separate runtime, administration, deployment, and object
                 ownership so operational roles cannot become schema owners.
 Depends On:     1100_security/1100_roles.sql
                 1100_security/1110_api_surface_lockdown.sql
 Creates:        Ownership assignment to lego_owner
                 lego_deployer -> lego_owner membership
 Key Rules:      lego_owner is NOLOGIN and owns application objects.
                 lego_deployer is NOLOGIN and is the only BrickTrackr group
                 role allowed to assume lego_owner.
                 Runtime/admin/import/reporting roles never own application
                 objects and never inherit deployment/ownership authority.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1111_role_ownership_separation.sql', ARRAY['1100_security/1100_roles.sql', '1100_security/1110_api_surface_lockdown.sql']::text[]);

\echo '[SECURITY] Separating ownership and deployment authority...'

/* Known operational roles must not inherit deployment or ownership authority. */
REVOKE lego_owner
FROM lego_api, lego_app, lego_admin, lego_importer, lego_reporting;

REVOKE lego_deployer
FROM lego_api, lego_app, lego_admin, lego_importer, lego_reporting;

/* Deployment may assume ownership; no other BrickTrackr group role may do so. */
GRANT lego_owner TO lego_deployer;

COMMENT ON ROLE lego_owner IS
    'NOLOGIN owner of BrickTrackr schemas/objects. Never used by application or human sessions directly.';
COMMENT ON ROLE lego_deployer IS
    'NOLOGIN deployment group. Approved deployment login(s) may be granted this role and may SET ROLE lego_owner for migrations.';

/*
 * ALTER ... OWNER requires membership in the target role.  Bootstrap already
 * requires role-creation privileges, so grant the installer temporary
 * membership only when it does not already have it.  The entire bootstrap is
 * transactional; a failed install cannot strand this temporary grant.
 */
CREATE TEMP TABLE bt_owner_membership_state (
    added_temporarily boolean NOT NULL
) ON COMMIT DROP;

INSERT INTO pg_temp.bt_owner_membership_state(added_temporarily)
SELECT current_user <> 'lego_owner'
   AND NOT pg_has_role(current_user, 'lego_owner', 'MEMBER');

DO $$
BEGIN
    IF (SELECT added_temporarily FROM pg_temp.bt_owner_membership_state) THEN
        EXECUTE format('GRANT lego_owner TO %I', current_user);
    END IF;
END;
$$;

/* Transfer tables/partitions first; owned sequences follow their parent table. */
DO $$
DECLARE
    v record;
    v_command text;
BEGIN
    FOR v IN
        SELECT n.nspname, c.relname, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN (
            'app','identity','reference','catalog','definition','collection',
            'wanted','moc','import','audit','api','admin','marketplace',
            'finance','operations','reporting'
        )
          AND c.relkind IN ('r','p','v','m','f')
        ORDER BY n.nspname, c.relname
    LOOP
        v_command := CASE v.relkind
            WHEN 'r' THEN 'ALTER TABLE'
            WHEN 'p' THEN 'ALTER TABLE'
            WHEN 'v' THEN 'ALTER VIEW'
            WHEN 'm' THEN 'ALTER MATERIALIZED VIEW'
            WHEN 'f' THEN 'ALTER FOREIGN TABLE'
        END;
        EXECUTE format(
            '%s %I.%I OWNER TO lego_owner',
            v_command, v.nspname, v.relname
        );
    END LOOP;
END;
$$;

/* Transfer any standalone sequences not already owned through a table column. */
DO $$
DECLARE
    v record;
BEGIN
    FOR v IN
        SELECT n.nspname, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN (
            'app','identity','reference','catalog','definition','collection',
            'wanted','moc','import','audit','api','admin','marketplace',
            'finance','operations','reporting'
        )
          AND c.relkind = 'S'
          AND NOT EXISTS (
              SELECT 1
              FROM pg_depend d
              WHERE d.classid = 'pg_class'::regclass
                AND d.objid = c.oid
                AND d.deptype IN ('a','i')
          )
        ORDER BY n.nspname, c.relname
    LOOP
        EXECUTE format(
            'ALTER SEQUENCE %I.%I OWNER TO lego_owner',
            v.nspname, v.relname
        );
    END LOOP;
END;
$$;

/* SECURITY DEFINER privilege is intentionally anchored to the NOLOGIN owner. */
DO $$
DECLARE
    v record;
BEGIN
    FOR v IN
        SELECT p.oid
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN (
            'app','identity','reference','catalog','definition','collection',
            'wanted','moc','import','audit','api','admin','marketplace',
            'finance','operations','reporting'
        )
        ORDER BY p.oid
    LOOP
        EXECUTE format(
            'ALTER ROUTINE %s OWNER TO lego_owner',
            v.oid::regprocedure
        );
    END LOOP;
END;
$$;

/* Transfer standalone domains/enums/ranges/composite types. Table row types
 * follow their table and are deliberately excluded here. */
DO $$
DECLARE
    v record;
BEGIN
    FOR v IN
        SELECT n.nspname, t.typname, t.typtype
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        LEFT JOIN pg_class c ON c.oid = t.typrelid
        WHERE n.nspname IN (
            'app','identity','reference','catalog','definition','collection',
            'wanted','moc','import','audit','api','admin','marketplace',
            'finance','operations','reporting'
        )
          AND (
              t.typtype IN ('d','e','r','m')
              OR (t.typtype = 'c' AND c.relkind = 'c')
          )
        ORDER BY n.nspname, t.typname
    LOOP
        IF v.typtype = 'd' THEN
            EXECUTE format(
                'ALTER DOMAIN %I.%I OWNER TO lego_owner',
                v.nspname, v.typname
            );
        ELSE
            EXECUTE format(
                'ALTER TYPE %I.%I OWNER TO lego_owner',
                v.nspname, v.typname
            );
        END IF;
    END LOOP;
END;
$$;

/* Schemas themselves are owned by the dedicated owner, never an operational role. */
DO $$
DECLARE
    v_schema text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY[
        'app','identity','reference','catalog','definition','collection',
        'wanted','moc','import','audit','api','admin','marketplace',
        'finance','operations','reporting'
    ]
    LOOP
        EXECUTE format('ALTER SCHEMA %I OWNER TO lego_owner', v_schema);
        EXECUTE format(
            'REVOKE CREATE ON SCHEMA %I FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting',
            v_schema
        );
    END LOOP;
END;
$$;

/*
 * Objects created while SET ROLE lego_owner must start private.  Grants to
 * runtime/admin/import/reporting roles are always deliberate migration changes.
 */
ALTER DEFAULT PRIVILEGES FOR ROLE lego_owner
    REVOKE ALL ON TABLES FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting;
ALTER DEFAULT PRIVILEGES FOR ROLE lego_owner
    REVOKE ALL ON SEQUENCES FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting;
ALTER DEFAULT PRIVILEGES FOR ROLE lego_owner
    REVOKE EXECUTE ON ROUTINES FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting;
ALTER DEFAULT PRIVILEGES FOR ROLE lego_owner
    REVOKE USAGE ON TYPES FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting;
ALTER DEFAULT PRIVILEGES FOR ROLE lego_owner
    REVOKE ALL ON SCHEMAS FROM PUBLIC, lego_api, lego_app, lego_admin, lego_importer, lego_reporting;

/* Remove only the bootstrap membership we added ourselves. */
DO $$
BEGIN
    IF (SELECT added_temporarily FROM pg_temp.bt_owner_membership_state) THEN
        EXECUTE format('REVOKE lego_owner FROM %I', current_user);
    END IF;
END;
$$;

SELECT pg_temp.bt_mark_completed('1100_security/1111_role_ownership_separation.sql');
