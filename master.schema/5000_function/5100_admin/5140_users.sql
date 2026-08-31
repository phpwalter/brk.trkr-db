\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5100_admin/5140_users.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', '0100_identity/0100_users.sql', '1100_security/1100_roles.sql']::text[]);

/*
===============================================================================
 File:           5000_function/5100_admin/5140_users.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Administrative CRUD and lifecycle procedures for identity.users
 Revision:       Removes invalid schema qualification from PostgreSQL special
                 expressions and retains the CITEXT-independent comparisons;
                 username/email comparisons are explicitly case-insensitive.
                 Administrative mutations establish actor_class=ADMIN so
                 first-user provisioning can be audited without an existing
                 authenticated BrickTrackr user row.
 Depends On:     5000_function/5100_admin/5100_admin_common.sql
                 0100_identity/0100_users.sql
                 1100_security/1100_roles.sql
===============================================================================

 Canonical table
 ---------------
 identity.users

 Security model
 --------------
 - Procedures are owned/executed under brktrkr_owner.
 - Only brktrkr_admin receives EXECUTE on the public admin.* surface below.
 - brktrkr_admin receives no direct table privileges on identity.users.
 - Normal application roles receive no admin.* execution from this module.
 - CREATE never accepts a caller-supplied user UUID.
 - Account-management and account-status mutations are separate from ordinary
   profile/account-field updates.
 - DELETE is soft delete only: account_status = ARCHIVED, archived_at = now().
 - RESTORE returns an archived account to ACTIVE.

 Audit model
 -----------
 This module does not create audit tables. BrickTrackr's canonical audit layer
 owns audit.events/audit.changes and row-audit triggers. Mutation procedures set
 transaction-local app.audit_operation/app.audit_reason context so an installed
 canonical audit trigger can enrich the corresponding committed row event.

 identity.users contract
 -----------------------
 Required:
   username
   display_name

 Optional:
   email
   date_of_birth
   locale
   timezone_name

 Internally controlled:
   user_id                    DEFAULT app.uuid_v7()
   account_management_type    INDEPENDENT | MANAGED_CHILD
   account_status             PENDING | ACTIVE | LOCKED | DISABLED | ARCHIVED
   created_at
   activated_at
   archived_at
===============================================================================
*/


/*
===============================================================================
 1. Root/bootstrap preflight and minimum ownership privileges

 This section runs before SET ROLE so a privileged installer such as root can
 ensure brktrkr_owner can own SECURITY DEFINER routines that access
 identity.users. brktrkr_admin receives only schema/type visibility, never
 direct table access.
===============================================================================
*/

DO $preflight$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_namespace
        WHERE nspname = 'identity'
    ) THEN
        RAISE EXCEPTION 'Required schema identity does not exist.';
    END IF;

    IF pg_catalog.to_regclass('identity.users') IS NULL THEN
        RAISE EXCEPTION 'Required table identity.users does not exist.';
    END IF;

    IF pg_catalog.to_regtype('identity.account_management_type') IS NULL THEN
        RAISE EXCEPTION 'Required type identity.account_management_type does not exist.';
    END IF;

    IF pg_catalog.to_regtype('identity.account_status') IS NULL THEN
        RAISE EXCEPTION 'Required type identity.account_status does not exist.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_namespace
        WHERE nspname = 'admin'
    ) THEN
        RAISE EXCEPTION 'Required schema admin does not exist.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'brktrkr_owner'
    ) THEN
        RAISE EXCEPTION 'Required PostgreSQL role brktrkr_owner does not exist.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'brktrkr_admin'
    ) THEN
        RAISE EXCEPTION 'Required PostgreSQL role brktrkr_admin does not exist.';
    END IF;
END;
$preflight$;


/*
 * The SECURITY DEFINER routine owner needs controlled access to the identity
 * schema/table. These grants do not expose identity.users to brktrkr_admin.
 */
GRANT USAGE ON SCHEMA identity TO brktrkr_owner;
GRANT SELECT, INSERT, UPDATE ON TABLE identity.users TO brktrkr_owner;

