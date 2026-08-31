\set ON_ERROR_STOP on

/*
===============================================================================
 File:           5000_function/5100_admin/5150_audit.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Controlled administrative read access to private audit history.
 Depends On:     5000_function/5100_admin/5140_users.sql
                 0900_audit/0900_audit_events.sql
                 0900_audit/0901_audit_changes.sql
                 1100_security/1100_roles.sql
 Creates:        admin.get_audit_event(...)
                 admin.list_audit_events(...)
 Security:       brktrkr_admin receives EXECUTE only.
                 No direct SELECT privilege is granted on audit.events or
                 audit.changes.
 Behavior:       Read-only. Audit reads do not generate audit events.
===============================================================================
*/

SELECT pg_temp.bt_preflight('5000_function/5100_admin/5150_audit.sql', ARRAY['5000_function/5100_admin/5140_users.sql', '0900_audit/0900_audit_events.sql', '0900_audit/0901_audit_changes.sql', '1100_security/1100_roles.sql']::text[]);

DO $preflight$
BEGIN
    IF pg_catalog.to_regclass('audit.events') IS NULL THEN
        RAISE EXCEPTION 'Required table audit.events does not exist.';
    END IF;

    IF pg_catalog.to_regclass('audit.changes') IS NULL THEN
        RAISE EXCEPTION 'Required table audit.changes does not exist.';
    END IF;

    IF pg_catalog.to_regprocedure('admin.require_user_admin()') IS NULL THEN
        RAISE EXCEPTION 'Required function admin.require_user_admin() does not exist.';
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

GRANT USAGE ON SCHEMA audit TO brktrkr_owner;
GRANT SELECT ON TABLE audit.events, audit.changes TO brktrkr_owner;

GRANT USAGE ON SCHEMA admin TO brktrkr_admin;

REVOKE ALL PRIVILEGES ON TABLE audit.events FROM brktrkr_admin;
REVOKE ALL PRIVILEGES ON TABLE audit.changes FROM brktrkr_admin;

SET ROLE brktrkr_owner;

