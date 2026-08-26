/*
===============================================================================
 File:           1200_validation/1223_admin_catalog_lifecycle_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Validate the generic catalog lifecycle and execute-only admin
                 security boundary.
 Depends On:     1100_security/1112_admin_execute_only.sql
                 1200_validation/1222_role_separation_validation.sql
 Creates:        Validation assertions only
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1223_admin_catalog_lifecycle_validation.sql', ARRAY['1100_security/1112_admin_execute_only.sql', '1200_validation/1222_role_separation_validation.sql']::text[]);

\echo '[VALIDATE] 1223_catalog_lifecycle_validation.sql'


/* Required lifecycle routines exist. */
SELECT app.assert_true(
    to_regprocedure('catalog.transition_item_status(uuid,catalog.item_status,text,text)') IS NOT NULL,
    'catalog.transition_item_status(...) is missing'
);

SELECT app.assert_true(
    to_regprocedure('admin.assert_system_admin()') IS NOT NULL,
    'admin.assert_system_admin() is missing'
);

SELECT app.assert_true(
    to_regprocedure('admin.retire_catalog_item(uuid,text)') IS NOT NULL,
    'admin.retire_catalog_item(uuid,text) is missing'
);

SELECT app.assert_true(
    to_regprocedure('admin.archive_catalog_item(uuid,text)') IS NOT NULL,
    'admin.archive_catalog_item(uuid,text) is missing'
);

SELECT app.assert_true(
    to_regprocedure('admin.restore_catalog_item(uuid,text,text)') IS NOT NULL,
    'admin.restore_catalog_item(uuid,text,text) is missing'
);


/* Every trusted lifecycle/admin helper must be SECURITY DEFINER. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE (
                  (n.nspname = 'catalog' AND p.proname = 'transition_item_status')
               OR (n.nspname = 'admin' AND p.proname IN (
                      'assert_system_admin',
                      'retire_catalog_item',
                      'archive_catalog_item',
                      'restore_catalog_item'
                  ))
               )
           AND NOT p.prosecdef
    ),
    'A lifecycle/admin routine is not SECURITY DEFINER'
);


/* lego_admin must have zero direct table privileges in application schemas. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM information_schema.role_table_grants g
         WHERE g.grantee = 'lego_admin'
           AND g.table_schema IN (
               'identity','reference','catalog','definition','collection',
               'wanted','moc','import','audit','marketplace','finance',
               'operations','reporting'
           )
    ),
    'lego_admin still has direct application table privileges'
);


/* lego_admin must not have direct sequence privileges. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM information_schema.usage_privileges u
         WHERE u.grantee = 'lego_admin'
           AND u.object_type = 'SEQUENCE'
           AND u.object_schema IN (
               'identity','reference','catalog','definition','collection',
               'wanted','moc','import','audit','marketplace','finance',
               'operations','reporting'
           )
    ),
    'lego_admin still has direct application sequence privileges'
);


/* lego_admin cannot CREATE objects in any application schema. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_namespace n
         WHERE n.nspname IN (
             'app','identity','reference','catalog','definition','collection',
             'wanted','moc','import','audit','api','admin','marketplace',
             'finance','operations','reporting'
         )
           AND has_schema_privilege('lego_admin', n.oid, 'CREATE')
    ),
    'lego_admin unexpectedly has CREATE on an application schema'
);


/* The internal engine/helper are not directly executable by lego_admin. */
SELECT app.assert_true(
    NOT has_function_privilege(
        'lego_admin',
        'catalog.transition_item_status(uuid,catalog.item_status,text,text)',
        'EXECUTE'
    ),
    'lego_admin must not directly execute catalog.transition_item_status(...)'
);

SELECT app.assert_true(
    NOT has_function_privilege(
        'lego_admin',
        'admin.assert_system_admin()',
        'EXECUTE'
    ),
    'lego_admin must not directly execute admin.assert_system_admin()'
);


