/*
===============================================================================
 File:           1200_validation/1222_role_separation_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Mechanically enforce runtime/admin/deployment/ownership
                 separation and fail installation on privilege-boundary drift.
 Depends On:     1100_security/1111_role_ownership_separation.sql
                 1200_validation/1221_operational_integrity_validation.sql
 Creates:        Validation assertions only
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1222_role_separation_validation.sql', ARRAY['1100_security/1111_role_ownership_separation.sql', '1200_validation/1221_operational_integrity_validation.sql']::text[]);

\echo '[VALIDATE] 1222_role_separation_validation.sql'

/* Every BrickTrackr group role has an exact capability envelope. */
DO $$
DECLARE
    v record;
BEGIN
    FOR v IN
        SELECT *
        FROM (VALUES
            ('lego_api',       false, true),
            ('lego_app',       false, true),
            ('lego_reporting', false, true),
            ('lego_admin',     true,  true),
            ('lego_importer',  true,  true),
            ('lego_owner',     false, false),
            ('lego_deployer',  false, false)
        ) AS x(role_name, bypass_rls, inherit_ok)
    LOOP
        PERFORM app.assert_true(
            EXISTS (
                SELECT 1
                FROM pg_roles r
                WHERE r.rolname = v.role_name
                  AND NOT r.rolcanlogin
                  AND NOT r.rolsuper
                  AND NOT r.rolcreatedb
                  AND NOT r.rolcreaterole
                  AND NOT r.rolreplication
                  AND r.rolbypassrls = v.bypass_rls
                  AND r.rolinherit = v.inherit_ok
            ),
            format('Role %s has drifted from its required capability envelope', v.role_name)
        );
    END LOOP;
END;
$$;

/* Only the deployment group may assume the object-owner role. */
SELECT app.assert_true(
    pg_has_role('lego_deployer', 'lego_owner', 'MEMBER'),
    'lego_deployer must be a member of lego_owner'
);

DO $$
DECLARE
    v_role text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[
        'lego_api','lego_app','lego_admin','lego_importer','lego_reporting'
    ]
    LOOP
        PERFORM app.assert_true(
            NOT pg_has_role(v_role, 'lego_owner', 'MEMBER'),
            format('%s must not inherit/assume lego_owner', v_role)
        );
        PERFORM app.assert_true(
            NOT pg_has_role(v_role, 'lego_deployer', 'MEMBER'),
            format('%s must not inherit/assume lego_deployer', v_role)
        );
    END LOOP;
END;
$$;

/* All application schemas are owned by the dedicated NOLOGIN owner. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_namespace n
        JOIN pg_roles r ON r.oid = n.nspowner
        WHERE n.nspname IN (
            'app','identity','reference','catalog','definition','collection',
            'wanted','moc','import','audit','api','admin','marketplace',
            'finance','operations','reporting'
        )
          AND r.rolname <> 'lego_owner'
    ),
    'An application schema is not owned by lego_owner'
);

/* Persistent relations and sequences are owned only by lego_owner. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_roles r ON r.oid = c.relowner
        WHERE n.nspname IN (
            'app','identity','reference','catalog','definition','collection',
            'wanted','moc','import','audit','api','admin','marketplace',
            'finance','operations','reporting'
        )
          AND c.relkind IN ('r','p','v','m','S','f')
          AND r.rolname <> 'lego_owner'
    ),
    'An application relation/sequence is not owned by lego_owner'
);

/* All application routines, including SECURITY DEFINER code, share one owner. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE n.nspname IN (
            'app','identity','reference','catalog','definition','collection',
            'wanted','moc','import','audit','api','admin','marketplace',
            'finance','operations','reporting'
        )
          AND r.rolname <> 'lego_owner'
    ),
    'An application routine is not owned by lego_owner'
);

/* Standalone domains/enums/ranges/composite types are owner-controlled too. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        JOIN pg_roles r ON r.oid = t.typowner
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
          AND r.rolname <> 'lego_owner'
    ),
    'An application standalone type/domain is not owned by lego_owner'
);

/* No operational group may CREATE objects in application schemas. */
DO $$
DECLARE
    v_role text;
    v_schema record;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[
        'lego_api','lego_app','lego_admin','lego_importer','lego_reporting'
    ]
    LOOP
        FOR v_schema IN
            SELECT oid, nspname
            FROM pg_namespace
            WHERE nspname IN (
                'app','identity','reference','catalog','definition','collection',
                'wanted','moc','import','audit','api','admin','marketplace',
                'finance','operations','reporting'
            )
        LOOP
            PERFORM app.assert_true(
                NOT has_schema_privilege(v_role, v_schema.oid, 'CREATE'),
                format('%s unexpectedly has CREATE on schema %s', v_role, v_schema.nspname)
            );
        END LOOP;
    END LOOP;
