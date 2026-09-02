/*
===============================================================================
 File:           1000_reporting/1010_reporting_system_summary.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Maintain a singleton cached system summary incrementally.
 Depends On:     catalog.items
                 import.source_runs
                 reference.external_sources
                 1100_security/1110_api_surface_lockdown.sql
 Key Rules:      Catalog counters update once per canonical DML statement using
                 PostgreSQL transition tables, not once per row.
                 Rebrickable source-run state updates transactionally.
                 Normal screen loads perform no COUNT(*) aggregation.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1000_reporting/1010_reporting_system_summary.sql', ARRAY['catalog.items', 'import.source_runs', 'reference.external_sources', '1100_security/1110_api_surface_lockdown.sql']::text[]);

CREATE TABLE reporting.system_summary (
    summary_id smallint NOT NULL DEFAULT 1,

    total_catalog_items bigint NOT NULL DEFAULT 0,

    active_catalog_items bigint NOT NULL DEFAULT 0,
    retired_catalog_items bigint NOT NULL DEFAULT 0,
    source_missing_catalog_items bigint NOT NULL DEFAULT 0,
    unresolved_custom_catalog_items bigint NOT NULL DEFAULT 0,
    archived_catalog_items bigint NOT NULL DEFAULT 0,

    total_sets bigint NOT NULL DEFAULT 0,
    total_parts bigint NOT NULL DEFAULT 0,
    total_minifigures bigint NOT NULL DEFAULT 0,
    total_books bigint NOT NULL DEFAULT 0,
    total_mocs bigint NOT NULL DEFAULT 0,
    total_sticker_sheets bigint NOT NULL DEFAULT 0,
    total_instructions bigint NOT NULL DEFAULT 0,
    total_packaging bigint NOT NULL DEFAULT 0,
    total_gear bigint NOT NULL DEFAULT 0,
    total_accessories bigint NOT NULL DEFAULT 0,
    total_polybags bigint NOT NULL DEFAULT 0,
    total_promotional_items bigint NOT NULL DEFAULT 0,
    total_publications bigint NOT NULL DEFAULT 0,
    total_other_items bigint NOT NULL DEFAULT 0,

    latest_rebrickable_run_id uuid,
    latest_rebrickable_status import.source_run_status,
    latest_rebrickable_started_at timestamptz,
    latest_rebrickable_completed_at timestamptz,
    latest_rebrickable_failed_at timestamptz,

    catalog_changed_at timestamptz,
    last_reconciled_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT pk_reporting_system_summary
        PRIMARY KEY (summary_id),

    CONSTRAINT ck_reporting_system_summary_singleton
        CHECK (summary_id = 1),

    CONSTRAINT ck_reporting_system_summary_nonnegative
        CHECK (
            total_catalog_items >= 0
            AND active_catalog_items >= 0
            AND retired_catalog_items >= 0
            AND source_missing_catalog_items >= 0
            AND unresolved_custom_catalog_items >= 0
            AND archived_catalog_items >= 0
            AND total_sets >= 0
            AND total_parts >= 0
            AND total_minifigures >= 0
            AND total_books >= 0
            AND total_mocs >= 0
            AND total_sticker_sheets >= 0
            AND total_instructions >= 0
            AND total_packaging >= 0
            AND total_gear >= 0
            AND total_accessories >= 0
            AND total_polybags >= 0
            AND total_promotional_items >= 0
            AND total_publications >= 0
            AND total_other_items >= 0
        )
);

INSERT INTO reporting.system_summary(summary_id)
VALUES (1);


/* -------------------------------------------------------------------------- */
/* Execute-only cached read surface                                           */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION reporting.get_system_summary()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
    SELECT to_jsonb(s)
    FROM reporting.system_summary s
    WHERE s.summary_id = 1
$function$;


