/*
===============================================================================
 File:           1000_reporting/1011_reporting_aggregate_tables.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Create and maintain BrickTrackr aggregate/cache tables used by
                 fast application screens and import monitoring.
 Depends On:     1000_reporting/1010_reporting_system_summary.sql
                 catalog.items
                 identity.owners
                 collection.entries
                 collection.instances
                 wanted.wishlists
                 wanted.wishlist_entries
                 wanted.build_goals
                 import.source_runs
                 import.source_run_steps
                 reference.external_sources
 Creates:        reporting.import_summary
                 import.catalog_summary_delta
                 reporting.catalog_kind_summary
                 reporting.owner_summary
 Key Rules:      Greenfield creates every aggregate table before ownership
                 separation. Catalog/import aggregates update transactionally.
                 Owner summaries refresh immediately for only the affected owner.
                 Runtime roles receive execute-only read access, not table DML.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1000_reporting/1011_reporting_aggregate_tables.sql', ARRAY['1000_reporting/1010_reporting_system_summary.sql', 'catalog.items', 'identity.owners', 'collection.entries', 'collection.instances', 'wanted.wishlists', 'wanted.wishlist_entries', 'wanted.build_goals', 'import.source_runs', 'import.source_run_steps', 'reference.external_sources']::text[]);


/* -------------------------------------------------------------------------- */
/* Per-import working deltas                                                  */
/* -------------------------------------------------------------------------- */

CREATE TABLE import.catalog_summary_delta (
    source_run_id uuid NOT NULL,

    catalog_items_inserted bigint NOT NULL DEFAULT 0,
    catalog_items_updated bigint NOT NULL DEFAULT 0,
    catalog_items_retired bigint NOT NULL DEFAULT 0,
    catalog_items_restored bigint NOT NULL DEFAULT 0,
    source_missing_added bigint NOT NULL DEFAULT 0,

    sets_inserted bigint NOT NULL DEFAULT 0,
    parts_inserted bigint NOT NULL DEFAULT 0,
    minifigures_inserted bigint NOT NULL DEFAULT 0,
    instructions_inserted bigint NOT NULL DEFAULT 0,
    mocs_inserted bigint NOT NULL DEFAULT 0,
    other_items_inserted bigint NOT NULL DEFAULT 0,

    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT pk_import_catalog_summary_delta
        PRIMARY KEY (source_run_id),

    CONSTRAINT fk_import_catalog_summary_delta_run
        FOREIGN KEY (source_run_id)
        REFERENCES import.source_runs(source_run_id),

    CONSTRAINT ck_import_catalog_summary_delta_nonnegative
        CHECK (
            catalog_items_inserted >= 0
            AND catalog_items_updated >= 0
            AND catalog_items_retired >= 0
            AND catalog_items_restored >= 0
            AND source_missing_added >= 0
            AND sets_inserted >= 0
            AND parts_inserted >= 0
            AND minifigures_inserted >= 0
            AND instructions_inserted >= 0
            AND mocs_inserted >= 0
            AND other_items_inserted >= 0
        )
);


/* -------------------------------------------------------------------------- */
/* Per-source-run reporting summary                                           */
/* -------------------------------------------------------------------------- */

CREATE TABLE reporting.import_summary (
    source_run_id uuid NOT NULL,
    source_id smallint NOT NULL,
    source_code text NOT NULL,

    status import.source_run_status NOT NULL,
    started_at timestamptz NOT NULL,
    completed_at timestamptz,
    failed_at timestamptz,

    catalog_items_inserted bigint NOT NULL DEFAULT 0,
    catalog_items_updated bigint NOT NULL DEFAULT 0,
    catalog_items_retired bigint NOT NULL DEFAULT 0,
    catalog_items_restored bigint NOT NULL DEFAULT 0,
    source_missing_added bigint NOT NULL DEFAULT 0,

    sets_inserted bigint NOT NULL DEFAULT 0,
    parts_inserted bigint NOT NULL DEFAULT 0,
    minifigures_inserted bigint NOT NULL DEFAULT 0,
    instructions_inserted bigint NOT NULL DEFAULT 0,
    mocs_inserted bigint NOT NULL DEFAULT 0,
    other_items_inserted bigint NOT NULL DEFAULT 0,

    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT pk_reporting_import_summary
        PRIMARY KEY (source_run_id),

    CONSTRAINT fk_reporting_import_summary_run
        FOREIGN KEY (source_run_id)
        REFERENCES import.source_runs(source_run_id),

    CONSTRAINT fk_reporting_import_summary_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT ck_reporting_import_summary_source_code
        CHECK (btrim(source_code) <> '')
);

CREATE INDEX ix_reporting_import_summary_started
    ON reporting.import_summary(started_at DESC);


/* -------------------------------------------------------------------------- */
/* Catalog-kind cached totals                                                 */
/* -------------------------------------------------------------------------- */