GRANT USAGE ON SCHEMA admin TO brktrkr_admin;
GRANT USAGE ON SCHEMA identity TO brktrkr_admin;
GRANT USAGE ON TYPE identity.account_management_type TO brktrkr_admin;
GRANT USAGE ON TYPE identity.account_status TO brktrkr_admin;

REVOKE ALL PRIVILEGES ON TABLE identity.users FROM brktrkr_admin;

SET ROLE brktrkr_owner;


/*
===============================================================================
 2. Administrative authorization helper
===============================================================================
*/

CREATE OR REPLACE FUNCTION admin.require_user_admin()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    /*
     * session_user remains the connecting role even inside SECURITY DEFINER.
     * Membership is therefore evaluated against the authenticated DB principal,
     * not caller-controlled application context.
     */
    IF session_user <> 'brktrkr_owner'
       AND NOT pg_catalog.pg_has_role(
            session_user,
            'brktrkr_admin',
            'MEMBER'
       )
    THEN
        RAISE EXCEPTION 'BrickTrackr user-administrator authority is required.'
            USING ERRCODE = '42501';
    END IF;
END;
$function$;


/*
===============================================================================
 3. Canonical administrative user JSON builder
===============================================================================
*/

CREATE OR REPLACE FUNCTION admin.build_user_json(
    p_user_id UUID
)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, identity
AS $function$
    SELECT pg_catalog.jsonb_build_object(
        'user_id', u.user_id,
        'username', u.username::TEXT,
        'display_name', u.display_name,
        'email', CASE
                    WHEN u.email IS NULL THEN NULL
                    ELSE u.email::TEXT
                 END,
        'account_management_type', u.account_management_type::TEXT,
        'account_status', u.account_status::TEXT,
        'date_of_birth', u.date_of_birth,
        'locale', u.locale,
        'timezone_name', u.timezone_name,
        'created_at', u.created_at,
        'activated_at', u.activated_at,
        'archived_at', u.archived_at
    )
    FROM identity.users AS u
    WHERE u.user_id = p_user_id;
$function$;


