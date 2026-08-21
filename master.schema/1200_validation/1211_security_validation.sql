/*
===============================================================================
 File:           1200_validation/1211_security_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Validate role posture, complete RLS coverage, non-enumerable
                 UNLISTED MOCs, and least-privilege application access.
 Depends On:     Complete 1100_security domain
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1211_security_validation.sql', ARRAY['Complete 1100_security domain']::text[]);



\echo '[VALIDATE] 1211_security_validation.sql'

/* Required group roles and posture. */
DO $$
DECLARE
    v_role text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[
        'lego_app',
        'lego_admin',
        'lego_importer'
    ]
    LOOP
        PERFORM app.assert_true(
            EXISTS (
                SELECT 1
                FROM pg_roles
                WHERE rolname = v_role
            ),
            format('Required role "%s" is missing', v_role)
        );
    END LOOP;

    PERFORM app.assert_true(
        NOT (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'lego_app'),
        'lego_app must remain a NOLOGIN group role'
    );

    PERFORM app.assert_true(
        NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'lego_app'),
        'lego_app must not have BYPASSRLS'
    );

    PERFORM app.assert_true(
        (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'lego_admin'),
        'lego_admin is expected to have BYPASSRLS'
    );

    PERFORM app.assert_true(
        (SELECT rolbypassrls FROM pg_roles WHERE rolname = 'lego_importer'),
        'lego_importer is expected to have BYPASSRLS'
    );
END;
$$;


/*
 * Regression guard: every application-accessible table in a schema that may
 * contain user-private data must have RLS enabled. This makes future GRANT
 * additions fail validation automatically unless RLS is added too.
 */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname IN (
              'identity',
              'catalog',
              'definition',
              'collection',
              'wanted',
              'moc',
              'import'
          )
          AND (
              has_table_privilege('lego_app', c.oid, 'SELECT')
              OR has_table_privilege('lego_app', c.oid, 'INSERT')
              OR has_table_privilege('lego_app', c.oid, 'UPDATE')
              OR has_table_privilege('lego_app', c.oid, 'DELETE')
          )
          AND NOT c.relrowsecurity
    ),
    'lego_app has access to one or more private-domain tables without RLS'
);


/* Explicitly required RLS table set. */
DO $$
DECLARE
    v_table text;
    v_schema text;
    v_name text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'identity.user_credentials',
        'identity.user_sessions',
        'identity.one_time_tokens',

        'catalog.items',
        'catalog.sets',
        'catalog.parts',
        'catalog.minifigures',
        'catalog.books',
        'catalog.mocs',
        'catalog.sticker_sheets',
        'catalog.instructions',
        'catalog.packaging',
        'catalog.gear',
        'catalog.accessories',
        'catalog.polybags',
        'catalog.promotional_items',
        'catalog.publications',
        'catalog.other_items',
        'catalog.part_variants',
        'catalog.lego_elements',
        'catalog.external_identifiers',
        'catalog.source_values',
        'catalog.source_value_history',
        'catalog.admin_overrides',

        'definition.inventory_definitions',
        'definition.inventory_versions',
        'definition.requirement_groups',
        'definition.requirement_options',
        'definition.definition_authority',

        'collection.storage_locations',
        'collection.entries',
        'collection.instances',
        'collection.instance_adjustments',
        'collection.storage_allocations',
        'collection.transfers',
        'collection.acquisitions',
        'collection.acquisition_items',
        'collection.tags',
        'collection.entry_tags',

        'wanted.wishlists',
        'wanted.wishlist_entries',
        'wanted.wishlist_reservations',
        'wanted.build_goals',
        'wanted.build_allocations',

        'moc.mocs',
        'moc.revisions',
        'moc.forks',
        'moc.subassemblies',
        'moc.licenses',
        'moc.assets',

        'import.jobs',
        'import.raw_records',
        'import.normalized_records',
        'import.matches',
        'import.user_mapping_suggestions',
        'import.applications',
        'import.application_changes',

        'audit.events',
        'audit.changes'
    ]
    LOOP
        v_schema := split_part(v_table, '.', 1);
        v_name := split_part(v_table, '.', 2);

        PERFORM app.assert_true(
            EXISTS (
                SELECT 1
                FROM pg_class c
                JOIN pg_namespace n
                  ON n.oid = c.relnamespace
                WHERE n.nspname = v_schema
                  AND c.relname = v_name
                  AND c.relrowsecurity
            ),
            format('RLS is not enabled on %s', v_table)
        );
    END LOOP;
END;
$$;


/* Audit remains FORCE RLS. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'audit'
          AND c.relname IN ('events', 'changes')
          AND NOT c.relforcerowsecurity
    ),
    'Audit tables must FORCE ROW LEVEL SECURITY'
);


/* Every RLS table directly usable by lego_app must have at least one policy. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND c.relrowsecurity
          AND n.nspname IN (
              'identity',
              'catalog',
              'definition',
              'collection',
              'wanted',
              'moc',
              'import'
          )
          AND has_table_privilege('lego_app', c.oid, 'SELECT')
          AND NOT EXISTS (
              SELECT 1
              FROM pg_policy p
              WHERE p.polrelid = c.oid
          )
    ),
    'An application-readable RLS table has no policy'
);


/* UNLISTED MOCs must not be admitted by direct table-scan policies. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'moc'
          AND tablename IN (
              'mocs',
              'revisions',
              'assets',
              'licenses',
              'subassemblies',
              'forks'
          )
          AND cmd = 'SELECT'
          AND coalesce(qual, '') ILIKE '%UNLISTED%'
    ),
    'UNLISTED MOCs are directly enumerable through an RLS SELECT policy'
);


/* Transfer history is insert-only from the application's perspective. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'collection'
          AND tablename = 'transfers'
          AND cmd IN ('UPDATE', 'DELETE', 'ALL')
    ),
    'collection.transfers must not expose UPDATE/DELETE through RLS'
);


/* Exact-ID UNLISTED access functions must not be executable by PUBLIC. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n
          ON n.oid = p.pronamespace
        CROSS JOIN LATERAL aclexplode(
            coalesce(
                p.proacl,
                acldefault('f', p.proowner)
            )
        ) acl
        WHERE n.nspname = 'api'
          AND p.proname IN (
              'get_moc_by_id',
              'get_moc_revisions',
              'get_moc_assets',
              'get_moc_licenses',
              'get_moc_subassemblies'
          )
          AND acl.grantee = 0
          AND acl.privilege_type = 'EXECUTE'
    ),
    'One or more SECURITY DEFINER MOC access functions are executable by PUBLIC'
);


/* App role gets no direct audit-table access. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'audit'
          AND c.relname IN ('events', 'changes')
          AND (
              has_table_privilege('lego_app', c.oid, 'SELECT')
              OR has_table_privilege('lego_app', c.oid, 'INSERT')
              OR has_table_privilege('lego_app', c.oid, 'UPDATE')
              OR has_table_privilege('lego_app', c.oid, 'DELETE')
          )
    ),
    'lego_app must not have direct audit-table privileges'
);

\echo '[VALIDATE PASS] 1211_security_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1211_security_validation.sql');
