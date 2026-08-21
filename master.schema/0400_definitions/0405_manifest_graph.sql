/*
===============================================================================
 File:           0400_definitions/0405_manifest_graph.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Add hierarchical, version-scoped manifest subassemblies and
                 requirement placement without replacing requirement groups.
 Depends On:     definition.inventory_versions
                 definition.requirement_groups
 Creates:        definition.manifest_subassemblies
                 definition.manifest_requirement_placements
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0400_definitions/0405_manifest_graph.sql', ARRAY['definition.inventory_versions', 'definition.requirement_groups']::text[]);




ALTER TABLE definition.requirement_groups
    ADD COLUMN requirement_key text,
    ADD CONSTRAINT ck_requirement_groups_key
        CHECK (requirement_key IS NULL OR btrim(requirement_key) <> '');

CREATE UNIQUE INDEX uq_requirement_groups_version_key
    ON definition.requirement_groups(inventory_version_id, requirement_key)
    WHERE requirement_key IS NOT NULL;

CREATE TABLE definition.manifest_subassemblies (
    manifest_subassembly_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    inventory_version_id uuid NOT NULL
        REFERENCES definition.inventory_versions(inventory_version_id) ON DELETE CASCADE,
    parent_subassembly_id uuid,
    subassembly_key text NOT NULL,
    display_name text NOT NULL,
    position_index integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_manifest_subassembly_key CHECK (btrim(subassembly_key) <> ''),
    CONSTRAINT ck_manifest_subassembly_name CHECK (btrim(display_name) <> ''),
    CONSTRAINT ck_manifest_subassembly_position CHECK (position_index >= 0),
    CONSTRAINT ck_manifest_subassembly_self CHECK (parent_subassembly_id IS NULL OR parent_subassembly_id <> manifest_subassembly_id),
    CONSTRAINT uq_manifest_subassembly_key UNIQUE (inventory_version_id, subassembly_key),
    CONSTRAINT uq_manifest_subassembly_scope UNIQUE (manifest_subassembly_id, inventory_version_id),
    CONSTRAINT fk_manifest_subassembly_parent_scope
        FOREIGN KEY (parent_subassembly_id, inventory_version_id)
        REFERENCES definition.manifest_subassemblies(manifest_subassembly_id, inventory_version_id)
        DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX ix_manifest_subassemblies_parent
    ON definition.manifest_subassemblies(parent_subassembly_id)
    WHERE parent_subassembly_id IS NOT NULL;

CREATE TABLE definition.manifest_requirement_placements (
    requirement_group_id bigint PRIMARY KEY
        REFERENCES definition.requirement_groups(requirement_group_id) ON DELETE CASCADE,
    manifest_subassembly_id uuid NOT NULL,
    inventory_version_id uuid NOT NULL,
    position_index integer NOT NULL DEFAULT 0,
    CONSTRAINT fk_manifest_requirement_placement_subassembly
        FOREIGN KEY (manifest_subassembly_id, inventory_version_id)
        REFERENCES definition.manifest_subassemblies(manifest_subassembly_id, inventory_version_id)
        ON DELETE CASCADE,
    CONSTRAINT ck_manifest_requirement_placement_position CHECK (position_index >= 0)
);

CREATE OR REPLACE FUNCTION definition.trg_validate_manifest_requirement_scope()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, definition
AS $$
DECLARE
    v_version uuid;
BEGIN
    SELECT inventory_version_id INTO v_version
    FROM definition.requirement_groups
    WHERE requirement_group_id = NEW.requirement_group_id;

    IF v_version IS DISTINCT FROM NEW.inventory_version_id THEN
        RAISE EXCEPTION 'Requirement group % does not belong to inventory version %',
            NEW.requirement_group_id, NEW.inventory_version_id
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_manifest_requirement_scope
BEFORE INSERT OR UPDATE
ON definition.manifest_requirement_placements
FOR EACH ROW EXECUTE FUNCTION definition.trg_validate_manifest_requirement_scope();
SELECT pg_temp.bt_mark_completed('0400_definitions/0405_manifest_graph.sql');