CREATE TABLE reporting.catalog_kind_summary (
    item_kind catalog.item_kind NOT NULL,

    total_items bigint NOT NULL DEFAULT 0,
    active_items bigint NOT NULL DEFAULT 0,
    retired_items bigint NOT NULL DEFAULT 0,
    source_missing_items bigint NOT NULL DEFAULT 0,
    unresolved_custom_items bigint NOT NULL DEFAULT 0,
    archived_items bigint NOT NULL DEFAULT 0,

    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT pk_reporting_catalog_kind_summary
        PRIMARY KEY (item_kind),

    CONSTRAINT ck_reporting_catalog_kind_summary_nonnegative
        CHECK (
            total_items >= 0
            AND active_items >= 0
            AND retired_items >= 0
            AND source_missing_items >= 0
            AND unresolved_custom_items >= 0
            AND archived_items >= 0
        )
);

/* Seed every catalog kind so Greenfield immediately displays zero values. */
INSERT INTO reporting.catalog_kind_summary(item_kind)
SELECT enumlabel::catalog.item_kind
FROM pg_enum e
JOIN pg_type t
  ON t.oid = e.enumtypid
JOIN pg_namespace n
  ON n.oid = t.typnamespace
WHERE n.nspname = 'catalog'
  AND t.typname = 'item_kind'
ORDER BY e.enumsortorder;


/* -------------------------------------------------------------------------- */
/* Per-owner cached totals                                                    */
/* -------------------------------------------------------------------------- */

CREATE TABLE reporting.owner_summary (
    owner_id uuid NOT NULL,

    collection_entry_count bigint NOT NULL DEFAULT 0,
    collection_quantity numeric(24,4) NOT NULL DEFAULT 0,
    collection_instance_count bigint NOT NULL DEFAULT 0,

    active_wishlist_count bigint NOT NULL DEFAULT 0,
    active_wishlist_entry_count bigint NOT NULL DEFAULT 0,
    active_wishlist_desired_quantity numeric(24,4) NOT NULL DEFAULT 0,

    active_build_goal_count bigint NOT NULL DEFAULT 0,

    last_collection_change_at timestamptz,
    last_wishlist_change_at timestamptz,
    last_build_goal_change_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT pk_reporting_owner_summary
        PRIMARY KEY (owner_id),

    CONSTRAINT fk_reporting_owner_summary_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT ck_reporting_owner_summary_nonnegative
        CHECK (
            collection_entry_count >= 0
            AND collection_quantity >= 0
            AND collection_instance_count >= 0
            AND active_wishlist_count >= 0
            AND active_wishlist_entry_count >= 0
            AND active_wishlist_desired_quantity >= 0
            AND active_build_goal_count >= 0
        )
);

/* Existing owners, if any seed rows existed before this module. */
INSERT INTO reporting.owner_summary(owner_id)
SELECT o.owner_id
FROM identity.owners o
ON CONFLICT (owner_id) DO NOTHING;