END;
$$;

/* lego_owner-created routines/types may never fall back to PUBLIC defaults. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_default_acl d
        JOIN pg_roles owner_role ON owner_role.oid = d.defaclrole
        CROSS JOIN LATERAL aclexplode(d.defaclacl) a
        WHERE owner_role.rolname = 'lego_owner'
          AND a.grantee = 0
          AND (
              (d.defaclobjtype = 'f' AND a.privilege_type = 'EXECUTE')
              OR (d.defaclobjtype = 'T' AND a.privilege_type = 'USAGE')
          )
    ),
    'lego_owner default privileges expose routines/types to PUBLIC'
);

/* Runtime/admin/import/reporting must not receive automatic owner defaults.
 * Every future privilege grant must be explicit in the migration that needs it. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_default_acl d
        JOIN pg_roles owner_role ON owner_role.oid = d.defaclrole
        CROSS JOIN LATERAL aclexplode(d.defaclacl) a
        JOIN pg_roles grantee_role ON grantee_role.oid = a.grantee
        WHERE owner_role.rolname = 'lego_owner'
          AND grantee_role.rolname IN (
              'lego_api','lego_app','lego_admin','lego_importer','lego_reporting'
          )
    ),
    'lego_owner default privileges automatically grant an operational role'
);


/* Trusted audit capture must remain owner-only while FORCE RLS stays enabled. */
SELECT app.assert_true(
    (
        SELECT p.prosecdef
           AND owner_role.rolname = 'lego_owner'
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_roles owner_role ON owner_role.oid = p.proowner
        WHERE n.nspname = 'audit'
          AND p.proname = 'capture_row_change'
          AND pg_get_function_identity_arguments(p.oid) = ''
    ),
    'audit.capture_row_change() must be SECURITY DEFINER owned by lego_owner'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'audit'
          AND c.relname IN ('events','changes')
          AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity)
    ),
    'audit.events and audit.changes must retain ENABLE/FORCE ROW LEVEL SECURITY'
);

SELECT app.assert_true(
    (
        SELECT count(*)
        FROM pg_policies
        WHERE schemaname = 'audit'
          AND policyname IN (
              'audit_events_owner_insert',
              'audit_events_owner_select',
              'audit_changes_owner_insert',
              'audit_changes_owner_select'
          )
          AND roles = ARRAY['lego_owner']::name[]
    ) = 4,
    'Owner-only audit RLS policies are missing or broadened'
);

SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'audit'
          AND (
                'public'::name = ANY (roles)
             OR 'lego_api'::name = ANY (roles)
             OR 'lego_app'::name = ANY (roles)
             OR 'lego_admin'::name = ANY (roles)
             OR 'lego_importer'::name = ANY (roles)
             OR 'lego_reporting'::name = ANY (roles)
          )
    ),
    'Operational/PUBLIC roles must not receive audit-table RLS policies'
);

SELECT pg_temp.bt_mark_completed('1200_validation/1222_role_separation_validation.sql');