/* -------------------------------------------------------------------------- */
/* Statement-level catalog summary maintenance                                */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION reporting.trg_system_summary_catalog_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    WITH d AS (
        SELECT
            count(*)::bigint AS total_catalog_items,

            count(*) FILTER (WHERE status = 'ACTIVE')::bigint AS active_catalog_items,
            count(*) FILTER (WHERE status = 'RETIRED')::bigint AS retired_catalog_items,
            count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint AS source_missing_catalog_items,
            count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_catalog_items,
            count(*) FILTER (WHERE status = 'ARCHIVED')::bigint AS archived_catalog_items,

            count(*) FILTER (WHERE item_kind = 'SET')::bigint AS total_sets,
            count(*) FILTER (WHERE item_kind = 'PART')::bigint AS total_parts,
            count(*) FILTER (WHERE item_kind = 'MINIFIGURE')::bigint AS total_minifigures,
            count(*) FILTER (WHERE item_kind = 'BOOK')::bigint AS total_books,
            count(*) FILTER (WHERE item_kind = 'MOC')::bigint AS total_mocs,
            count(*) FILTER (WHERE item_kind = 'STICKER_SHEET')::bigint AS total_sticker_sheets,
            count(*) FILTER (WHERE item_kind = 'INSTRUCTIONS')::bigint AS total_instructions,
            count(*) FILTER (WHERE item_kind = 'PACKAGING')::bigint AS total_packaging,
            count(*) FILTER (WHERE item_kind = 'GEAR')::bigint AS total_gear,
            count(*) FILTER (WHERE item_kind = 'ACCESSORY')::bigint AS total_accessories,
            count(*) FILTER (WHERE item_kind = 'POLYBAG')::bigint AS total_polybags,
            count(*) FILTER (WHERE item_kind = 'PROMOTIONAL_ITEM')::bigint AS total_promotional_items,
            count(*) FILTER (WHERE item_kind = 'PUBLICATION')::bigint AS total_publications,
            count(*) FILTER (WHERE item_kind = 'OTHER')::bigint AS total_other_items
        FROM new_catalog_rows
    )
    UPDATE reporting.system_summary s
       SET total_catalog_items = s.total_catalog_items + d.total_catalog_items,

           active_catalog_items = s.active_catalog_items + d.active_catalog_items,
           retired_catalog_items = s.retired_catalog_items + d.retired_catalog_items,
           source_missing_catalog_items = s.source_missing_catalog_items + d.source_missing_catalog_items,
           unresolved_custom_catalog_items = s.unresolved_custom_catalog_items + d.unresolved_custom_catalog_items,
           archived_catalog_items = s.archived_catalog_items + d.archived_catalog_items,

           total_sets = s.total_sets + d.total_sets,
           total_parts = s.total_parts + d.total_parts,
           total_minifigures = s.total_minifigures + d.total_minifigures,
           total_books = s.total_books + d.total_books,
           total_mocs = s.total_mocs + d.total_mocs,
           total_sticker_sheets = s.total_sticker_sheets + d.total_sticker_sheets,
           total_instructions = s.total_instructions + d.total_instructions,
           total_packaging = s.total_packaging + d.total_packaging,
           total_gear = s.total_gear + d.total_gear,
           total_accessories = s.total_accessories + d.total_accessories,
           total_polybags = s.total_polybags + d.total_polybags,
           total_promotional_items = s.total_promotional_items + d.total_promotional_items,
           total_publications = s.total_publications + d.total_publications,
           total_other_items = s.total_other_items + d.total_other_items,

           catalog_changed_at = clock_timestamp(),
           updated_at = clock_timestamp()
      FROM d
     WHERE s.summary_id = 1;

    RETURN NULL;
END;
$function$;


