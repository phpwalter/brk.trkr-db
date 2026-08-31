/*
===============================================================================
 File:           5000_function/5100_admin/5100_admin_common.sql
 Project:        BrickTrackr
 Schema Version: 1.2.0
 PostgreSQL:     16+
 Purpose:        Shared system-administrator helpers and audit context support.
 Revision:       Removes invalid schema qualification from PostgreSQL
                 special expressions such as COALESCE/NULLIF.
                 INSERT audit changes now omit JSON-null fields so only
                 meaningful populated values are recorded.
 Depends On:     5000_function/5700_system/5707_system_audit.sql
                 5000_function/5700_system/5709_system_request_context.sql
                 identity.current_user_id()
 Creates:        audit.capture_row_change()
                 admin.assert_system_admin()
 Key Rules:      PostgreSQL role membership establishes privileged authority.
                 actor_class is audit context, not caller authorization.
                 USER actors require an authenticated BrickTrackr user.
                 ADMIN actors may legitimately have no BrickTrackr user yet.
                 IMPORTER actors require brktrkr_import membership and a
                 source_run_id.
                 SYSTEM actors require owner/migrator authority.
===============================================================================
*/

\set ON_ERROR_STOP on

/*
 * This file is compatible with both the normal full installer and the
 * live-update preflight shim because both expose pg_temp.bt_preflight().
 */
SELECT pg_temp.bt_preflight('5000_function/5100_admin/5100_admin_common.sql', ARRAY['5000_function/5700_system/5707_system_audit.sql', '5000_function/5700_system/5709_system_request_context.sql', 'identity.current_user_id()']::text[]);


/*
===============================================================================
 Canonical row-audit trigger

 Actor rules
 -----------
 USER
     - requires identity.current_user_id()
     - actor_user_id is the authenticated BrickTrackr user

 ADMIN
     - requires session_user membership in brktrkr_admin
       (brktrkr_owner is also accepted for controlled owner maintenance)
     - actor_user_id is optional
     - no existing BrickTrackr user is required
     - database principal is recorded in metadata

 IMPORTER
     - requires session_user membership in brktrkr_import
     - requires app.source_run_id
     - actor_user_id is NULL
     - database principal is recorded in metadata

 SYSTEM
     - requires brktrkr_owner or brktrkr_migrator membership
     - actor_user_id is optional
     - database principal is recorded in metadata

 This explicitly solves first-user bootstrap:
     brktrkr_admin_login -> admin.create_user()
 can be audited before any identity.users row exists.
===============================================================================
*/

