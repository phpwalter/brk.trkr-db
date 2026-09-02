/*
===============================================================================
 File:           5000_function/5100_admin/5110_admin_catalog_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Generic canonical catalog lifecycle engine and system-admin
                 convenience procedures.
 Depends On:     5000_function/5100_admin/5100_admin_common.sql
                 catalog.items
 Creates:        catalog.transition_item_status(...)
                 admin.retire_catalog_item(...)
                 admin.archive_catalog_item(...)
                 admin.restore_catalog_item(...)
 Key Rules:      Canonical lifecycle logic is implemented once.
                 Runtime/admin callers never access catalog tables directly.
                 Admin entry points require brktrkr_admin membership.
                 A non-empty reason is mandatory for every lifecycle change.
                 SOURCE_MISSING remains importer-controlled.
                 UNRESOLVED_CUSTOM requires a dedicated resolution workflow.
                 No hard-delete operation is exposed.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5100_admin/5110_admin_catalog_lifecycle.sql', ARRAY['5000_function/5100_admin/5100_admin_common.sql', 'catalog.items']::text[]);

CREATE OR REPLACE FUNCTION catalog.transition_item_status(
    p_catalog_item_id uuid,
    p_new_status catalog.item_status,
    p_reason text,
    p_operation text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
DECLARE
    v_item catalog.items%ROWTYPE;
    v_old_status catalog.item_status;

    v_previous_reason text;
    v_previous_operation text;
BEGIN
    IF p_catalog_item_id IS NULL THEN
        RAISE EXCEPTION
            'catalog_item_id is required'
            USING ERRCODE = '22004';
    END IF;

    IF p_new_status IS NULL THEN
        RAISE EXCEPTION
            'new catalog item status is required'
            USING ERRCODE = '22004';
    END IF;

    IF p_reason IS NULL OR pg_catalog.btrim(p_reason) = '' THEN
        RAISE EXCEPTION
            'Lifecycle reason is required'
            USING ERRCODE = '22023';
    END IF;

    IF p_operation IS NULL OR pg_catalog.btrim(p_operation) = '' THEN
        RAISE EXCEPTION
            'Lifecycle operation is required'
            USING ERRCODE = '22023';
    END IF;

    SELECT i.*
      INTO v_item
      FROM catalog.items i
     WHERE i.catalog_item_id = p_catalog_item_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Catalog item % was not found',
            p_catalog_item_id
            USING ERRCODE = 'P0002';
    END IF;

    v_old_status := v_item.status;

    IF v_old_status = p_new_status THEN
        RAISE EXCEPTION
            'Catalog item % is already %',
            p_catalog_item_id,
            p_new_status
            USING ERRCODE = '23514';
    END IF;

    /*
     * These states are intentionally outside the generic administrator
     * lifecycle engine.
     */
    IF v_old_status = 'SOURCE_MISSING'
       OR p_new_status = 'SOURCE_MISSING'
    THEN
        RAISE EXCEPTION
            'SOURCE_MISSING lifecycle is controlled by authoritative reconciliation'
            USING ERRCODE = '42501';
    END IF;

    IF v_old_status = 'UNRESOLVED_CUSTOM'
       OR p_new_status = 'UNRESOLVED_CUSTOM'
    THEN
        RAISE EXCEPTION
            'UNRESOLVED_CUSTOM lifecycle requires the dedicated resolution workflow'
            USING ERRCODE = '42501';
    END IF;

    IF NOT (
           (v_old_status = 'ACTIVE'   AND p_new_status IN ('RETIRED', 'ARCHIVED'))
        OR (v_old_status = 'RETIRED'  AND p_new_status IN ('ACTIVE', 'ARCHIVED'))
        OR (v_old_status = 'ARCHIVED' AND p_new_status IN ('ACTIVE', 'RETIRED'))
    ) THEN
        RAISE EXCEPTION
            'Invalid catalog lifecycle transition: % -> %',
            v_old_status,
            p_new_status
            USING ERRCODE = '23514';
    END IF;

    v_previous_reason :=
        pg_catalog.current_setting('app.audit_reason', true);
    v_previous_operation :=
        pg_catalog.current_setting('app.audit_operation', true);

    PERFORM pg_catalog.set_config(
        'app.audit_reason',
        pg_catalog.btrim(p_reason),
        true
    );

    PERFORM pg_catalog.set_config(
        'app.audit_operation',
        pg_catalog.upper(pg_catalog.btrim(p_operation)),
        true
    );

    BEGIN
        UPDATE catalog.items
           SET status = p_new_status,
               archived_at = CASE
                   WHEN p_new_status = 'ARCHIVED'
                       THEN pg_catalog.clock_timestamp()
                   ELSE NULL
               END
         WHERE catalog_item_id = p_catalog_item_id
         RETURNING *
          INTO v_item;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM pg_catalog.set_config(
                'app.audit_reason',
                COALESCE(v_previous_reason, ''),
                true
            );
            PERFORM pg_catalog.set_config(
                'app.audit_operation',
                COALESCE(v_previous_operation, ''),
                true
            );
            RAISE;
    END;

    PERFORM pg_catalog.set_config(
        'app.audit_reason',
        COALESCE(v_previous_reason, ''),
        true
    );
    PERFORM pg_catalog.set_config(
        'app.audit_operation',
        COALESCE(v_previous_operation, ''),
        true
    );

    RETURN pg_catalog.jsonb_build_object(
        'catalog_item_id', v_item.catalog_item_id,
        'item_kind', v_item.item_kind::text,
        'canonical_name', v_item.canonical_name,
        'old_status', v_old_status::text,
        'new_status', v_item.status::text,
        'archived_at', v_item.archived_at
    );