CREATE OR REPLACE FUNCTION reporting.trg_system_summary_catalog_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    WITH d AS (
        SELECT
            count(*)::bigint AS total_catalog_items,

            count(*) FILTER (WHERE status = 'ACTIVE')::bigint AS active_catalog_items,
            count(*) FILTER (WHERE status = 'RETIRED')::bigint AS retired_catalog_items,
            count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint AS source_missing_catalog_items,
            count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_catalog_items,
            count(*) FILTER (WHERE status = 'ARCHIVED')::bigint AS archived_catalog_items,

            count(*) FILTER (WHERE item_kind = 'SET')::bigint AS total_sets,
            count(*) FILTER (WHERE item_kind = 'PART')::bigint AS total_parts,
            count(*) FILTER (WHERE item_kind = 'MINIFIGURE')::bigint AS total_minifigures,
            count(*) FILTER (WHERE item_kind = 'BOOK')::bigint AS total_books,
            count(*) FILTER (WHERE item_kind = 'MOC')::bigint AS total_mocs,
            count(*) FILTER (WHERE item_kind = 'STICKER_SHEET')::bigint AS total_sticker_sheets,
            count(*) FILTER (WHERE item_kind = 'INSTRUCTIONS')::bigint AS total_instructions,
            count(*) FILTER (WHERE item_kind = 'PACKAGING')::bigint AS total_packaging,
            count(*) FILTER (WHERE item_kind = 'GEAR')::bigint AS total_gear,
            count(*) FILTER (WHERE item_kind = 'ACCESSORY')::bigint AS total_accessories,
            count(*) FILTER (WHERE item_kind = 'POLYBAG')::bigint AS total_polybags,
            count(*) FILTER (WHERE item_kind = 'PROMOTIONAL_ITEM')::bigint AS total_promotional_items,
            count(*) FILTER (WHERE item_kind = 'PUBLICATION')::bigint AS total_publications,
            count(*) FILTER (WHERE item_kind = 'OTHER')::bigint AS total_other_items
        FROM old_catalog_rows
    )
    UPDATE reporting.system_summary s
       SET total_catalog_items = s.total_catalog_items - d.total_catalog_items,

           active_catalog_items = s.active_catalog_items - d.active_catalog_items,
           retired_catalog_items = s.retired_catalog_items - d.retired_catalog_items,
           source_missing_catalog_items = s.source_missing_catalog_items - d.source_missing_catalog_items,
           unresolved_custom_catalog_items = s.unresolved_custom_catalog_items - d.unresolved_custom_catalog_items,
           archived_catalog_items = s.archived_catalog_items - d.archived_catalog_items,

           total_sets = s.total_sets - d.total_sets,
           total_parts = s.total_parts - d.total_parts,
           total_minifigures = s.total_minifigures - d.total_minifigures,
           total_books = s.total_books - d.total_books,
           total_mocs = s.total_mocs - d.total_mocs,
           total_sticker_sheets = s.total_sticker_sheets - d.total_sticker_sheets,
           total_instructions = s.total_instructions - d.total_instructions,
           total_packaging = s.total_packaging - d.total_packaging,
           total_gear = s.total_gear - d.total_gear,
           total_accessories = s.total_accessories - d.total_accessories,
           total_polybags = s.total_polybags - d.total_polybags,
           total_promotional_items = s.total_promotional_items - d.total_promotional_items,
           total_publications = s.total_publications - d.total_publications,
           total_other_items = s.total_other_items - d.total_other_items,

           catalog_changed_at = clock_timestamp(),
           updated_at = clock_timestamp()
      FROM d
     WHERE s.summary_id = 1;

    RETURN NULL;
END;
$function$;