/*
===============================================================================
 4. CREATE

 Minimum normal USER-level provisioning requires:
   username
   display_name

 email is optional.

 CREATE always provisions:
   account_management_type = INDEPENDENT
   account_status          = ACTIVE
   activated_at            = now()

 user_id is generated by identity.users DEFAULT app.uuid_v7().
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.create_user(
    IN p_username TEXT,
    IN p_display_name TEXT,
    IN p_email TEXT DEFAULT NULL,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_previous_actor_class TEXT;
    v_username TEXT;
    v_display_name TEXT;
    v_email TEXT;
    v_user_id UUID;
BEGIN
    PERFORM admin.require_user_admin();

    v_username := pg_catalog.btrim(p_username);
    v_display_name := pg_catalog.btrim(p_display_name);
    v_email := NULLIF(pg_catalog.lower(pg_catalog.btrim(p_email)), '');

    IF v_username IS NULL OR v_username = '' THEN
        RAISE EXCEPTION 'username is required.'
            USING ERRCODE = '22023';
    END IF;

    IF v_display_name IS NULL OR v_display_name = '' THEN
        RAISE EXCEPTION 'display_name is required.'
            USING ERRCODE = '22023';
    END IF;

    IF v_email IS NOT NULL
       AND v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    THEN
        RAISE EXCEPTION 'email is not valid.'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM identity.users AS u
        WHERE pg_catalog.lower(u.username::TEXT) = pg_catalog.lower(v_username)
    ) THEN
        RAISE EXCEPTION 'username "%" is already in use.', v_username
            USING ERRCODE = '23505';
    END IF;

    IF v_email IS NOT NULL
       AND EXISTS (
            SELECT 1
            FROM identity.users AS u
            WHERE pg_catalog.lower(u.email::TEXT) = pg_catalog.lower(v_email)
       )
    THEN
        RAISE EXCEPTION 'email "%" is already in use.', v_email
            USING ERRCODE = '23505';
    END IF;

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    PERFORM pg_catalog.set_config(
        'app.audit_operation',
        'admin.create_user',
        true
    );
    PERFORM pg_catalog.set_config(
        'app.audit_reason',
        'administrative user provisioning',
        true
    );

    BEGIN
        INSERT INTO identity.users (
            username,
            display_name,
            email,
            account_management_type,
            account_status,
            activated_at
        )
        VALUES (
            v_username,
            v_display_name,
            v_email,
            'INDEPENDENT',
            'ACTIVE',
            pg_catalog.now()
        )
        RETURNING user_id
        INTO v_user_id;

    EXCEPTION
        WHEN OTHERS THEN
            PERFORM pg_catalog.set_config(
                'app.actor_class',
                COALESCE(v_previous_actor_class, ''),
                true
            );
            RAISE;
    END;

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        COALESCE(v_previous_actor_class, ''),
        true
    );

    p_result := admin.build_user_json(v_user_id);
END;
$procedure$;


/*
===============================================================================
 5. READ - by UUID
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.get_user(
    IN p_user_id UUID,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin
AS $procedure$
BEGIN
    PERFORM admin.require_user_admin();

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'p_user_id is required.'
            USING ERRCODE = '22023';
    END IF;

    p_result := admin.build_user_json(p_user_id);

    IF p_result IS NULL THEN
        RAISE EXCEPTION 'User % does not exist.', p_user_id
            USING ERRCODE = 'P0002';
    END IF;
END;
$procedure$;


/*
===============================================================================
 6. READ - by email
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.get_user_by_email(
    IN p_email TEXT,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_email TEXT;
    v_user_id UUID;
BEGIN
    PERFORM admin.require_user_admin();

    v_email := NULLIF(pg_catalog.lower(pg_catalog.btrim(p_email)), '');

    IF v_email IS NULL THEN
        RAISE EXCEPTION 'email is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT u.user_id
    INTO v_user_id
    FROM identity.users AS u
    WHERE pg_catalog.lower(u.email::TEXT) = pg_catalog.lower(v_email);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User with email "%" does not exist.', v_email
            USING ERRCODE = 'P0002';
    END IF;

    p_result := admin.build_user_json(v_user_id);
END;
$procedure$;


/*
===============================================================================
 7. READ - by username
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.get_user_by_username(
    IN p_username TEXT,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_username TEXT;
    v_user_id UUID;
BEGIN
    PERFORM admin.require_user_admin();

    v_username := NULLIF(pg_catalog.btrim(p_username), '');

    IF v_username IS NULL THEN
        RAISE EXCEPTION 'username is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT u.user_id
    INTO v_user_id
    FROM identity.users AS u
    WHERE pg_catalog.lower(u.username::TEXT) = pg_catalog.lower(v_username);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User with username "%" does not exist.', v_username
            USING ERRCODE = 'P0002';
    END IF;

    p_result := admin.build_user_json(v_user_id);
END;
$procedure$;


/*
===============================================================================
 8. READ - list/search

 Search matches:
   username
   display_name
   email
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.list_users(
    IN p_management_type identity.account_management_type DEFAULT NULL,
    IN p_status identity.account_status DEFAULT NULL,
    IN p_search TEXT DEFAULT NULL,
    IN p_include_archived BOOLEAN DEFAULT FALSE,
    IN p_limit INTEGER DEFAULT 100,
    IN p_offset INTEGER DEFAULT 0,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_search TEXT;
    v_limit INTEGER;
    v_offset INTEGER;
    v_total BIGINT;
BEGIN
    PERFORM admin.require_user_admin();

    v_search := NULLIF(pg_catalog.lower(pg_catalog.btrim(p_search)), '');
    v_limit := COALESCE(p_limit, 100);
    v_offset := COALESCE(p_offset, 0);

    IF v_limit < 1 OR v_limit > 500 THEN
        RAISE EXCEPTION 'p_limit must be between 1 and 500.'
            USING ERRCODE = '22023';
    END IF;

    IF v_offset < 0 THEN
        RAISE EXCEPTION 'p_offset must be zero or greater.'
            USING ERRCODE = '22023';
    END IF;

    SELECT pg_catalog.count(*)
    INTO v_total
    FROM identity.users AS u
    WHERE (p_management_type IS NULL
           OR u.account_management_type = p_management_type)
      AND (p_status IS NULL
           OR u.account_status = p_status)
      AND (COALESCE(p_include_archived, FALSE)
           OR u.account_status <> 'ARCHIVED')
      AND (
            v_search IS NULL
            OR pg_catalog.lower(u.username::TEXT) LIKE '%' || v_search || '%'
            OR pg_catalog.lower(u.display_name) LIKE '%' || v_search || '%'
            OR pg_catalog.lower(COALESCE(u.email::TEXT, '')) LIKE '%' || v_search || '%'
          );

    SELECT pg_catalog.jsonb_build_object(
        'total', v_total,
        'limit', v_limit,
        'offset', v_offset,
        'users',
        COALESCE(
            pg_catalog.jsonb_agg(
                pg_catalog.jsonb_build_object(
                    'user_id', q.user_id,
                    'username', q.username::TEXT,
                    'display_name', q.display_name,
                    'email', CASE
                                WHEN q.email IS NULL THEN NULL
                                ELSE q.email::TEXT
                             END,
                    'account_management_type', q.account_management_type::TEXT,
                    'account_status', q.account_status::TEXT,
                    'date_of_birth', q.date_of_birth,
                    'locale', q.locale,
                    'timezone_name', q.timezone_name,
                    'created_at', q.created_at,
                    'activated_at', q.activated_at,
                    'archived_at', q.archived_at
                )
                ORDER BY q.created_at DESC, q.user_id
            ),
            '[]'::JSONB
        )
    )
    INTO p_result
    FROM (
        SELECT u.*
        FROM identity.users AS u
        WHERE (p_management_type IS NULL
               OR u.account_management_type = p_management_type)
          AND (p_status IS NULL
               OR u.account_status = p_status)
          AND (COALESCE(p_include_archived, FALSE)
               OR u.account_status <> 'ARCHIVED')
          AND (
                v_search IS NULL
                OR pg_catalog.lower(u.username::TEXT) LIKE '%' || v_search || '%'
                OR pg_catalog.lower(u.display_name) LIKE '%' || v_search || '%'
                OR pg_catalog.lower(COALESCE(u.email::TEXT, '')) LIKE '%' || v_search || '%'
              )
        ORDER BY u.created_at DESC, u.user_id
        LIMIT v_limit
        OFFSET v_offset
    ) AS q;
END;
$procedure$;


/*
===============================================================================
 9. UPDATE - ordinary mutable fields

 Writable:
   username
   display_name
   email
   date_of_birth
   locale
   timezone_name

 Not writable here:
   user_id
   account_management_type -> admin.set_user_management_type()
   account_status          -> admin.set_user_status()/delete_user()/restore_user()
   created_at
   activated_at
   archived_at

 JSON semantics:
   omitted property = no change
   explicit JSON null = clear nullable property
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.update_user(
    IN p_user_id UUID,
    IN p_patch JSONB,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_previous_actor_class TEXT;
    v_user identity.users%ROWTYPE;
    v_key TEXT;

    v_username TEXT;
    v_display_name TEXT;
    v_email TEXT;
    v_date_of_birth DATE;
    v_locale TEXT;
    v_timezone_name TEXT;
BEGIN
    PERFORM admin.require_user_admin();

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'p_user_id is required.'
            USING ERRCODE = '22023';
    END IF;

    IF p_patch IS NULL
       OR pg_catalog.jsonb_typeof(p_patch) <> 'object'
    THEN
        RAISE EXCEPTION 'p_patch must be a JSON object.'
            USING ERRCODE = '22023';
    END IF;

    IF p_patch = '{}'::JSONB THEN
        RAISE EXCEPTION 'p_patch contains no changes.'
            USING ERRCODE = '22023';
    END IF;

    FOR v_key IN
        SELECT pg_catalog.jsonb_object_keys(p_patch)
    LOOP
        IF v_key NOT IN (
            'username',
            'display_name',
            'email',
            'date_of_birth',
            'locale',
            'timezone_name'
        ) THEN
            RAISE EXCEPTION 'Property "%" is not writable by admin.update_user.', v_key
                USING ERRCODE = '22023';
        END IF;
    END LOOP;

    SELECT *
    INTO v_user
    FROM identity.users
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User % does not exist.', p_user_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_user.account_status = 'ARCHIVED' THEN
        RAISE EXCEPTION 'User % is archived. Restore the user before updating it.', p_user_id
            USING ERRCODE = '55000';
    END IF;

    v_username := v_user.username::TEXT;
    v_display_name := v_user.display_name;
    v_email := CASE
                   WHEN v_user.email IS NULL THEN NULL
                   ELSE v_user.email::TEXT
               END;
    v_date_of_birth := v_user.date_of_birth;
    v_locale := v_user.locale;
    v_timezone_name := v_user.timezone_name;

    IF p_patch ? 'username' THEN
        IF p_patch->'username' = 'null'::JSONB THEN
            RAISE EXCEPTION 'username may not be NULL.'
                USING ERRCODE = '23502';
        END IF;

        v_username := pg_catalog.btrim(p_patch->>'username');

        IF v_username = '' THEN
            RAISE EXCEPTION 'username may not be empty.'
                USING ERRCODE = '22023';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM identity.users AS other
            WHERE pg_catalog.lower(other.username::TEXT) = pg_catalog.lower(v_username)
              AND other.user_id <> p_user_id
        ) THEN
            RAISE EXCEPTION 'username "%" is already in use.', v_username
                USING ERRCODE = '23505';
        END IF;
    END IF;

    IF p_patch ? 'display_name' THEN
        IF p_patch->'display_name' = 'null'::JSONB THEN
            RAISE EXCEPTION 'display_name may not be NULL.'
                USING ERRCODE = '23502';
        END IF;

        v_display_name := pg_catalog.btrim(p_patch->>'display_name');

        IF v_display_name = '' THEN
            RAISE EXCEPTION 'display_name may not be empty.'
                USING ERRCODE = '22023';
        END IF;
    END IF;

    IF p_patch ? 'email' THEN
        IF p_patch->'email' = 'null'::JSONB THEN
            v_email := NULL;
        ELSE
            v_email := NULLIF(
                pg_catalog.lower(pg_catalog.btrim(p_patch->>'email')),
                ''
            );

            IF v_email IS NULL THEN
                RAISE EXCEPTION 'email must be a valid address or explicit JSON null.'
                    USING ERRCODE = '22023';
            END IF;

            IF v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
                RAISE EXCEPTION 'email is not valid.'
                    USING ERRCODE = '22023';
            END IF;

            IF EXISTS (
                SELECT 1
                FROM identity.users AS other
                WHERE pg_catalog.lower(other.email::TEXT) = pg_catalog.lower(v_email)
                  AND other.user_id <> p_user_id
            ) THEN
                RAISE EXCEPTION 'email "%" is already in use.', v_email
                    USING ERRCODE = '23505';
            END IF;
        END IF;
    END IF;

    IF p_patch ? 'date_of_birth' THEN
        v_date_of_birth := CASE
            WHEN p_patch->'date_of_birth' = 'null'::JSONB THEN NULL
            ELSE (p_patch->>'date_of_birth')::DATE
        END;
    END IF;

    IF p_patch ? 'locale' THEN
        v_locale := CASE
            WHEN p_patch->'locale' = 'null'::JSONB THEN NULL
            ELSE NULLIF(pg_catalog.btrim(p_patch->>'locale'), '')
        END;
    END IF;

    IF p_patch ? 'timezone_name' THEN
        v_timezone_name := CASE
            WHEN p_patch->'timezone_name' = 'null'::JSONB THEN NULL
            ELSE NULLIF(pg_catalog.btrim(p_patch->>'timezone_name'), '')
        END;
    END IF;

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    PERFORM pg_catalog.set_config(
        'app.audit_operation',
        'admin.update_user',
        true
    );
    PERFORM pg_catalog.set_config(
        'app.audit_reason',
        'administrative user field update',
        true
    );

    BEGIN
        UPDATE identity.users
        SET username = v_username,
            display_name = v_display_name,
            email = v_email,
            date_of_birth = v_date_of_birth,
            locale = v_locale,
            timezone_name = v_timezone_name
        WHERE user_id = p_user_id;

    EXCEPTION
        WHEN OTHERS THEN
            PERFORM pg_catalog.set_config(
                'app.actor_class',
                COALESCE(v_previous_actor_class, ''),
                true
            );
            RAISE;
    END;

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        COALESCE(v_previous_actor_class, ''),
        true
    );

    p_result := admin.build_user_json(p_user_id);
END;
$procedure$;


/*
===============================================================================
 10. UPDATE - account management type

 This replaces the obsolete "set_user_role" concept. identity.users has no
 role column. The privilege-sensitive account classification is
 account_management_type.
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.set_user_management_type(
    IN p_user_id UUID,
    IN p_management_type identity.account_management_type,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_previous_actor_class TEXT;
    v_user identity.users%ROWTYPE;
BEGIN
    PERFORM admin.require_user_admin();

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'p_user_id is required.'
            USING ERRCODE = '22023';
    END IF;

    IF p_management_type IS NULL THEN
        RAISE EXCEPTION 'p_management_type is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_user
    FROM identity.users
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User % does not exist.', p_user_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_user.account_status = 'ARCHIVED' THEN
        RAISE EXCEPTION 'User % is archived. Restore the user before changing account management type.', p_user_id
            USING ERRCODE = '55000';
    END IF;

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    PERFORM pg_catalog.set_config(
        'app.audit_operation',
        'admin.set_user_management_type',
        true
    );
    PERFORM pg_catalog.set_config(
        'app.audit_reason',
        'administrative account management type change',
        true
    );

    BEGIN
        UPDATE identity.users
        SET account_management_type = p_management_type
        WHERE user_id = p_user_id;

    EXCEPTION
        WHEN OTHERS THEN
            PERFORM pg_catalog.set_config(
                'app.actor_class',
                COALESCE(v_previous_actor_class, ''),
                true
            );
            RAISE;
    END;

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        COALESCE(v_previous_actor_class, ''),
        true
    );

    p_result := admin.build_user_json(p_user_id);
END;
$procedure$;


/*
===============================================================================
 11. UPDATE - lifecycle status

 ARCHIVED is deliberately excluded here.
 Use admin.delete_user() for the soft-delete transition.

 ACTIVE guarantees activated_at is populated.
 Non-ARCHIVED states guarantee archived_at is NULL.
 Existing activated_at is retained as historical activation metadata.
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.set_user_status(
    IN p_user_id UUID,
    IN p_status identity.account_status,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_previous_actor_class TEXT;
    v_user identity.users%ROWTYPE;
BEGIN
    PERFORM admin.require_user_admin();

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'p_user_id is required.'
            USING ERRCODE = '22023';
    END IF;

    IF p_status IS NULL THEN
        RAISE EXCEPTION 'p_status is required.'
            USING ERRCODE = '22023';
    END IF;

    IF p_status = 'ARCHIVED' THEN
        RAISE EXCEPTION 'Use admin.delete_user() to archive/soft-delete a user.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_user
    FROM identity.users
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User % does not exist.', p_user_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_user.account_status = 'ARCHIVED' THEN
        RAISE EXCEPTION 'User % is archived. Use admin.restore_user() first.', p_user_id
            USING ERRCODE = '55000';
    END IF;

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    PERFORM pg_catalog.set_config(
        'app.audit_operation',
        'admin.set_user_status',
        true
    );
    PERFORM pg_catalog.set_config(
        'app.audit_reason',
        'administrative account status change',
        true
    );

    BEGIN
        UPDATE identity.users
        SET account_status = p_status,
            activated_at = CASE
                WHEN p_status = 'ACTIVE'
                    THEN COALESCE(activated_at, pg_catalog.now())
                ELSE activated_at
            END,
            archived_at = NULL
        WHERE user_id = p_user_id;

    EXCEPTION
        WHEN OTHERS THEN
            PERFORM pg_catalog.set_config(
                'app.actor_class',
                COALESCE(v_previous_actor_class, ''),
                true
            );
            RAISE;
    END;

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        COALESCE(v_previous_actor_class, ''),
        true
    );

    p_result := admin.build_user_json(p_user_id);
END;
$procedure$;


/*
===============================================================================
 12. DELETE - soft delete only

 No DELETE FROM identity.users occurs.

 Soft-delete state:
   account_status = ARCHIVED
   archived_at    = now()
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.delete_user(
    IN p_user_id UUID,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_previous_actor_class TEXT;
    v_user identity.users%ROWTYPE;
BEGIN
    PERFORM admin.require_user_admin();

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'p_user_id is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_user
    FROM identity.users
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User % does not exist.', p_user_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_user.account_status = 'ARCHIVED' THEN
        p_result := admin.build_user_json(p_user_id);
        RETURN;
    END IF;

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    PERFORM pg_catalog.set_config(
        'app.audit_operation',
        'admin.delete_user',
        true
    );
    PERFORM pg_catalog.set_config(
        'app.audit_reason',
        'administrative soft delete',
        true
    );

    BEGIN
        UPDATE identity.users
        SET account_status = 'ARCHIVED',
            archived_at = pg_catalog.now()
        WHERE user_id = p_user_id;

    EXCEPTION
        WHEN OTHERS THEN
            PERFORM pg_catalog.set_config(
                'app.actor_class',
                COALESCE(v_previous_actor_class, ''),
                true
            );
            RAISE;
    END;

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        COALESCE(v_previous_actor_class, ''),
        true
    );

    p_result := admin.build_user_json(p_user_id);
END;
$procedure$;


/*
===============================================================================
 13. RESTORE

 An archived account returns to ACTIVE.
 Historical activated_at is retained; if it was never set, restore establishes
 it so identity.users.ck_users_active remains true.
===============================================================================
*/

