/*
===============================================================================
 File:           5000_function/5100_admin/5120_admin_definition_graph.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Enforce acyclic manifest-subassembly graphs.
 Depends On:     definition.manifest_subassemblies
 Creates:        definition.validate_manifest_subassembly_acyclic(...)
                 definition.trg_validate_manifest_subassembly_acyclic()
                 admin.clone_manifest_graph(...)
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5100_admin/5120_admin_definition_graph.sql', ARRAY['definition.manifest_subassemblies']::text[]);



CREATE OR REPLACE FUNCTION definition.validate_manifest_subassembly_acyclic(
    p_subassembly_id uuid,
    p_parent_id uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, definition
AS $$
DECLARE
    v_cycle boolean;
BEGIN
    IF p_parent_id IS NULL THEN RETURN; END IF;
    IF p_subassembly_id = p_parent_id THEN
        RAISE EXCEPTION 'Manifest subassembly cannot parent itself' USING ERRCODE='23514';
    END IF;

    WITH RECURSIVE ancestors(id) AS (
        SELECT p_parent_id
        UNION ALL
        SELECT s.parent_subassembly_id
        FROM definition.manifest_subassemblies s
        JOIN ancestors a ON s.manifest_subassembly_id = a.id
        WHERE s.parent_subassembly_id IS NOT NULL
    )
    SELECT EXISTS (SELECT 1 FROM ancestors WHERE id = p_subassembly_id) INTO v_cycle;

    IF v_cycle THEN
        RAISE EXCEPTION 'Manifest subassembly hierarchy cycle detected' USING ERRCODE='23514';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION definition.trg_validate_manifest_subassembly_acyclic()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, definition
AS $$
BEGIN
    PERFORM definition.validate_manifest_subassembly_acyclic(
        NEW.manifest_subassembly_id, NEW.parent_subassembly_id
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_manifest_subassembly_acyclic
BEFORE INSERT OR UPDATE OF parent_subassembly_id
ON definition.manifest_subassemblies
FOR EACH ROW EXECUTE FUNCTION definition.trg_validate_manifest_subassembly_acyclic();

CREATE OR REPLACE FUNCTION admin.clone_manifest_graph(
    p_from_inventory_version_id uuid,
    p_to_inventory_version_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, definition
AS $$
DECLARE
    v_inserted integer;
BEGIN
    IF p_from_inventory_version_id = p_to_inventory_version_id THEN
        RAISE EXCEPTION 'Source and destination inventory versions must differ'
            USING ERRCODE='22023';
    END IF;

    IF EXISTS (
        SELECT 1 FROM definition.manifest_subassemblies
        WHERE inventory_version_id = p_to_inventory_version_id
    ) THEN
        RAISE EXCEPTION 'Destination inventory version already has a manifest graph'
            USING ERRCODE='23505';
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS bt_manifest_clone_map (
        old_id uuid PRIMARY KEY,
        new_id uuid NOT NULL UNIQUE
    ) ON COMMIT DROP;
    TRUNCATE bt_manifest_clone_map;

    /* Insert roots first. */
    INSERT INTO definition.manifest_subassemblies(
        inventory_version_id, parent_subassembly_id, subassembly_key,
        display_name, position_index
    )
    SELECT p_to_inventory_version_id, NULL, s.subassembly_key,
           s.display_name, s.position_index
    FROM definition.manifest_subassemblies s
    WHERE s.inventory_version_id = p_from_inventory_version_id
      AND s.parent_subassembly_id IS NULL;

    INSERT INTO bt_manifest_clone_map(old_id, new_id)
    SELECT src.manifest_subassembly_id, dst.manifest_subassembly_id
    FROM definition.manifest_subassemblies src
    JOIN definition.manifest_subassemblies dst
      ON dst.inventory_version_id = p_to_inventory_version_id
     AND dst.subassembly_key = src.subassembly_key
    WHERE src.inventory_version_id = p_from_inventory_version_id;

    LOOP
        WITH candidates AS (
            SELECT src.*,
                   parent_map.new_id AS new_parent_id
            FROM definition.manifest_subassemblies src
            JOIN bt_manifest_clone_map parent_map
              ON parent_map.old_id = src.parent_subassembly_id
            LEFT JOIN bt_manifest_clone_map own_map
              ON own_map.old_id = src.manifest_subassembly_id
            WHERE src.inventory_version_id = p_from_inventory_version_id
              AND own_map.old_id IS NULL
        ),
        ins AS (
            INSERT INTO definition.manifest_subassemblies(
                inventory_version_id, parent_subassembly_id,
                subassembly_key, display_name, position_index
            )
            SELECT p_to_inventory_version_id, c.new_parent_id,
                   c.subassembly_key, c.display_name, c.position_index
            FROM candidates c
            RETURNING manifest_subassembly_id, subassembly_key
        )
        INSERT INTO bt_manifest_clone_map(old_id, new_id)
        SELECT src.manifest_subassembly_id, ins.manifest_subassembly_id
        FROM ins
        JOIN definition.manifest_subassemblies src
          ON src.inventory_version_id = p_from_inventory_version_id
         AND src.subassembly_key = ins.subassembly_key
        ON CONFLICT (old_id) DO NOTHING;

        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        EXIT WHEN v_inserted = 0;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM definition.manifest_subassemblies src
        LEFT JOIN bt_manifest_clone_map m
          ON m.old_id = src.manifest_subassembly_id
        WHERE src.inventory_version_id = p_from_inventory_version_id
          AND m.old_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Manifest graph clone could not resolve all nodes; source graph may be cyclic'
            USING ERRCODE='23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM definition.manifest_requirement_placements p
        JOIN definition.requirement_groups rg
          ON rg.requirement_group_id = p.requirement_group_id
        WHERE p.inventory_version_id = p_from_inventory_version_id
          AND rg.requirement_key IS NULL
    ) THEN
        RAISE EXCEPTION
            'Cannot clone placed requirement groups without requirement_key'
            USING ERRCODE='23514';
    END IF;

    INSERT INTO definition.manifest_requirement_placements(
        requirement_group_id,
        manifest_subassembly_id,
        inventory_version_id,
        position_index
    )
    SELECT dst_rg.requirement_group_id,
           map.new_id,
           p_to_inventory_version_id,
           p.position_index
    FROM definition.manifest_requirement_placements p
    JOIN definition.requirement_groups src_rg
      ON src_rg.requirement_group_id = p.requirement_group_id
    JOIN definition.requirement_groups dst_rg
      ON dst_rg.inventory_version_id = p_to_inventory_version_id
     AND dst_rg.requirement_key = src_rg.requirement_key
    JOIN bt_manifest_clone_map map
      ON map.old_id = p.manifest_subassembly_id
    WHERE p.inventory_version_id = p_from_inventory_version_id;
END;
$$;
SELECT pg_temp.bt_mark_completed('5000_function/5100_admin/5120_admin_definition_graph.sql');