CREATE OR REPLACE FUNCTION reporting.trg_system_summary_catalog_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM old_catalog_rows o
        JOIN new_catalog_rows n USING (catalog_item_id)
        WHERE o.item_kind IS DISTINCT FROM n.item_kind
           OR o.status IS DISTINCT FROM n.status
    ) THEN
        RETURN NULL;
    END IF;

    WITH old_d AS (
        SELECT
            count(*) FILTER (WHERE status = 'ACTIVE')::bigint AS active_catalog_items,
            count(*) FILTER (WHERE status = 'RETIRED')::bigint AS retired_catalog_items,
            count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint AS source_missing_catalog_items,
            count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_catalog_items,
            count(*) FILTER (WHERE status = 'ARCHIVED')::bigint AS archived_catalog_items,

            count(*) FILTER (WHERE item_kind = 'SET')::bigint AS total_sets,
            count(*) FILTER (WHERE item_kind = 'PART')::bigint AS total_parts,
            count(*) FILTER (WHERE item_kind = 'MINIFIGURE')::bigint AS total_minifigures,
            count(*) FILTER (WHERE item_kind = 'BOOK')::bigint AS total_books,
            count(*) FILTER (WHERE item_kind = 'MOC')::bigint AS total_mocs,
            count(*) FILTER (WHERE item_kind = 'STICKER_SHEET')::bigint AS total_sticker_sheets,
            count(*) FILTER (WHERE item_kind = 'INSTRUCTIONS')::bigint AS total_instructions,
            count(*) FILTER (WHERE item_kind = 'PACKAGING')::bigint AS total_packaging,
            count(*) FILTER (WHERE item_kind = 'GEAR')::bigint AS total_gear,
            count(*) FILTER (WHERE item_kind = 'ACCESSORY')::bigint AS total_accessories,
            count(*) FILTER (WHERE item_kind = 'POLYBAG')::bigint AS total_polybags,
            count(*) FILTER (WHERE item_kind = 'PROMOTIONAL_ITEM')::bigint AS total_promotional_items,
            count(*) FILTER (WHERE item_kind = 'PUBLICATION')::bigint AS total_publications,
            count(*) FILTER (WHERE item_kind = 'OTHER')::bigint AS total_other_items
        FROM old_catalog_rows
    ),
    new_d AS (
        SELECT
            count(*) FILTER (WHERE status = 'ACTIVE')::bigint AS active_catalog_items,
            count(*) FILTER (WHERE status = 'RETIRED')::bigint AS retired_catalog_items,
            count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint AS source_missing_catalog_items,
            count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_catalog_items,
            count(*) FILTER (WHERE status = 'ARCHIVED')::bigint AS archived_catalog_items,

            count(*) FILTER (WHERE item_kind = 'SET')::bigint AS total_sets,
            count(*) FILTER (WHERE item_kind = 'PART')::bigint AS total_parts,
            count(*) FILTER (WHERE item_kind = 'MINIFIGURE')::bigint AS total_minifigures,
            count(*) FILTER (WHERE item_kind = 'BOOK')::bigint AS total_books,
            count(*) FILTER (WHERE item_kind = 'MOC')::bigint AS total_mocs,
            count(*) FILTER (WHERE item_kind = 'STICKER_SHEET')::bigint AS total_sticker_sheets,
            count(*) FILTER (WHERE item_kind = 'INSTRUCTIONS')::bigint AS total_instructions,
            count(*) FILTER (WHERE item_kind = 'PACKAGING')::bigint AS total_packaging,
            count(*) FILTER (WHERE item_kind = 'GEAR')::bigint AS total_gear,
            count(*) FILTER (WHERE item_kind = 'ACCESSORY')::bigint AS total_accessories,
            count(*) FILTER (WHERE item_kind = 'POLYBAG')::bigint AS total_polybags,
            count(*) FILTER (WHERE item_kind = 'PROMOTIONAL_ITEM')::bigint AS total_promotional_items,
            count(*) FILTER (WHERE item_kind = 'PUBLICATION')::bigint AS total_publications,
            count(*) FILTER (WHERE item_kind = 'OTHER')::bigint AS total_other_items
        FROM new_catalog_rows
    )
    UPDATE reporting.system_summary s
       SET active_catalog_items = s.active_catalog_items + n.active_catalog_items - o.active_catalog_items,
           retired_catalog_items = s.retired_catalog_items + n.retired_catalog_items - o.retired_catalog_items,
           source_missing_catalog_items = s.source_missing_catalog_items + n.source_missing_catalog_items - o.source_missing_catalog_items,
           unresolved_custom_catalog_items = s.unresolved_custom_catalog_items + n.unresolved_custom_catalog_items - o.unresolved_custom_catalog_items,
           archived_catalog_items = s.archived_catalog_items + n.archived_catalog_items - o.archived_catalog_items,

           total_sets = s.total_sets + n.total_sets - o.total_sets,
           total_parts = s.total_parts + n.total_parts - o.total_parts,
           total_minifigures = s.total_minifigures + n.total_minifigures - o.total_minifigures,
           total_books = s.total_books + n.total_books - o.total_books,
           total_mocs = s.total_mocs + n.total_mocs - o.total_mocs,
           total_sticker_sheets = s.total_sticker_sheets + n.total_sticker_sheets - o.total_sticker_sheets,
           total_instructions = s.total_instructions + n.total_instructions - o.total_instructions,
           total_packaging = s.total_packaging + n.total_packaging - o.total_packaging,
           total_gear = s.total_gear + n.total_gear - o.total_gear,
           total_accessories = s.total_accessories + n.total_accessories - o.total_accessories,
           total_polybags = s.total_polybags + n.total_polybags - o.total_polybags,
           total_promotional_items = s.total_promotional_items + n.total_promotional_items - o.total_promotional_items,
           total_publications = s.total_publications + n.total_publications - o.total_publications,
           total_other_items = s.total_other_items + n.total_other_items - o.total_other_items,

           catalog_changed_at = clock_timestamp(),
           updated_at = clock_timestamp()
      FROM old_d o
      CROSS JOIN new_d n
     WHERE s.summary_id = 1;

    RETURN NULL;
