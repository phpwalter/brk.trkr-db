/*
===============================================================================
 File:           5000_function/5700_system/5707_system_audit.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Enforce append-only audit history and automatically capture
                 meaningful business-row changes.
 Depends On:     audit.events
                 audit.changes
                 identity.current_user_id()
                 Complete 0500_collections domain
                 Complete 0600_wanted domain
                 Complete 0700_mocs domain
                 Complete 0800_imports domain
 Creates:        audit.prevent_mutation()
                 audit.capture_row_change()
                 append-only audit triggers
                 selected business-table audit triggers
 Key Rules:      Audit tables cannot be updated/deleted.
                 Unchanged fields do not create audit.change rows.
                 High-volume import staging is intentionally excluded.
                 Actor identity is taken from app.current_user_id.
 Validation:     Runtime append-only triggers reject mutations; generic row audit
                 records only fields whose JSONB values actually changed.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5700_system/5707_system_audit.sql', ARRAY['audit.events', 'audit.changes', 'identity.current_user_id()', 'Complete 0500_collections domain', 'Complete 0600_wanted domain', 'Complete 0700_mocs domain', 'Complete 0800_imports domain']::text[]);



CREATE FUNCTION audit.prevent_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'Audit table %.% is append-only',
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_audit_events_append_only
BEFORE UPDATE OR DELETE
ON audit.events
FOR EACH ROW
EXECUTE FUNCTION audit.prevent_mutation();

CREATE TRIGGER trg_audit_changes_append_only
BEFORE UPDATE OR DELETE
ON audit.changes
FOR EACH ROW
EXECUTE FUNCTION audit.prevent_mutation();


CREATE FUNCTION audit.capture_row_change()
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

    /*
     * Actor contract:
     *
     * USER / ADMIN
     *   Must have authenticated app.current_user_id and therefore remain
     *   fail-closed through identity.current_user_id().
     *
     * IMPORTER
     *   Represents source-driven canonical reconciliation, not a human actor.
     *   Only a PostgreSQL login that is actually a member of lego_importer may
     *   use this class, and source_run_id is mandatory provenance.
     *
     * SYSTEM
     *   Remains fail-closed to an authenticated user unless a dedicated system
     *   contract is introduced separately.
     */
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

    INSERT INTO audit.events (
        event_type,
        actor_user_id,
        entity_schema,
        entity_table,
        entity_id,
        source_run_id
    )
    VALUES (
        TG_OP,
        v_actor_user_id,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        v_entity_id,
        v_source_run_id
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


CREATE TRIGGER trg_audit_users
AFTER INSERT OR UPDATE OR DELETE
ON identity.users
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('user_id');

CREATE TRIGGER trg_audit_family_memberships
AFTER INSERT OR UPDATE OR DELETE
ON identity.family_memberships
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('family_membership_id');

CREATE TRIGGER trg_audit_family_permissions
AFTER INSERT OR UPDATE OR DELETE
ON identity.family_member_permissions
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('family_membership_id');

CREATE TRIGGER trg_audit_guardianships
AFTER INSERT OR UPDATE OR DELETE
ON identity.guardianships
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('guardianship_id');

CREATE TRIGGER trg_audit_catalog_items
AFTER INSERT OR UPDATE OR DELETE
ON catalog.items
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('catalog_item_id');

CREATE TRIGGER trg_audit_catalog_overrides
AFTER INSERT OR UPDATE OR DELETE
ON catalog.admin_overrides
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('admin_override_id');

CREATE TRIGGER trg_audit_collection_entries
AFTER INSERT OR UPDATE OR DELETE
ON collection.entries
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('collection_entry_id');

CREATE TRIGGER trg_audit_collection_instances
AFTER INSERT OR UPDATE OR DELETE
ON collection.instances
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('collection_instance_id');

CREATE TRIGGER trg_audit_wishlists
AFTER INSERT OR UPDATE OR DELETE
ON wanted.wishlists
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('wishlist_id');

CREATE TRIGGER trg_audit_wishlist_entries
AFTER INSERT OR UPDATE OR DELETE
ON wanted.wishlist_entries
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('wishlist_entry_id');

CREATE TRIGGER trg_audit_build_goals
AFTER INSERT OR UPDATE OR DELETE
ON wanted.build_goals
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('build_goal_id');

CREATE TRIGGER trg_audit_mocs
AFTER INSERT OR UPDATE OR DELETE
ON moc.mocs
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('moc_id');

CREATE TRIGGER trg_audit_moc_revisions
AFTER INSERT OR UPDATE OR DELETE
ON moc.revisions
FOR EACH ROW
EXECUTE FUNCTION audit.capture_row_change('moc_revision_id');

\echo '[PASS] 1008_audit_function.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5707_system_audit.sql');