CREATE OR REPLACE PROCEDURE admin.get_audit_event(
    IN p_audit_event_id UUID,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit, admin
AS $procedure$
BEGIN
    PERFORM admin.require_user_admin();

    IF p_audit_event_id IS NULL THEN
        RAISE EXCEPTION 'p_audit_event_id is required.'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        pg_catalog.to_jsonb(e)
        ||
        pg_catalog.jsonb_build_object(
            'changes',
            COALESCE(
                (
                    SELECT pg_catalog.jsonb_agg(
                        pg_catalog.to_jsonb(c)
                        ORDER BY c.field_name
                    )
                    FROM audit.changes AS c
                    WHERE c.audit_event_id = e.audit_event_id
                ),
                '[]'::JSONB
            )
        )
    INTO p_result
    FROM audit.events AS e
    WHERE e.audit_event_id = p_audit_event_id;

    IF p_result IS NULL THEN
        RAISE EXCEPTION 'Audit event % does not exist.', p_audit_event_id
            USING ERRCODE = 'P0002';
    END IF;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE admin.list_audit_events(
    IN p_event_type TEXT DEFAULT NULL,
    IN p_actor_user_id UUID DEFAULT NULL,
    IN p_entity_schema TEXT DEFAULT NULL,
    IN p_entity_table TEXT DEFAULT NULL,
    IN p_entity_id TEXT DEFAULT NULL,
    IN p_source_run_id UUID DEFAULT NULL,
    IN p_date_from TIMESTAMPTZ DEFAULT NULL,
    IN p_date_to TIMESTAMPTZ DEFAULT NULL,
    IN p_limit INTEGER DEFAULT 100,
    IN p_offset INTEGER DEFAULT 0,
    INOUT p_result JSONB DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit, admin
AS $procedure$
DECLARE
    v_event_type TEXT;
    v_entity_schema TEXT;
    v_entity_table TEXT;
    v_entity_id TEXT;
    v_limit INTEGER;
    v_offset INTEGER;
    v_total BIGINT;
BEGIN
    PERFORM admin.require_user_admin();

    v_event_type := NULLIF(pg_catalog.btrim(p_event_type), '');
    v_entity_schema := NULLIF(pg_catalog.btrim(p_entity_schema), '');
    v_entity_table := NULLIF(pg_catalog.btrim(p_entity_table), '');
    v_entity_id := NULLIF(pg_catalog.btrim(p_entity_id), '');

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

    IF p_date_from IS NOT NULL
       AND p_date_to IS NOT NULL
       AND p_date_from > p_date_to
    THEN
        RAISE EXCEPTION 'p_date_from may not be later than p_date_to.'
            USING ERRCODE = '22023';
    END IF;

    SELECT pg_catalog.count(*)
    INTO v_total
    FROM audit.events AS e
    WHERE (v_event_type IS NULL OR e.event_type::TEXT = v_event_type)
      AND (p_actor_user_id IS NULL OR e.actor_user_id = p_actor_user_id)
      AND (v_entity_schema IS NULL OR e.entity_schema = v_entity_schema)
      AND (v_entity_table IS NULL OR e.entity_table = v_entity_table)
      AND (v_entity_id IS NULL OR e.entity_id = v_entity_id)
      AND (p_source_run_id IS NULL OR e.source_run_id = p_source_run_id)
      AND (p_date_from IS NULL OR e.occurred_at >= p_date_from)
      AND (p_date_to IS NULL OR e.occurred_at <= p_date_to);

    SELECT
        pg_catalog.jsonb_build_object(
            'total', v_total,
            'limit', v_limit,
            'offset', v_offset,
            'events',
            COALESCE(
                pg_catalog.jsonb_agg(
                    q.event_json
                    ORDER BY q.occurred_at DESC, q.audit_event_id DESC
                ),
                '[]'::JSONB
            )
        )
    INTO p_result
    FROM (
        SELECT
            e.audit_event_id,
            e.occurred_at,
            pg_catalog.to_jsonb(e)
            ||
            pg_catalog.jsonb_build_object(
                'changes',
                COALESCE(
                    (
                        SELECT pg_catalog.jsonb_agg(
                            pg_catalog.to_jsonb(c)
                            ORDER BY c.field_name
                        )
                        FROM audit.changes AS c
                        WHERE c.audit_event_id = e.audit_event_id
                    ),
                    '[]'::JSONB
                )
            ) AS event_json
        FROM audit.events AS e
        WHERE (v_event_type IS NULL OR e.event_type::TEXT = v_event_type)
          AND (p_actor_user_id IS NULL OR e.actor_user_id = p_actor_user_id)
          AND (v_entity_schema IS NULL OR e.entity_schema = v_entity_schema)
          AND (v_entity_table IS NULL OR e.entity_table = v_entity_table)
          AND (v_entity_id IS NULL OR e.entity_id = v_entity_id)
          AND (p_source_run_id IS NULL OR e.source_run_id = p_source_run_id)
          AND (p_date_from IS NULL OR e.occurred_at >= p_date_from)
          AND (p_date_to IS NULL OR e.occurred_at <= p_date_to)
        ORDER BY e.occurred_at DESC, e.audit_event_id DESC
        LIMIT v_limit
        OFFSET v_offset
    ) AS q;
END;
$procedure$;

REVOKE ALL ON PROCEDURE admin.get_audit_event(UUID, JSONB)
FROM PUBLIC;

REVOKE ALL ON PROCEDURE admin.list_audit_events(
    TEXT,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    INTEGER,
    INTEGER,
    JSONB
)
FROM PUBLIC;

GRANT EXECUTE ON PROCEDURE admin.get_audit_event(UUID, JSONB)
TO brktrkr_admin;

GRANT EXECUTE ON PROCEDURE admin.list_audit_events(
    TEXT,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    INTEGER,
    INTEGER,
    JSONB
)
TO brktrkr_admin;

DO $validate$
BEGIN
    IF pg_catalog.to_regprocedure(
        'admin.get_audit_event(uuid,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION 'admin.get_audit_event(uuid,jsonb) was not created.';
    END IF;

    IF pg_catalog.to_regprocedure(
        'admin.list_audit_events(text,uuid,text,text,text,uuid,timestamptz,timestamptz,integer,integer,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION 'admin.list_audit_events(...) was not created.';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'brktrkr_admin',
        pg_catalog.to_regprocedure('admin.get_audit_event(uuid,jsonb)'),
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'brktrkr_admin lacks EXECUTE on admin.get_audit_event().'
            USING ERRCODE = '42501';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'brktrkr_admin',
        pg_catalog.to_regprocedure(
            'admin.list_audit_events(text,uuid,text,text,text,uuid,timestamptz,timestamptz,integer,integer,jsonb)'
        ),
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'brktrkr_admin lacks EXECUTE on admin.list_audit_events().'
            USING ERRCODE = '42501';
    END IF;

    IF pg_catalog.has_table_privilege(
        'brktrkr_admin',
        'audit.events',
        'SELECT'
    )
    OR pg_catalog.has_table_privilege(
        'brktrkr_admin',
        'audit.changes',
        'SELECT'
    )
    THEN
        RAISE EXCEPTION
            'Security contract failure: brktrkr_admin must not directly SELECT private audit tables.'
            USING ERRCODE = '42501';
    END IF;
END;
$validate$;

RESET ROLE;

SELECT pg_temp.bt_mark_completed('5000_function/5100_admin/5150_audit.sql');

\echo '[PASS] 5150_audit.sql installed successfully.'