END;
$function$;


CREATE TRIGGER trg_catalog_items_system_summary_insert
AFTER INSERT ON catalog.items
REFERENCING NEW TABLE AS new_catalog_rows
FOR EACH STATEMENT
EXECUTE FUNCTION reporting.trg_system_summary_catalog_insert();

CREATE TRIGGER trg_catalog_items_system_summary_update
AFTER UPDATE ON catalog.items
REFERENCING OLD TABLE AS old_catalog_rows NEW TABLE AS new_catalog_rows
FOR EACH STATEMENT
EXECUTE FUNCTION reporting.trg_system_summary_catalog_update();

CREATE TRIGGER trg_catalog_items_system_summary_delete
AFTER DELETE ON catalog.items
REFERENCING OLD TABLE AS old_catalog_rows
FOR EACH STATEMENT
EXECUTE FUNCTION reporting.trg_system_summary_catalog_delete();


/* -------------------------------------------------------------------------- */
/* Rebrickable source-run lifecycle                                           */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION reporting.trg_system_summary_rebrickable_run()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM reference.external_sources s
         WHERE s.source_id = NEW.source_id
           AND s.source_code = 'REBRICKABLE'
    ) THEN
        RETURN NEW;
    END IF;

    UPDATE reporting.system_summary
       SET latest_rebrickable_run_id = NEW.source_run_id,
           latest_rebrickable_status = NEW.status,
           latest_rebrickable_started_at = NEW.started_at,
           latest_rebrickable_completed_at = NEW.completed_at,
           latest_rebrickable_failed_at = NEW.failed_at,
           updated_at = clock_timestamp()
     WHERE summary_id = 1
       AND (
           latest_rebrickable_started_at IS NULL
           OR NEW.started_at >= latest_rebrickable_started_at
       );

    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_source_runs_system_summary
AFTER INSERT OR UPDATE OF status, completed_at, failed_at
ON import.source_runs
FOR EACH ROW
EXECUTE FUNCTION reporting.trg_system_summary_rebrickable_run();