CREATE OR REPLACE PROCEDURE admin.restore_user(
    IN p_user_id UUID,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, identity, admin
AS $procedure$
DECLARE
    v_previous_actor_class TEXT;
    v_user identity.users%ROWTYPE;
BEGIN
    PERFORM admin.require_user_admin();

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'p_user_id is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_user
    FROM identity.users
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'User % does not exist.', p_user_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_user.account_status <> 'ARCHIVED' THEN
        p_result := admin.build_user_json(p_user_id);
        RETURN;
    END IF;

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    PERFORM pg_catalog.set_config(
        'app.audit_operation',
        'admin.restore_user',
        true
    );
    PERFORM pg_catalog.set_config(
        'app.audit_reason',
        'administrative account restore',
        true
    );

    BEGIN
        UPDATE identity.users
        SET account_status = 'ACTIVE',
            activated_at = COALESCE(activated_at, pg_catalog.now()),
            archived_at = NULL
        WHERE user_id = p_user_id;

    EXCEPTION
        WHEN OTHERS THEN
            PERFORM pg_catalog.set_config(
                'app.actor_class',
                COALESCE(v_previous_actor_class, ''),
                true
            );
            RAISE;
    END;

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        COALESCE(v_previous_actor_class, ''),
        true
    );

    p_result := admin.build_user_json(p_user_id);
