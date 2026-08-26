/*
===============================================================================
 File:           5000_function/5700_system/5702_system_catalog.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Enforce catalog root/subtype consistency.
 Depends On:     Complete 0300_catalog domain
 Creates:        catalog.assert_item_kind()
                 catalog.validate_subtype_kind()
                 subtype validation triggers for all catalog subtype tables
 Key Rules:      Every subtype row must agree with catalog.items.item_kind.
                 A SET row cannot reference a PART root, etc.
                 Runtime checks protect subtype integrity before domain-wide
                 validation is run.
 Validation:     BEFORE INSERT/UPDATE triggers reject item-kind mismatches on all
                 fourteen catalog subtype tables.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5700_system/5702_system_catalog.sql', ARRAY['Complete 0300_catalog domain']::text[]);



CREATE FUNCTION catalog.assert_item_kind(
    p_catalog_item_id uuid,
    p_expected_kind catalog.item_kind
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_kind catalog.item_kind;
BEGIN
    SELECT item_kind
    INTO v_kind
    FROM catalog.items
    WHERE catalog_item_id = p_catalog_item_id;

    IF v_kind IS NULL THEN
        RAISE EXCEPTION
            'Catalog item "%" does not exist',
            p_catalog_item_id;
    END IF;

    IF v_kind <> p_expected_kind THEN
        RAISE EXCEPTION
            'Catalog item "%" is %, expected %',
            p_catalog_item_id,
            v_kind,
            p_expected_kind;
    END IF;
END;
$$;


CREATE FUNCTION catalog.validate_subtype_kind()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM catalog.assert_item_kind(
        NEW.catalog_item_id,
        TG_ARGV[0]::catalog.item_kind
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_catalog_sets_kind
BEFORE INSERT OR UPDATE
ON catalog.sets
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('SET');

CREATE TRIGGER trg_catalog_parts_kind
BEFORE INSERT OR UPDATE
ON catalog.parts
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('PART');

CREATE TRIGGER trg_catalog_minifigures_kind
BEFORE INSERT OR UPDATE
ON catalog.minifigures
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('MINIFIGURE');

CREATE TRIGGER trg_catalog_books_kind
BEFORE INSERT OR UPDATE
ON catalog.books
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('BOOK');

CREATE TRIGGER trg_catalog_mocs_kind
BEFORE INSERT OR UPDATE
ON catalog.mocs
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('MOC');

CREATE TRIGGER trg_catalog_sticker_sheets_kind
BEFORE INSERT OR UPDATE
ON catalog.sticker_sheets
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('STICKER_SHEET');

CREATE TRIGGER trg_catalog_instructions_kind
BEFORE INSERT OR UPDATE
ON catalog.instructions
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('INSTRUCTIONS');

CREATE TRIGGER trg_catalog_packaging_kind
BEFORE INSERT OR UPDATE
ON catalog.packaging
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('PACKAGING');

CREATE TRIGGER trg_catalog_gear_kind
BEFORE INSERT OR UPDATE
ON catalog.gear
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('GEAR');

CREATE TRIGGER trg_catalog_accessories_kind
BEFORE INSERT OR UPDATE
ON catalog.accessories
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('ACCESSORY');

CREATE TRIGGER trg_catalog_polybags_kind
BEFORE INSERT OR UPDATE
ON catalog.polybags
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('POLYBAG');

CREATE TRIGGER trg_catalog_promotional_items_kind
BEFORE INSERT OR UPDATE
ON catalog.promotional_items
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('PROMOTIONAL_ITEM');

CREATE TRIGGER trg_catalog_publications_kind
BEFORE INSERT OR UPDATE
ON catalog.publications
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('PUBLICATION');

CREATE TRIGGER trg_catalog_other_kind
BEFORE INSERT OR UPDATE
ON catalog.other_items
FOR EACH ROW
EXECUTE FUNCTION catalog.validate_subtype_kind('OTHER');

\echo '[PASS] 1002_catalog_function.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5702_system_catalog.sql');
