/*
===============================================================================
 File:           5000_function/5100_admin/5100_admin_common.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Shared system-administrator helpers and audit context support.
 Depends On:     5000_function/5700_system/5707_system_audit.sql
                 5000_function/5700_system/5709_system_request_context.sql
                 identity.current_user_id()
 Creates:        admin.assert_system_admin()
 Key Rules:      Admin authorization is PostgreSQL-role based.
                 actor_class is audit context only.
                 Admin mutations may attach operation/reason metadata to the
                 existing row-audit event.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5100_admin/5100_admin_common.sql', ARRAY['5000_function/5700_system/5707_system_audit.sql', '5000_function/5700_system/5709_system_request_context.sql', 'identity.current_user_id()']::text[]);

CREATE OR REPLACE FUNCTION audit.capture_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit, identity
AS $$
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

    v_key text;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        v_old := to_jsonb(OLD);
    END IF;

    IF TG_OP <> 'DELETE' THEN
        v_new := to_jsonb(NEW);
    END IF;

    v_entity_id :=
        coalesce(
            v_new ->> v_pk_column,
            v_old ->> v_pk_column
        );

    v_actor_class :=
        COALESCE(
            NULLIF(pg_catalog.current_setting('app.actor_class', true), ''),
            'USER'
        );

    IF v_actor_class = 'IMPORTER' THEN
        IF NOT pg_catalog.pg_has_role(
            session_user,
            'lego_importer',
            'MEMBER'
        ) THEN
            RAISE EXCEPTION
                'IMPORTER audit context requires lego_importer membership'
                USING ERRCODE = '42501';
        END IF;

        BEGIN
            v_source_run_id :=
                NULLIF(
                    pg_catalog.current_setting(
                        'app.source_run_id',
                        true
                    ),
                    ''
                )::uuid;
        EXCEPTION
            WHEN invalid_text_representation THEN
                RAISE EXCEPTION
                    'IMPORTER audit context has malformed source_run_id'
                    USING ERRCODE = '22023';
        END;

        IF v_source_run_id IS NULL THEN
            RAISE EXCEPTION
                'IMPORTER audit context requires source_run_id'
                USING ERRCODE = '28000';
        END IF;

        v_actor_user_id := NULL;
    ELSE
        v_actor_user_id := identity.current_user_id();
        v_source_run_id := NULLIF(
            pg_catalog.current_setting(
                'app.source_run_id',
                true
            ),
            ''
        )::uuid;
    END IF;

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
            SELECT jsonb_object_keys(
                coalesce(v_old, '{}'::jsonb)
            ) AS key

            UNION

            SELECT jsonb_object_keys(
                coalesce(v_new, '{}'::jsonb)
            ) AS key
        ) keys
    LOOP
        IF (v_old -> v_key)
           IS DISTINCT FROM
           (v_new -> v_key)
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
                v_old -> v_key,
                v_new -> v_key
            );
        END IF;
    END LOOP;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;


/*
 * Defense-in-depth guard used by every admin entry point.
 *
 * Authorization is based on PostgreSQL role membership, never actor_class.
 * actor_class is audit context only.
 */
CREATE OR REPLACE FUNCTION admin.assert_system_admin()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
    IF NOT pg_catalog.pg_has_role(
        session_user,
        'lego_admin',
        'MEMBER'
    ) THEN
        RAISE EXCEPTION
            'System administrator role required'
            USING ERRCODE = '42501';
    END IF;
END;
$$;


/*
 * Single canonical lifecycle engine.
 *
 * This function is intentionally not granted to lego_admin or runtime roles.
 * Admin callers use the convenience procedures below.
 *
 * Generic lifecycle transitions:
 *
 *   ACTIVE   -> RETIRED
 *   ACTIVE   -> ARCHIVED
 *   RETIRED  -> ACTIVE
 *   RETIRED  -> ARCHIVED
 *   ARCHIVED -> ACTIVE
 *   ARCHIVED -> RETIRED
 *
 * SOURCE_MISSING is controlled by authoritative reconciliation.
 * UNRESOLVED_CUSTOM requires explicit resolve/promote administration.
 */

SELECT pg_temp.bt_mark_completed('5000_function/5100_admin/5100_admin_common.sql');