END;
$procedure$;


/*
===============================================================================
 14. Privilege lockdown and explicit admin whitelist
===============================================================================
*/

REVOKE ALL ON FUNCTION admin.require_user_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.build_user_json(UUID) FROM PUBLIC;

REVOKE ALL ON PROCEDURE admin.create_user(TEXT, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.get_user(UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.get_user_by_email(TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.get_user_by_username(TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.list_users(
    identity.account_management_type,
    identity.account_status,
    TEXT,
    BOOLEAN,
    INTEGER,
    INTEGER,
    JSONB
) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.update_user(UUID, JSONB, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.set_user_management_type(
    UUID,
    identity.account_management_type,
    JSONB
) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.set_user_status(
    UUID,
    identity.account_status,
    JSONB
) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.delete_user(UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE admin.restore_user(UUID, JSONB) FROM PUBLIC;


/*
 * Internal helper functions are intentionally not directly executable by the
 * administrative service role. It receives only the procedure surface.
 */
REVOKE ALL ON FUNCTION admin.require_user_admin() FROM brktrkr_admin;
REVOKE ALL ON FUNCTION admin.build_user_json(UUID) FROM brktrkr_admin;


GRANT EXECUTE ON PROCEDURE admin.create_user(TEXT, TEXT, TEXT, JSONB)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.get_user(UUID, JSONB)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.get_user_by_email(TEXT, JSONB)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.get_user_by_username(TEXT, JSONB)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.list_users(
    identity.account_management_type,
    identity.account_status,
    TEXT,
    BOOLEAN,
    INTEGER,
    INTEGER,
    JSONB
)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.update_user(UUID, JSONB, JSONB)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.set_user_management_type(
    UUID,
    identity.account_management_type,
    JSONB
)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.set_user_status(
    UUID,
    identity.account_status,
    JSONB
)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.delete_user(UUID, JSONB)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.restore_user(UUID, JSONB)
TO brktrkr_admin;


/*
===============================================================================
 15. Installation assertions
===============================================================================
*/

DO $validate$
DECLARE
    v_signature TEXT;
BEGIN
    FOREACH v_signature IN ARRAY ARRAY[
        'admin.create_user(text,text,text,jsonb)',
        'admin.get_user(uuid,jsonb)',
        'admin.get_user_by_email(text,jsonb)',
        'admin.get_user_by_username(text,jsonb)',
        'admin.list_users(identity.account_management_type,identity.account_status,text,boolean,integer,integer,jsonb)',
        'admin.update_user(uuid,jsonb,jsonb)',
        'admin.set_user_management_type(uuid,identity.account_management_type,jsonb)',
        'admin.set_user_status(uuid,identity.account_status,jsonb)',
        'admin.delete_user(uuid,jsonb)',
        'admin.restore_user(uuid,jsonb)'
    ]
    LOOP
        IF pg_catalog.to_regprocedure(v_signature) IS NULL THEN
            RAISE EXCEPTION 'Required procedure % was not created.', v_signature;
        END IF;

        IF NOT pg_catalog.has_function_privilege(
            'brktrkr_admin',
            pg_catalog.to_regprocedure(v_signature),
            'EXECUTE'
        ) THEN
            RAISE EXCEPTION 'brktrkr_admin does not have EXECUTE on %.', v_signature;
        END IF;
    END LOOP;

    IF pg_catalog.has_table_privilege(
        'brktrkr_admin',
        'identity.users',
        'SELECT'
    )
    OR pg_catalog.has_table_privilege(
        'brktrkr_admin',
        'identity.users',
        'INSERT'
    )
    OR pg_catalog.has_table_privilege(
        'brktrkr_admin',
        'identity.users',
        'UPDATE'
    )
    OR pg_catalog.has_table_privilege(
        'brktrkr_admin',
        'identity.users',
        'DELETE'
    )
    THEN
        RAISE EXCEPTION
            'Security contract failure: brktrkr_admin must not have direct CRUD privileges on identity.users.'
            USING ERRCODE = '42501';
    END IF;
END;
$validate$;

RESET ROLE;

SELECT pg_temp.bt_mark_completed('5000_function/5100_admin/5140_users.sql');

\echo '[PASS] 5140_users.sql installed successfully.'
