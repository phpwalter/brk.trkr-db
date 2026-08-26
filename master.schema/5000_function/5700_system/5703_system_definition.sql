/*
===============================================================================
 File:           5000_function/5700_system/5703_system_definition.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Enforce semantic inventory-version immutability and definition
                 authority integrity.
 Depends On:     definition.inventory_definitions
                 definition.inventory_versions
                 definition.requirement_groups
                 definition.requirement_options
                 definition.definition_authority
 Creates:        definition.effective_inventory_version()
                 definition.prevent_finalized_version_mutation()
                 definition.prevent_finalized_graph_mutation()
                 definition.validate_authority()
                 associated triggers
 Key Rules:      Finalized semantic inventory versions are immutable.
                 Requirement graphs belonging to finalized versions are
                 immutable.
                 Admin-authority versions must belong to the same inventory
                 definition and be marked as administrator corrections.
 Validation:     Runtime triggers reject mutation/authority inconsistencies;
                 function validation verifies required functions/triggers.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5700_system/5703_system_definition.sql', ARRAY['definition.inventory_definitions', 'definition.inventory_versions', 'definition.requirement_groups', 'definition.requirement_options', 'definition.definition_authority']::text[]);



CREATE FUNCTION definition.effective_inventory_version(
    p_inventory_definition_id uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(
        active_admin_version_id,
        latest_source_version_id
    )
    FROM definition.definition_authority
    WHERE inventory_definition_id =
          p_inventory_definition_id;
$$;


CREATE FUNCTION definition.prevent_finalized_version_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'FINALIZED' THEN
        RAISE EXCEPTION
            'Finalized inventory version "%" is immutable',
            OLD.inventory_version_id;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inventory_version_immutable
BEFORE UPDATE OR DELETE
ON definition.inventory_versions
FOR EACH ROW
EXECUTE FUNCTION definition.prevent_finalized_version_mutation();


CREATE FUNCTION definition.prevent_finalized_graph_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_version_id uuid;
    v_group_id bigint;
    v_status definition.inventory_version_status;
BEGIN
    IF TG_TABLE_NAME = 'requirement_groups' THEN
        IF TG_OP = 'DELETE' THEN
            v_version_id := OLD.inventory_version_id;
        ELSE
            v_version_id := NEW.inventory_version_id;
        END IF;
    ELSE
        IF TG_OP = 'DELETE' THEN
            v_group_id := OLD.requirement_group_id;
        ELSE
            v_group_id := NEW.requirement_group_id;
        END IF;

        SELECT inventory_version_id
        INTO v_version_id
        FROM definition.requirement_groups
        WHERE requirement_group_id = v_group_id;
    END IF;

    SELECT status
    INTO v_status
    FROM definition.inventory_versions
    WHERE inventory_version_id = v_version_id;

    IF v_status = 'FINALIZED' THEN
        RAISE EXCEPTION
            'Requirement graph for finalized inventory version "%" is immutable',
            v_version_id;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_requirement_groups_immutable
BEFORE INSERT OR UPDATE OR DELETE
ON definition.requirement_groups
FOR EACH ROW
EXECUTE FUNCTION definition.prevent_finalized_graph_mutation();

CREATE TRIGGER trg_requirement_options_immutable
BEFORE INSERT OR UPDATE OR DELETE
ON definition.requirement_options
FOR EACH ROW
EXECUTE FUNCTION definition.prevent_finalized_graph_mutation();


CREATE FUNCTION definition.validate_authority()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_definition_id uuid;
    v_is_admin boolean;
BEGIN
    IF NEW.latest_source_version_id IS NOT NULL THEN
        SELECT inventory_definition_id
        INTO v_definition_id
        FROM definition.inventory_versions
        WHERE inventory_version_id =
              NEW.latest_source_version_id;

        IF v_definition_id IS DISTINCT FROM
           NEW.inventory_definition_id
        THEN
            RAISE EXCEPTION
                'Latest source version belongs to another inventory definition';
        END IF;
    END IF;

    IF NEW.active_admin_version_id IS NOT NULL THEN
        SELECT
            inventory_definition_id,
            is_admin_correction
        INTO
            v_definition_id,
            v_is_admin
        FROM definition.inventory_versions
        WHERE inventory_version_id =
              NEW.active_admin_version_id;

        IF v_definition_id IS DISTINCT FROM
           NEW.inventory_definition_id
        THEN
            RAISE EXCEPTION
                'Admin version belongs to another inventory definition';
        END IF;

        IF v_is_admin IS DISTINCT FROM true THEN
            RAISE EXCEPTION
                'Active admin version must be marked as an administrator correction';
        END IF;
    END IF;

    NEW.updated_at := now();

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_definition_authority_validate
BEFORE INSERT OR UPDATE
ON definition.definition_authority
FOR EACH ROW
EXECUTE FUNCTION definition.validate_authority();

\echo '[PASS] 1003_definition_function.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5703_system_definition.sql');