/* Exact reviewed admin lifecycle surface is executable. */
SELECT app.assert_true(
    has_function_privilege(
        'lego_admin',
        'admin.retire_catalog_item(uuid,text)',
        'EXECUTE'
    ),
    'lego_admin cannot execute admin.retire_catalog_item(uuid,text)'
);

SELECT app.assert_true(
    has_function_privilege(
        'lego_admin',
        'admin.archive_catalog_item(uuid,text)',
        'EXECUTE'
    ),
    'lego_admin cannot execute admin.archive_catalog_item(uuid,text)'
);

SELECT app.assert_true(
    has_function_privilege(
        'lego_admin',
        'admin.restore_catalog_item(uuid,text,text)',
        'EXECUTE'
    ),
    'lego_admin cannot execute admin.restore_catalog_item(uuid,text,text)'
);


/* Runtime/import/reporting roles must not execute admin lifecycle routines. */
DO $$
DECLARE
    v_role text;
    v_signature text;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[
        'lego_api','lego_app','lego_importer','lego_reporting'
    ]
    LOOP
        FOREACH v_signature IN ARRAY ARRAY[
            'admin.retire_catalog_item(uuid,text)',
            'admin.archive_catalog_item(uuid,text)',
            'admin.restore_catalog_item(uuid,text,text)'
        ]
        LOOP
            PERFORM app.assert_true(
                NOT has_function_privilege(v_role, v_signature, 'EXECUTE'),
                format('%s unexpectedly has EXECUTE on %s', v_role, v_signature)
            );
        END LOOP;
    END LOOP;
END;
$$;


/* PUBLIC must not receive explicit/default EXECUTE ACL entries. */
SELECT app.assert_true(
    NOT EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          CROSS JOIN LATERAL aclexplode(
              COALESCE(
                  p.proacl,
                  acldefault('f', p.proowner)
              )
          ) a
         WHERE (
                  (
                      n.nspname = 'catalog'
                      AND p.proname = 'transition_item_status'
                      AND pg_get_function_identity_arguments(p.oid)
                          = 'p_catalog_item_id uuid, p_new_status catalog.item_status, p_reason text, p_operation text'
                  )
               OR (
                      n.nspname = 'admin'
                      AND p.proname = 'assert_system_admin'
                      AND pg_get_function_identity_arguments(p.oid) = ''
                  )
               OR (
                      n.nspname = 'admin'
                      AND p.proname = 'retire_catalog_item'
                      AND pg_get_function_identity_arguments(p.oid)
                          = 'p_catalog_item_id uuid, p_reason text'
                  )
               OR (
                      n.nspname = 'admin'
                      AND p.proname = 'archive_catalog_item'
                      AND pg_get_function_identity_arguments(p.oid)
                          = 'p_catalog_item_id uuid, p_reason text'
                  )
               OR (
                      n.nspname = 'admin'
                      AND p.proname = 'restore_catalog_item'
                      AND pg_get_function_identity_arguments(p.oid)
                          = 'p_catalog_item_id uuid, p_restore_status text, p_reason text'
                  )
               )
           AND a.grantee = 0
           AND a.privilege_type = 'EXECUTE'
    ),
    'PUBLIC unexpectedly has lifecycle/admin EXECUTE privileges'
);


/*
 * Audit capture must remain trigger-only, SECURITY DEFINER, and owned by the
 * dedicated object owner after the ownership-separation migration.
 */
SELECT app.assert_true(
    (
        SELECT p.prosecdef
           AND r.rolname = 'lego_owner'
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          JOIN pg_roles r ON r.oid = p.proowner
         WHERE n.nspname = 'audit'
           AND p.proname = 'capture_row_change'
           AND pg_get_function_identity_arguments(p.oid) = ''
    ),
    'audit.capture_row_change() must remain SECURITY DEFINER owned by lego_owner'
);


SELECT pg_temp.bt_mark_completed('1200_validation/1223_admin_catalog_lifecycle_validation.sql');