CREATE OR REPLACE FUNCTION audit.capture_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit, identity
AS $function$
DECLARE
    v_pk_column text := TG_ARGV[0];

    v_old jsonb;
    v_new jsonb;

    v_entity_id text;
    v_event_id uuid;

    v_actor_class text;
    v_actor_user_id uuid;
    v_source_run_id uuid;

    v_audit_reason text;
    v_audit_operation text;
    v_metadata jsonb;

    v_context_user_text text;
    v_source_run_text text;
    v_key text;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old := pg_catalog.to_jsonb(OLD);
    END IF;

    IF TG_OP <> 'DELETE' THEN
        v_new := pg_catalog.to_jsonb(NEW);
    END IF;

    v_entity_id :=
        COALESCE(
            v_new ->> v_pk_column,
            v_old ->> v_pk_column
        );

    v_actor_class :=
        pg_catalog.upper(
            COALESCE(
                NULLIF(
                    pg_catalog.current_setting('app.actor_class', true),
                    ''
                ),
                'USER'
            )
        );

    /*
     * Parse optional user context ourselves for ADMIN/SYSTEM actors.
     * Do not call identity.current_user_id() in those branches because that
     * helper intentionally raises when no authenticated application user exists.
     */
    v_context_user_text :=
        NULLIF(
            pg_catalog.current_setting('app.current_user_id', true),
            ''
        );

    v_source_run_text :=
        NULLIF(
            pg_catalog.current_setting('app.source_run_id', true),
            ''
        );

    CASE v_actor_class
        WHEN 'USER' THEN
            v_actor_user_id := identity.current_user_id();

            IF v_source_run_text IS NOT NULL THEN
                BEGIN
                    v_source_run_id := v_source_run_text::uuid;
                EXCEPTION
                    WHEN invalid_text_representation THEN
                        RAISE EXCEPTION
                            'USER audit context has malformed source_run_id'
                            USING ERRCODE = '22023';
                END;
            END IF;

        WHEN 'ADMIN' THEN
            IF NOT (
                pg_catalog.pg_has_role(
                    session_user,
                    'brktrkr_admin',
                    'MEMBER'
                )
                OR pg_catalog.pg_has_role(
                    session_user,
                    'brktrkr_owner',
                    'MEMBER'
                )
                OR session_user = 'brktrkr_owner'
            ) THEN
                RAISE EXCEPTION
                    'ADMIN audit context requires brktrkr_admin or brktrkr_owner authority'
                    USING ERRCODE = '42501';
            END IF;

            IF v_context_user_text IS NOT NULL THEN
                BEGIN
                    v_actor_user_id := v_context_user_text::uuid;
                EXCEPTION
                    WHEN invalid_text_representation THEN
                        RAISE EXCEPTION
                            'ADMIN audit context has malformed current_user_id'
                            USING ERRCODE = '22023';
                END;
            ELSE
                v_actor_user_id := NULL;
            END IF;

            IF v_source_run_text IS NOT NULL THEN
                BEGIN
                    v_source_run_id := v_source_run_text::uuid;
                EXCEPTION
                    WHEN invalid_text_representation THEN
                        RAISE EXCEPTION
                            'ADMIN audit context has malformed source_run_id'
                            USING ERRCODE = '22023';
                END;
            END IF;

        WHEN 'IMPORTER' THEN
            IF NOT pg_catalog.pg_has_role(
                session_user,
                'brktrkr_import',
                'MEMBER'
            ) THEN
                RAISE EXCEPTION
                    'IMPORTER audit context requires brktrkr_import membership'
                    USING ERRCODE = '42501';
            END IF;

            IF v_source_run_text IS NULL THEN
                RAISE EXCEPTION
                    'IMPORTER audit context requires source_run_id'
                    USING ERRCODE = '28000';
            END IF;

            BEGIN
                v_source_run_id := v_source_run_text::uuid;
            EXCEPTION
                WHEN invalid_text_representation THEN
                    RAISE EXCEPTION
                        'IMPORTER audit context has malformed source_run_id'
                        USING ERRCODE = '22023';
            END;

            v_actor_user_id := NULL;

        WHEN 'SYSTEM' THEN
            IF NOT (
                pg_catalog.pg_has_role(
                    session_user,
                    'brktrkr_owner',
                    'MEMBER'
                )
                OR pg_catalog.pg_has_role(
                    session_user,
                    'brktrkr_migrator',
                    'MEMBER'
                )
                OR session_user = 'brktrkr_owner'
            ) THEN
                RAISE EXCEPTION
                    'SYSTEM audit context requires brktrkr_owner or brktrkr_migrator authority'
                    USING ERRCODE = '42501';
            END IF;

            IF v_context_user_text IS NOT NULL THEN
                BEGIN
                    v_actor_user_id := v_context_user_text::uuid;
                EXCEPTION
                    WHEN invalid_text_representation THEN
                        RAISE EXCEPTION
                            'SYSTEM audit context has malformed current_user_id'
                            USING ERRCODE = '22023';
                END;
            ELSE
                v_actor_user_id := NULL;
            END IF;

            IF v_source_run_text IS NOT NULL THEN
                BEGIN
                    v_source_run_id := v_source_run_text::uuid;
                EXCEPTION
                    WHEN invalid_text_representation THEN
                        RAISE EXCEPTION
                            'SYSTEM audit context has malformed source_run_id'
                            USING ERRCODE = '22023';
                END;
            END IF;

        ELSE
            RAISE EXCEPTION
                'Unsupported audit actor_class "%"', v_actor_class
                USING ERRCODE = '22023';
    END CASE;

    v_audit_reason :=
        NULLIF(
            pg_catalog.current_setting('app.audit_reason', true),
            ''
        );

    v_audit_operation :=
        NULLIF(
            pg_catalog.current_setting('app.audit_operation', true),
            ''
        );

    v_metadata :=
        pg_catalog.jsonb_strip_nulls(
            pg_catalog.jsonb_build_object(
                'actor_class', v_actor_class,
                'database_user', session_user,
                'operation', v_audit_operation,
                'reason', v_audit_reason
            )
        );

    INSERT INTO audit.events (
        event_type,
        actor_user_id,
        entity_schema,
        entity_table,
        entity_id,
        source_run_id,
        metadata
    )
    VALUES (
        TG_OP,
        v_actor_user_id,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        v_entity_id,
        v_source_run_id,
        v_metadata
    )
    RETURNING audit_event_id
    INTO v_event_id;

    FOR v_key IN
        SELECT key
        FROM (
            SELECT pg_catalog.jsonb_object_keys(
                COALESCE(v_old, '{}'::jsonb)
            ) AS key

            UNION

            SELECT pg_catalog.jsonb_object_keys(
                COALESCE(v_new, '{}'::jsonb)
            ) AS key
        ) AS keys
    LOOP
        /*
         * INSERT:
         *   record only fields whose new JSON value is not JSON null.
         *   This suppresses noise such as old=NULL/new=null for nullable
         *   columns that were not populated on creation.
         *
         * UPDATE:
         *   record only true before/after differences.
         *
         * DELETE:
         *   record fields that previously had a non-null JSON value.
         */
        IF (
            TG_OP = 'INSERT'
            AND (v_new -> v_key) IS DISTINCT FROM 'null'::jsonb
        )
        OR (
            TG_OP = 'UPDATE'
            AND (v_old -> v_key) IS DISTINCT FROM (v_new -> v_key)
        )
        OR (
            TG_OP = 'DELETE'
            AND (v_old -> v_key) IS DISTINCT FROM 'null'::jsonb
        )
        THEN
            INSERT INTO audit.changes (
                audit_event_id,
                field_name,
                old_value,
                new_value
            )
            VALUES (
                v_event_id,
                v_key,
                CASE
                    WHEN TG_OP = 'INSERT' THEN NULL
                    ELSE v_old -> v_key
                END,
                CASE
                    WHEN TG_OP = 'DELETE' THEN NULL
                    ELSE v_new -> v_key
                END
            );
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$function$;


/*
===============================================================================
 System-admin authorization guard

 Authorization is PostgreSQL-role based. app.actor_class never grants access.
===============================================================================
*/

CREATE OR REPLACE FUNCTION admin.assert_system_admin()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF NOT (
        pg_catalog.pg_has_role(
            session_user,
            'brktrkr_admin',
            'MEMBER'
        )
        OR pg_catalog.pg_has_role(
            session_user,
            'brktrkr_owner',
            'MEMBER'
        )
        OR session_user = 'brktrkr_owner'
    ) THEN
        RAISE EXCEPTION
            'System administrator role required'
            USING ERRCODE = '42501';
    END IF;
END;
$function$;


REVOKE EXECUTE ON FUNCTION audit.capture_row_change() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION admin.assert_system_admin() FROM PUBLIC;

SELECT pg_temp.bt_mark_completed('5000_function/5100_admin/5100_admin_common.sql');

\echo '[PASS] 5100_admin_common.sql installed successfully.'