/* -------------------------------------------------------------------------- */
/* One-time/bootstrap/drift repair                                            */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION reporting.rebuild_system_summary()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_run record;
BEGIN
    UPDATE reporting.system_summary s
       SET total_catalog_items = x.total_catalog_items,

           active_catalog_items = x.active_catalog_items,
           retired_catalog_items = x.retired_catalog_items,
           source_missing_catalog_items = x.source_missing_catalog_items,
           unresolved_custom_catalog_items = x.unresolved_custom_catalog_items,
           archived_catalog_items = x.archived_catalog_items,

           total_sets = x.total_sets,
           total_parts = x.total_parts,
           total_minifigures = x.total_minifigures,
           total_books = x.total_books,
           total_mocs = x.total_mocs,
           total_sticker_sheets = x.total_sticker_sheets,
           total_instructions = x.total_instructions,
           total_packaging = x.total_packaging,
           total_gear = x.total_gear,
           total_accessories = x.total_accessories,
           total_polybags = x.total_polybags,
           total_promotional_items = x.total_promotional_items,
           total_publications = x.total_publications,
           total_other_items = x.total_other_items,

           catalog_changed_at = clock_timestamp(),
           last_reconciled_at = clock_timestamp(),
           updated_at = clock_timestamp()
      FROM (
          SELECT
              count(*)::bigint AS total_catalog_items,

              count(*) FILTER (WHERE status = 'ACTIVE')::bigint AS active_catalog_items,
              count(*) FILTER (WHERE status = 'RETIRED')::bigint AS retired_catalog_items,
              count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint AS source_missing_catalog_items,
              count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_catalog_items,
              count(*) FILTER (WHERE status = 'ARCHIVED')::bigint AS archived_catalog_items,

              count(*) FILTER (WHERE item_kind = 'SET')::bigint AS total_sets,
              count(*) FILTER (WHERE item_kind = 'PART')::bigint AS total_parts,
              count(*) FILTER (WHERE item_kind = 'MINIFIGURE')::bigint AS total_minifigures,
              count(*) FILTER (WHERE item_kind = 'BOOK')::bigint AS total_books,
              count(*) FILTER (WHERE item_kind = 'MOC')::bigint AS total_mocs,
              count(*) FILTER (WHERE item_kind = 'STICKER_SHEET')::bigint AS total_sticker_sheets,
              count(*) FILTER (WHERE item_kind = 'INSTRUCTIONS')::bigint AS total_instructions,
              count(*) FILTER (WHERE item_kind = 'PACKAGING')::bigint AS total_packaging,
              count(*) FILTER (WHERE item_kind = 'GEAR')::bigint AS total_gear,
              count(*) FILTER (WHERE item_kind = 'ACCESSORY')::bigint AS total_accessories,
              count(*) FILTER (WHERE item_kind = 'POLYBAG')::bigint AS total_polybags,
              count(*) FILTER (WHERE item_kind = 'PROMOTIONAL_ITEM')::bigint AS total_promotional_items,
              count(*) FILTER (WHERE item_kind = 'PUBLICATION')::bigint AS total_publications,
              count(*) FILTER (WHERE item_kind = 'OTHER')::bigint AS total_other_items
          FROM catalog.items
      ) x
     WHERE s.summary_id = 1;

    SELECT r.source_run_id, r.status, r.started_at, r.completed_at, r.failed_at
      INTO v_run
      FROM import.source_runs r
      JOIN reference.external_sources es
        ON es.source_id = r.source_id
     WHERE es.source_code = 'REBRICKABLE'
     ORDER BY r.started_at DESC
     LIMIT 1;

    IF FOUND THEN
        UPDATE reporting.system_summary
           SET latest_rebrickable_run_id = v_run.source_run_id,
               latest_rebrickable_status = v_run.status,
               latest_rebrickable_started_at = v_run.started_at,
               latest_rebrickable_completed_at = v_run.completed_at,
               latest_rebrickable_failed_at = v_run.failed_at,
               updated_at = clock_timestamp()
         WHERE summary_id = 1;
    END IF;

    RETURN reporting.get_system_summary();
END;
$function$;


/* -------------------------------------------------------------------------- */
/* Security                                                                   */
/* -------------------------------------------------------------------------- */

REVOKE ALL ON TABLE reporting.system_summary FROM PUBLIC;

REVOKE ALL ON FUNCTION reporting.trg_system_summary_catalog_insert() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_system_summary_catalog_update() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_system_summary_catalog_delete() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_system_summary_rebrickable_run() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.rebuild_system_summary() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.get_system_summary() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION reporting.get_system_summary()
TO brktrkr_api, brktrkr_reporting, brktrkr_import;

/*
 * Existing database installation requires one initial snapshot. Future
 * canonical changes are maintained incrementally by the triggers above.
 */
SELECT reporting.rebuild_system_summary();

SELECT pg_temp.bt_mark_completed('1000_reporting/1010_reporting_system_summary.sql');
\echo '[PASS] 1010_reporting_system_summary.sql'