/* -------------------------------------------------------------------------- */
/* Import delta helper                                                        */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION import.accumulate_catalog_summary_delta(
    p_source_run_id uuid,
    p_catalog_items_inserted bigint DEFAULT 0,
    p_catalog_items_updated bigint DEFAULT 0,
    p_catalog_items_retired bigint DEFAULT 0,
    p_catalog_items_restored bigint DEFAULT 0,
    p_source_missing_added bigint DEFAULT 0,
    p_sets_inserted bigint DEFAULT 0,
    p_parts_inserted bigint DEFAULT 0,
    p_minifigures_inserted bigint DEFAULT 0,
    p_instructions_inserted bigint DEFAULT 0,
    p_mocs_inserted bigint DEFAULT 0,
    p_other_items_inserted bigint DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_source_id smallint;
    v_source_code text;
    v_status import.source_run_status;
    v_started_at timestamptz;
    v_completed_at timestamptz;
    v_failed_at timestamptz;
BEGIN
    IF p_source_run_id IS NULL THEN
        RETURN;
    END IF;

    SELECT sr.source_id, es.source_code, sr.status,
           sr.started_at, sr.completed_at, sr.failed_at
      INTO v_source_id, v_source_code, v_status,
           v_started_at, v_completed_at, v_failed_at
      FROM import.source_runs sr
      JOIN reference.external_sources es
        ON es.source_id = sr.source_id
     WHERE sr.source_run_id = p_source_run_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown source_run_id: %', p_source_run_id
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO import.catalog_summary_delta (
        source_run_id,
        catalog_items_inserted,
        catalog_items_updated,
        catalog_items_retired,
        catalog_items_restored,
        source_missing_added,
        sets_inserted,
        parts_inserted,
        minifigures_inserted,
        instructions_inserted,
        mocs_inserted,
        other_items_inserted
    )
    VALUES (
        p_source_run_id,
        p_catalog_items_inserted,
        p_catalog_items_updated,
        p_catalog_items_retired,
        p_catalog_items_restored,
        p_source_missing_added,
        p_sets_inserted,
        p_parts_inserted,
        p_minifigures_inserted,
        p_instructions_inserted,
        p_mocs_inserted,
        p_other_items_inserted
    )
    ON CONFLICT (source_run_id)
    DO UPDATE SET
        catalog_items_inserted =
            import.catalog_summary_delta.catalog_items_inserted
            + EXCLUDED.catalog_items_inserted,
        catalog_items_updated =
            import.catalog_summary_delta.catalog_items_updated
            + EXCLUDED.catalog_items_updated,
        catalog_items_retired =
            import.catalog_summary_delta.catalog_items_retired
            + EXCLUDED.catalog_items_retired,
        catalog_items_restored =
            import.catalog_summary_delta.catalog_items_restored
            + EXCLUDED.catalog_items_restored,
        source_missing_added =
            import.catalog_summary_delta.source_missing_added
            + EXCLUDED.source_missing_added,
        sets_inserted =
            import.catalog_summary_delta.sets_inserted
            + EXCLUDED.sets_inserted,
        parts_inserted =
            import.catalog_summary_delta.parts_inserted
            + EXCLUDED.parts_inserted,
        minifigures_inserted =
            import.catalog_summary_delta.minifigures_inserted
            + EXCLUDED.minifigures_inserted,
        instructions_inserted =
            import.catalog_summary_delta.instructions_inserted
            + EXCLUDED.instructions_inserted,
        mocs_inserted =
            import.catalog_summary_delta.mocs_inserted
            + EXCLUDED.mocs_inserted,
        other_items_inserted =
            import.catalog_summary_delta.other_items_inserted
            + EXCLUDED.other_items_inserted,
        updated_at = clock_timestamp();

    INSERT INTO reporting.import_summary (
        source_run_id, source_id, source_code, status,
        started_at, completed_at, failed_at,
        catalog_items_inserted, catalog_items_updated,
        catalog_items_retired, catalog_items_restored,
        source_missing_added, sets_inserted, parts_inserted,
        minifigures_inserted, instructions_inserted,
        mocs_inserted, other_items_inserted, updated_at
    )
    SELECT
        p_source_run_id, v_source_id, v_source_code, v_status,
        v_started_at, v_completed_at, v_failed_at,
        d.catalog_items_inserted, d.catalog_items_updated,
        d.catalog_items_retired, d.catalog_items_restored,
        d.source_missing_added, d.sets_inserted, d.parts_inserted,
        d.minifigures_inserted, d.instructions_inserted,
        d.mocs_inserted, d.other_items_inserted, clock_timestamp()
    FROM import.catalog_summary_delta d
    WHERE d.source_run_id = p_source_run_id
    ON CONFLICT (source_run_id)
    DO UPDATE SET
        source_id = EXCLUDED.source_id,
        source_code = EXCLUDED.source_code,
        status = EXCLUDED.status,
        started_at = EXCLUDED.started_at,
        completed_at = EXCLUDED.completed_at,
        failed_at = EXCLUDED.failed_at,
        catalog_items_inserted = EXCLUDED.catalog_items_inserted,
        catalog_items_updated = EXCLUDED.catalog_items_updated,
        catalog_items_retired = EXCLUDED.catalog_items_retired,
        catalog_items_restored = EXCLUDED.catalog_items_restored,
        source_missing_added = EXCLUDED.source_missing_added,
        sets_inserted = EXCLUDED.sets_inserted,
        parts_inserted = EXCLUDED.parts_inserted,
        minifigures_inserted = EXCLUDED.minifigures_inserted,
        instructions_inserted = EXCLUDED.instructions_inserted,
        mocs_inserted = EXCLUDED.mocs_inserted,
        other_items_inserted = EXCLUDED.other_items_inserted,
        updated_at = EXCLUDED.updated_at;
END;
$function$;


/* -------------------------------------------------------------------------- */
/* Catalog-kind + import-delta statement triggers                             */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION reporting.trg_aggregate_catalog_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_source_run_id uuid;
    v_actor_class text;
    v_total bigint;
    v_sets bigint;
    v_parts bigint;
    v_minifigs bigint;
    v_instructions bigint;
    v_mocs bigint;
    v_other bigint;
BEGIN
    INSERT INTO reporting.catalog_kind_summary (
        item_kind, total_items, active_items, retired_items,
        source_missing_items, unresolved_custom_items, archived_items, updated_at
    )
    SELECT
        item_kind,
        count(*)::bigint,
        count(*) FILTER (WHERE status = 'ACTIVE')::bigint,
        count(*) FILTER (WHERE status = 'RETIRED')::bigint,
        count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint,
        count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint,
        count(*) FILTER (WHERE status = 'ARCHIVED')::bigint,
        clock_timestamp()
    FROM new_aggregate_catalog_rows
    GROUP BY item_kind
    ON CONFLICT (item_kind)
    DO UPDATE SET
        total_items =
            reporting.catalog_kind_summary.total_items + EXCLUDED.total_items,
        active_items =
            reporting.catalog_kind_summary.active_items + EXCLUDED.active_items,
        retired_items =
            reporting.catalog_kind_summary.retired_items + EXCLUDED.retired_items,
        source_missing_items =
            reporting.catalog_kind_summary.source_missing_items + EXCLUDED.source_missing_items,
        unresolved_custom_items =
            reporting.catalog_kind_summary.unresolved_custom_items + EXCLUDED.unresolved_custom_items,
        archived_items =
            reporting.catalog_kind_summary.archived_items + EXCLUDED.archived_items,
        updated_at = EXCLUDED.updated_at;

    v_actor_class :=
        NULLIF(current_setting('app.actor_class', true), '');

    IF v_actor_class = 'IMPORTER' THEN
        BEGIN
            v_source_run_id :=
                NULLIF(current_setting('app.source_run_id', true), '')::uuid;
        EXCEPTION
            WHEN invalid_text_representation THEN
                v_source_run_id := NULL;
        END;

        IF v_source_run_id IS NOT NULL THEN
            SELECT
                count(*)::bigint,
                count(*) FILTER (WHERE item_kind = 'SET')::bigint,
                count(*) FILTER (WHERE item_kind = 'PART')::bigint,
                count(*) FILTER (WHERE item_kind = 'MINIFIGURE')::bigint,
                count(*) FILTER (WHERE item_kind = 'INSTRUCTIONS')::bigint,
                count(*) FILTER (WHERE item_kind = 'MOC')::bigint,
                count(*) FILTER (
                    WHERE item_kind NOT IN (
                        'SET','PART','MINIFIGURE','INSTRUCTIONS','MOC'
                    )
                )::bigint
            INTO
                v_total, v_sets, v_parts, v_minifigs,
                v_instructions, v_mocs, v_other
            FROM new_aggregate_catalog_rows;

            PERFORM import.accumulate_catalog_summary_delta(
                v_source_run_id,
                p_catalog_items_inserted => v_total,
                p_sets_inserted => v_sets,
                p_parts_inserted => v_parts,
                p_minifigures_inserted => v_minifigs,
                p_instructions_inserted => v_instructions,
                p_mocs_inserted => v_mocs,
                p_other_items_inserted => v_other
            );
        END IF;
    END IF;

    RETURN NULL;
END;
$function$;


CREATE OR REPLACE FUNCTION reporting.trg_aggregate_catalog_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_source_run_id uuid;
    v_actor_class text;
    v_updated bigint;
    v_retired bigint;
    v_restored bigint;
    v_missing bigint;
BEGIN
    /* Subtract old state. */
    UPDATE reporting.catalog_kind_summary s
       SET total_items = s.total_items - d.total_items,
           active_items = s.active_items - d.active_items,
           retired_items = s.retired_items - d.retired_items,
           source_missing_items = s.source_missing_items - d.source_missing_items,
           unresolved_custom_items = s.unresolved_custom_items - d.unresolved_custom_items,
           archived_items = s.archived_items - d.archived_items,
           updated_at = clock_timestamp()
      FROM (
          SELECT
              item_kind,
              count(*)::bigint AS total_items,
              count(*) FILTER (WHERE status = 'ACTIVE')::bigint AS active_items,
              count(*) FILTER (WHERE status = 'RETIRED')::bigint AS retired_items,
              count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint AS source_missing_items,
              count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_items,
              count(*) FILTER (WHERE status = 'ARCHIVED')::bigint AS archived_items
          FROM old_aggregate_catalog_rows
          GROUP BY item_kind
      ) d
     WHERE s.item_kind = d.item_kind;

    /* Add new state. */
    INSERT INTO reporting.catalog_kind_summary (
        item_kind, total_items, active_items, retired_items,
        source_missing_items, unresolved_custom_items, archived_items, updated_at
    )
    SELECT
        item_kind,
        count(*)::bigint,
        count(*) FILTER (WHERE status = 'ACTIVE')::bigint,
        count(*) FILTER (WHERE status = 'RETIRED')::bigint,
        count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint,
        count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint,
        count(*) FILTER (WHERE status = 'ARCHIVED')::bigint,
        clock_timestamp()
    FROM new_aggregate_catalog_rows
    GROUP BY item_kind
    ON CONFLICT (item_kind)
    DO UPDATE SET
        total_items =
            reporting.catalog_kind_summary.total_items + EXCLUDED.total_items,
        active_items =
            reporting.catalog_kind_summary.active_items + EXCLUDED.active_items,
        retired_items =
            reporting.catalog_kind_summary.retired_items + EXCLUDED.retired_items,
        source_missing_items =
            reporting.catalog_kind_summary.source_missing_items + EXCLUDED.source_missing_items,
        unresolved_custom_items =
            reporting.catalog_kind_summary.unresolved_custom_items + EXCLUDED.unresolved_custom_items,
        archived_items =
            reporting.catalog_kind_summary.archived_items + EXCLUDED.archived_items,
        updated_at = EXCLUDED.updated_at;

    v_actor_class :=
        NULLIF(current_setting('app.actor_class', true), '');

    IF v_actor_class = 'IMPORTER' THEN
        BEGIN
            v_source_run_id :=
                NULLIF(current_setting('app.source_run_id', true), '')::uuid;
        EXCEPTION
            WHEN invalid_text_representation THEN
                v_source_run_id := NULL;
        END;

        IF v_source_run_id IS NOT NULL THEN
            SELECT
                count(*)::bigint,
                count(*) FILTER (
                    WHERE o.status <> 'RETIRED'
                      AND n.status = 'RETIRED'
                )::bigint,
                count(*) FILTER (
                    WHERE o.status IN ('RETIRED','ARCHIVED','SOURCE_MISSING')
                      AND n.status = 'ACTIVE'
                )::bigint,
                count(*) FILTER (
                    WHERE o.status <> 'SOURCE_MISSING'
                      AND n.status = 'SOURCE_MISSING'
                )::bigint
            INTO v_updated, v_retired, v_restored, v_missing
            FROM old_aggregate_catalog_rows o
            JOIN new_aggregate_catalog_rows n
              USING (catalog_item_id);

            PERFORM import.accumulate_catalog_summary_delta(
                v_source_run_id,
                p_catalog_items_updated => v_updated,
                p_catalog_items_retired => v_retired,
                p_catalog_items_restored => v_restored,
                p_source_missing_added => v_missing
            );
        END IF;
    END IF;

    RETURN NULL;
END;
$function$;


CREATE OR REPLACE FUNCTION reporting.trg_aggregate_catalog_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    UPDATE reporting.catalog_kind_summary s
       SET total_items = s.total_items - d.total_items,
           active_items = s.active_items - d.active_items,
           retired_items = s.retired_items - d.retired_items,
           source_missing_items = s.source_missing_items - d.source_missing_items,
           unresolved_custom_items = s.unresolved_custom_items - d.unresolved_custom_items,
           archived_items = s.archived_items - d.archived_items,
           updated_at = clock_timestamp()
      FROM (
          SELECT
              item_kind,
              count(*)::bigint AS total_items,
              count(*) FILTER (WHERE status = 'ACTIVE')::bigint AS active_items,
              count(*) FILTER (WHERE status = 'RETIRED')::bigint AS retired_items,
              count(*) FILTER (WHERE status = 'SOURCE_MISSING')::bigint AS source_missing_items,
              count(*) FILTER (WHERE status = 'UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_items,
              count(*) FILTER (WHERE status = 'ARCHIVED')::bigint AS archived_items
          FROM old_aggregate_catalog_rows
          GROUP BY item_kind
      ) d
     WHERE s.item_kind = d.item_kind;

    RETURN NULL;
END;
$function$;


CREATE TRIGGER trg_catalog_items_aggregate_insert
AFTER INSERT ON catalog.items
REFERENCING NEW TABLE AS new_aggregate_catalog_rows
FOR EACH STATEMENT
EXECUTE FUNCTION reporting.trg_aggregate_catalog_insert();

CREATE TRIGGER trg_catalog_items_aggregate_update
AFTER UPDATE ON catalog.items
REFERENCING OLD TABLE AS old_aggregate_catalog_rows
            NEW TABLE AS new_aggregate_catalog_rows
FOR EACH STATEMENT
EXECUTE FUNCTION reporting.trg_aggregate_catalog_update();

CREATE TRIGGER trg_catalog_items_aggregate_delete
AFTER DELETE ON catalog.items
REFERENCING OLD TABLE AS old_aggregate_catalog_rows
FOR EACH STATEMENT
EXECUTE FUNCTION reporting.trg_aggregate_catalog_delete();



/*
 * Checkpointed reconciliation restart protection.
 *
 * Phase 3B/4B/5B restart deletes source_run_steps before replaying canonical
 * work. Clear the accumulated delta for those non-terminal runs so replay
 * cannot double-count import statistics.
 */
CREATE OR REPLACE FUNCTION reporting.trg_reset_import_summary_on_step_restart()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    DELETE FROM import.catalog_summary_delta d
    USING (
        SELECT DISTINCT o.source_run_id
        FROM old_summary_steps o
        JOIN import.source_runs sr
          ON sr.source_run_id = o.source_run_id
        WHERE sr.status <> 'COMPLETED'
    ) r
    WHERE d.source_run_id = r.source_run_id;

    UPDATE reporting.import_summary s
       SET catalog_items_inserted = 0,
           catalog_items_updated = 0,
           catalog_items_retired = 0,
           catalog_items_restored = 0,
           source_missing_added = 0,
           sets_inserted = 0,
           parts_inserted = 0,
           minifigures_inserted = 0,
           instructions_inserted = 0,
           mocs_inserted = 0,
           other_items_inserted = 0,
           updated_at = clock_timestamp()
      FROM (
          SELECT DISTINCT o.source_run_id
          FROM old_summary_steps o
          JOIN import.source_runs sr
            ON sr.source_run_id = o.source_run_id
          WHERE sr.status <> 'COMPLETED'
      ) r
     WHERE s.source_run_id = r.source_run_id;

    RETURN NULL;
END;
$function$;

CREATE TRIGGER trg_source_run_steps_reset_import_summary
AFTER DELETE ON import.source_run_steps
REFERENCING OLD TABLE AS old_summary_steps
FOR EACH STATEMENT
EXECUTE FUNCTION reporting.trg_reset_import_summary_on_step_restart();


/* Keep reporting.import_summary lifecycle timestamps/status current. */
CREATE OR REPLACE FUNCTION reporting.trg_import_summary_source_run()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_source_code text;
BEGIN
    SELECT es.source_code
      INTO v_source_code
      FROM reference.external_sources es
     WHERE es.source_id = NEW.source_id;

    INSERT INTO reporting.import_summary (
        source_run_id, source_id, source_code, status,
        started_at, completed_at, failed_at, updated_at
    )
    VALUES (
        NEW.source_run_id, NEW.source_id, v_source_code, NEW.status,
        NEW.started_at, NEW.completed_at, NEW.failed_at, clock_timestamp()
    )
    ON CONFLICT (source_run_id)
    DO UPDATE SET
        source_id = EXCLUDED.source_id,
        source_code = EXCLUDED.source_code,
        status = EXCLUDED.status,
        started_at = EXCLUDED.started_at,
        completed_at = EXCLUDED.completed_at,
        failed_at = EXCLUDED.failed_at,
        updated_at = EXCLUDED.updated_at;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_source_runs_import_summary
AFTER INSERT OR UPDATE OF status, completed_at, failed_at
ON import.source_runs
FOR EACH ROW
EXECUTE FUNCTION reporting.trg_import_summary_source_run();


/* -------------------------------------------------------------------------- */
/* Owner summary targeted refresh                                             */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION reporting.refresh_owner_summary(p_owner_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF p_owner_id IS NULL THEN
        RETURN;
    END IF;

    INSERT INTO reporting.owner_summary(owner_id)
    VALUES (p_owner_id)
    ON CONFLICT (owner_id) DO NOTHING;

    UPDATE reporting.owner_summary s
       SET collection_entry_count = (
               SELECT count(*)::bigint
               FROM collection.entries e
               WHERE e.owner_id = p_owner_id
                 AND e.status <> 'ARCHIVED'
           ),
           collection_quantity = (
               SELECT COALESCE(sum(e.quantity::numeric), 0)::numeric(24,4)
               FROM collection.entries e
               WHERE e.owner_id = p_owner_id
                 AND e.status <> 'ARCHIVED'
           ),
           collection_instance_count = (
               SELECT count(*)::bigint
               FROM collection.instances i
               JOIN collection.entries e
                 ON e.collection_entry_id = i.collection_entry_id
               WHERE e.owner_id = p_owner_id
                 AND e.status <> 'ARCHIVED'
                 AND i.archived_at IS NULL
           ),
           active_wishlist_count = (
               SELECT count(*)::bigint
               FROM wanted.wishlists w
               WHERE w.owner_id = p_owner_id
                 AND w.archived_at IS NULL
           ),
           active_wishlist_entry_count = (
               SELECT count(*)::bigint
               FROM wanted.wishlist_entries we
               JOIN wanted.wishlists w
                 ON w.wishlist_id = we.wishlist_id
               WHERE w.owner_id = p_owner_id
                 AND w.archived_at IS NULL
                 AND we.status <> 'ARCHIVED'
           ),
           active_wishlist_desired_quantity = (
               SELECT COALESCE(sum(we.desired_quantity::numeric), 0)::numeric(24,4)
               FROM wanted.wishlist_entries we
               JOIN wanted.wishlists w
                 ON w.wishlist_id = we.wishlist_id
               WHERE w.owner_id = p_owner_id
                 AND w.archived_at IS NULL
                 AND we.status <> 'ARCHIVED'
           ),
           active_build_goal_count = (
               SELECT count(*)::bigint
               FROM wanted.build_goals g
               WHERE g.owner_id = p_owner_id
                 AND g.status NOT IN ('COMPLETE', 'ARCHIVED')
           ),
           updated_at = clock_timestamp()
     WHERE s.owner_id = p_owner_id;
END;
$function$;


CREATE OR REPLACE FUNCTION reporting.trg_owner_summary_seed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    INSERT INTO reporting.owner_summary(owner_id)
    VALUES (NEW.owner_id)
    ON CONFLICT (owner_id) DO NOTHING;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_identity_owners_summary_seed
AFTER INSERT ON identity.owners
FOR EACH ROW
EXECUTE FUNCTION reporting.trg_owner_summary_seed();


CREATE OR REPLACE FUNCTION reporting.trg_owner_summary_collection_entry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM reporting.refresh_owner_summary(NEW.owner_id);
    END IF;
    IF TG_OP <> 'INSERT'
       AND (TG_OP = 'DELETE' OR OLD.owner_id IS DISTINCT FROM NEW.owner_id)
    THEN
        PERFORM reporting.refresh_owner_summary(OLD.owner_id);
    END IF;

    UPDATE reporting.owner_summary
       SET last_collection_change_at = clock_timestamp()
     WHERE owner_id = COALESCE(NEW.owner_id, OLD.owner_id);

    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER trg_collection_entries_owner_summary
AFTER INSERT OR UPDATE OR DELETE
ON collection.entries
FOR EACH ROW
EXECUTE FUNCTION reporting.trg_owner_summary_collection_entry();


CREATE OR REPLACE FUNCTION reporting.trg_owner_summary_collection_instance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_owner_id uuid;
BEGIN
    SELECT e.owner_id
      INTO v_owner_id
      FROM collection.entries e
     WHERE e.collection_entry_id =
           COALESCE(NEW.collection_entry_id, OLD.collection_entry_id);

    IF v_owner_id IS NOT NULL THEN
        PERFORM reporting.refresh_owner_summary(v_owner_id);
        UPDATE reporting.owner_summary
           SET last_collection_change_at = clock_timestamp()
         WHERE owner_id = v_owner_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER trg_collection_instances_owner_summary
AFTER INSERT OR UPDATE OR DELETE
ON collection.instances
FOR EACH ROW
EXECUTE FUNCTION reporting.trg_owner_summary_collection_instance();


CREATE OR REPLACE FUNCTION reporting.trg_owner_summary_wishlist()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM reporting.refresh_owner_summary(NEW.owner_id);
    END IF;
    IF TG_OP <> 'INSERT'
       AND (TG_OP = 'DELETE' OR OLD.owner_id IS DISTINCT FROM NEW.owner_id)
    THEN
        PERFORM reporting.refresh_owner_summary(OLD.owner_id);
    END IF;

    UPDATE reporting.owner_summary
       SET last_wishlist_change_at = clock_timestamp()
     WHERE owner_id = COALESCE(NEW.owner_id, OLD.owner_id);

    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER trg_wishlists_owner_summary
AFTER INSERT OR UPDATE OR DELETE
ON wanted.wishlists
FOR EACH ROW
EXECUTE FUNCTION reporting.trg_owner_summary_wishlist();


CREATE OR REPLACE FUNCTION reporting.trg_owner_summary_wishlist_entry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_owner_id uuid;
BEGIN
    SELECT w.owner_id
      INTO v_owner_id
      FROM wanted.wishlists w
     WHERE w.wishlist_id = COALESCE(NEW.wishlist_id, OLD.wishlist_id);

    IF v_owner_id IS NOT NULL THEN
        PERFORM reporting.refresh_owner_summary(v_owner_id);
        UPDATE reporting.owner_summary
           SET last_wishlist_change_at = clock_timestamp()
         WHERE owner_id = v_owner_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER trg_wishlist_entries_owner_summary
AFTER INSERT OR UPDATE OR DELETE
ON wanted.wishlist_entries
FOR EACH ROW
EXECUTE FUNCTION reporting.trg_owner_summary_wishlist_entry();


CREATE OR REPLACE FUNCTION reporting.trg_owner_summary_build_goal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
    IF TG_OP <> 'DELETE' THEN
        PERFORM reporting.refresh_owner_summary(NEW.owner_id);
    END IF;
    IF TG_OP <> 'INSERT'
       AND (TG_OP = 'DELETE' OR OLD.owner_id IS DISTINCT FROM NEW.owner_id)
    THEN
        PERFORM reporting.refresh_owner_summary(OLD.owner_id);
    END IF;

    UPDATE reporting.owner_summary
       SET last_build_goal_change_at = clock_timestamp()
     WHERE owner_id = COALESCE(NEW.owner_id, OLD.owner_id);

    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER trg_build_goals_owner_summary
AFTER INSERT OR UPDATE OR DELETE
ON wanted.build_goals
FOR EACH ROW
EXECUTE FUNCTION reporting.trg_owner_summary_build_goal();


/* -------------------------------------------------------------------------- */
/* Execute-only reads                                                         */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION reporting.get_import_summary(
    p_limit integer DEFAULT 50
)
RETURNS SETOF reporting.import_summary
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
    SELECT s.*
    FROM reporting.import_summary s
    ORDER BY s.started_at DESC
    LIMIT greatest(1, least(COALESCE(p_limit, 50), 500))
$function$;


CREATE OR REPLACE FUNCTION reporting.get_catalog_kind_summary()
RETURNS SETOF reporting.catalog_kind_summary
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
    SELECT s.*
    FROM reporting.catalog_kind_summary s
    ORDER BY s.item_kind
$function$;


CREATE OR REPLACE FUNCTION reporting.get_owner_summary(p_owner_id uuid)
RETURNS reporting.owner_summary
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
    SELECT s
    FROM reporting.owner_summary s
    WHERE s.owner_id = p_owner_id
$function$;



/*
 * Importer-safe system-summary read surface.
 *
 * The runtime importer already has USAGE on schema import. Keeping this wrapper
 * in import avoids granting the importer general visibility into reporting.
 */
CREATE OR REPLACE FUNCTION import.get_system_summary()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
    SELECT reporting.get_system_summary()
$function$;


/* -------------------------------------------------------------------------- */
/* Security                                                                   */
/* -------------------------------------------------------------------------- */

REVOKE ALL ON TABLE import.catalog_summary_delta FROM PUBLIC;
REVOKE ALL ON TABLE reporting.import_summary FROM PUBLIC;
REVOKE ALL ON TABLE reporting.catalog_kind_summary FROM PUBLIC;
REVOKE ALL ON TABLE reporting.owner_summary FROM PUBLIC;

REVOKE ALL ON FUNCTION import.accumulate_catalog_summary_delta(
    uuid,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint
) FROM PUBLIC;

REVOKE ALL ON FUNCTION reporting.refresh_owner_summary(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION reporting.trg_aggregate_catalog_insert() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_aggregate_catalog_update() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_aggregate_catalog_delete() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_reset_import_summary_on_step_restart() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_import_summary_source_run() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_owner_summary_seed() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_owner_summary_collection_entry() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_owner_summary_collection_instance() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_owner_summary_wishlist() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_owner_summary_wishlist_entry() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.trg_owner_summary_build_goal() FROM PUBLIC;

REVOKE ALL ON FUNCTION import.get_system_summary() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.get_import_summary(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.get_catalog_kind_summary() FROM PUBLIC;
REVOKE ALL ON FUNCTION reporting.get_owner_summary(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION import.get_system_summary()
TO brktrkr_import;

GRANT EXECUTE ON FUNCTION reporting.get_import_summary(integer)
TO brktrkr_api, brktrkr_reporting, brktrkr_import;

GRANT EXECUTE ON FUNCTION reporting.get_catalog_kind_summary()
TO brktrkr_api, brktrkr_reporting, brktrkr_import;

GRANT EXECUTE ON FUNCTION reporting.get_owner_summary(uuid)
TO brktrkr_api, brktrkr_reporting;


/* -------------------------------------------------------------------------- */
/* Greenfield/current-data baseline                                           */
/* -------------------------------------------------------------------------- */

/*
 * Normally Greenfield has no catalog data here. The statements below also make
 * this module correct if installed into an already populated development DB.
 */
UPDATE reporting.catalog_kind_summary s
   SET total_items = x.total_items,
       active_items = x.active_items,
       retired_items = x.retired_items,
       source_missing_items = x.source_missing_items,
       unresolved_custom_items = x.unresolved_custom_items,
       archived_items = x.archived_items,
       updated_at = clock_timestamp()
  FROM (
      SELECT
          k.item_kind,
          count(i.catalog_item_id)::bigint AS total_items,
          count(i.catalog_item_id) FILTER (WHERE i.status = 'ACTIVE')::bigint AS active_items,
          count(i.catalog_item_id) FILTER (WHERE i.status = 'RETIRED')::bigint AS retired_items,
          count(i.catalog_item_id) FILTER (WHERE i.status = 'SOURCE_MISSING')::bigint AS source_missing_items,
          count(i.catalog_item_id) FILTER (WHERE i.status = 'UNRESOLVED_CUSTOM')::bigint AS unresolved_custom_items,
          count(i.catalog_item_id) FILTER (WHERE i.status = 'ARCHIVED')::bigint AS archived_items
      FROM reporting.catalog_kind_summary k
      LEFT JOIN catalog.items i
        ON i.item_kind = k.item_kind
      GROUP BY k.item_kind
  ) x
 WHERE s.item_kind = x.item_kind;

INSERT INTO reporting.import_summary (
    source_run_id, source_id, source_code, status,
    started_at, completed_at, failed_at
)
SELECT
    sr.source_run_id, sr.source_id, es.source_code, sr.status,
    sr.started_at, sr.completed_at, sr.failed_at
FROM import.source_runs sr
JOIN reference.external_sources es
  ON es.source_id = sr.source_id
ON CONFLICT (source_run_id) DO NOTHING;

SELECT reporting.refresh_owner_summary(o.owner_id)
FROM identity.owners o;


SELECT pg_temp.bt_mark_completed('1000_reporting/1011_reporting_aggregate_tables.sql');
\echo '[PASS] 1011_reporting_aggregate_tables.sql'
