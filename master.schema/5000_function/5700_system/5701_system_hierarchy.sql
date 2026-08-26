/*
===============================================================================
 File:           5000_function/5700_system/5701_system_hierarchy.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Prevent recursive cycles in all modeled hierarchy trees.
 Depends On:     reference.themes
                 reference.categories
                 collection.storage_locations
                 moc.subassemblies
 Creates:        reference.validate_theme_cycle()
                 reference.validate_category_cycle()
                 collection.validate_storage_cycle()
                 moc.validate_subassembly_cycle()
                 associated BEFORE triggers
 Key Rules:      Hierarchical records may never become descendants of themselves.
                 Storage parent/child rows must remain owner-consistent.
                 MOC parent/child subassemblies must remain revision-consistent.
 Validation:     Runtime recursive CTE checks reject cycle-producing changes;
                 function validation confirms trigger installation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5700_system/5701_system_hierarchy.sql', ARRAY['reference.themes', 'reference.categories', 'collection.storage_locations', 'moc.subassemblies']::text[]);



CREATE FUNCTION reference.validate_theme_cycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.parent_theme_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        WITH RECURSIVE ancestry AS (
            SELECT
                theme_id,
                parent_theme_id
            FROM reference.themes
            WHERE theme_id = NEW.parent_theme_id

            UNION ALL

            SELECT
                t.theme_id,
                t.parent_theme_id
            FROM reference.themes t
            JOIN ancestry a
              ON t.theme_id = a.parent_theme_id
        )
        SELECT 1
        FROM ancestry
        WHERE theme_id = NEW.theme_id
    ) THEN
        RAISE EXCEPTION
            'Theme hierarchy cycle detected';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_theme_cycle
BEFORE INSERT OR UPDATE OF parent_theme_id
ON reference.themes
FOR EACH ROW
EXECUTE FUNCTION reference.validate_theme_cycle();


CREATE FUNCTION reference.validate_category_cycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.parent_category_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        WITH RECURSIVE ancestry AS (
            SELECT
                category_id,
                parent_category_id
            FROM reference.categories
            WHERE category_id = NEW.parent_category_id

            UNION ALL

            SELECT
                c.category_id,
                c.parent_category_id
            FROM reference.categories c
            JOIN ancestry a
              ON c.category_id = a.parent_category_id
        )
        SELECT 1
        FROM ancestry
        WHERE category_id = NEW.category_id
    ) THEN
        RAISE EXCEPTION
            'Category hierarchy cycle detected';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_category_cycle
BEFORE INSERT OR UPDATE OF parent_category_id
ON reference.categories
FOR EACH ROW
EXECUTE FUNCTION reference.validate_category_cycle();


CREATE FUNCTION collection.validate_storage_cycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_parent_owner uuid;
BEGIN
    IF NEW.parent_storage_location_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT owner_id
    INTO v_parent_owner
    FROM collection.storage_locations
    WHERE storage_location_id =
          NEW.parent_storage_location_id;

    IF v_parent_owner IS DISTINCT FROM NEW.owner_id THEN
        RAISE EXCEPTION
            'Storage parent and child must belong to the same owner';
    END IF;

    IF EXISTS (
        WITH RECURSIVE ancestry AS (
            SELECT
                storage_location_id,
                parent_storage_location_id
            FROM collection.storage_locations
            WHERE storage_location_id =
                  NEW.parent_storage_location_id

            UNION ALL

            SELECT
                s.storage_location_id,
                s.parent_storage_location_id
            FROM collection.storage_locations s
            JOIN ancestry a
              ON s.storage_location_id =
                 a.parent_storage_location_id
        )
        SELECT 1
        FROM ancestry
        WHERE storage_location_id =
              NEW.storage_location_id
    ) THEN
        RAISE EXCEPTION
            'Storage hierarchy cycle detected';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_storage_cycle
BEFORE INSERT OR UPDATE OF
    parent_storage_location_id,
    owner_id
ON collection.storage_locations
FOR EACH ROW
EXECUTE FUNCTION collection.validate_storage_cycle();


CREATE FUNCTION moc.validate_subassembly_cycle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_parent_revision uuid;
BEGIN
    IF NEW.parent_subassembly_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT moc_revision_id
    INTO v_parent_revision
    FROM moc.subassemblies
    WHERE subassembly_id =
          NEW.parent_subassembly_id;

    IF v_parent_revision IS DISTINCT FROM
       NEW.moc_revision_id
    THEN
        RAISE EXCEPTION
            'Parent and child subassemblies must belong to the same MOC revision';
    END IF;

    IF EXISTS (
        WITH RECURSIVE ancestry AS (
            SELECT
                subassembly_id,
                parent_subassembly_id
            FROM moc.subassemblies
            WHERE subassembly_id =
                  NEW.parent_subassembly_id

            UNION ALL

            SELECT
                s.subassembly_id,
                s.parent_subassembly_id
            FROM moc.subassemblies s
            JOIN ancestry a
              ON s.subassembly_id =
                 a.parent_subassembly_id
        )
        SELECT 1
        FROM ancestry
        WHERE subassembly_id =
              NEW.subassembly_id
    ) THEN
        RAISE EXCEPTION
            'MOC subassembly hierarchy cycle detected';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_subassembly_cycle
BEFORE INSERT OR UPDATE OF
    parent_subassembly_id,
    moc_revision_id
ON moc.subassemblies
FOR EACH ROW
EXECUTE FUNCTION moc.validate_subassembly_cycle();

\echo '[PASS] 1001_hierarchy_function.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5701_system_hierarchy.sql');