END;
$$;


/*
 * Admin convenience procedures.
 *
 * actor_class is set by trusted code after the PostgreSQL membership check.
 * It is never used as the authorization decision.
 */
CREATE OR REPLACE FUNCTION admin.retire_catalog_item(
    p_catalog_item_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, catalog
AS $$
DECLARE
    v_previous_actor_class text;
    v_result jsonb;
BEGIN
    PERFORM admin.assert_system_admin();

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    BEGIN
        v_result := catalog.transition_item_status(
            p_catalog_item_id,
            'RETIRED'::catalog.item_status,
            p_reason,
            'RETIRE'
        );
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

    RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION admin.archive_catalog_item(
    p_catalog_item_id uuid,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, catalog
AS $$
DECLARE
    v_previous_actor_class text;
    v_result jsonb;
BEGIN
    PERFORM admin.assert_system_admin();

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    BEGIN
        v_result := catalog.transition_item_status(
            p_catalog_item_id,
            'ARCHIVED'::catalog.item_status,
            p_reason,
            'ARCHIVE'
        );
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

    RETURN v_result;
END;
$$;


CREATE OR REPLACE FUNCTION admin.restore_catalog_item(
    p_catalog_item_id uuid,
    p_restore_status text,
    p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, admin, catalog
AS $$
DECLARE
    v_previous_actor_class text;
    v_target_status catalog.item_status;
    v_result jsonb;
BEGIN
    PERFORM admin.assert_system_admin();

    IF p_restore_status IS NULL
       OR pg_catalog.upper(pg_catalog.btrim(p_restore_status))
          NOT IN ('ACTIVE', 'RETIRED')
    THEN
        RAISE EXCEPTION
            'restore status must be ACTIVE or RETIRED'
            USING ERRCODE = '22023';
    END IF;

    v_target_status :=
        pg_catalog.upper(pg_catalog.btrim(p_restore_status))::catalog.item_status;

    v_previous_actor_class :=
        pg_catalog.current_setting('app.actor_class', true);

    PERFORM pg_catalog.set_config(
        'app.actor_class',
        'ADMIN',
        true
    );

    BEGIN
        v_result := catalog.transition_item_status(
            p_catalog_item_id,
            v_target_status,
            p_reason,
            'RESTORE'
        );
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

    RETURN v_result;
END;
$$;


COMMENT ON FUNCTION admin.retire_catalog_item(uuid, text) IS
    'System-admin-only canonical catalog transition to RETIRED. Requires an audit reason.';

COMMENT ON FUNCTION admin.archive_catalog_item(uuid, text) IS
    'System-admin-only canonical catalog transition to ARCHIVED. Requires an audit reason.';

COMMENT ON FUNCTION admin.restore_catalog_item(uuid, text, text) IS
    'System-admin-only restore of an ARCHIVED canonical catalog item to ACTIVE or RETIRED. Requires an audit reason.';

SELECT pg_temp.bt_mark_completed('5000_function/5100_admin/5110_admin_catalog_lifecycle.sql');
