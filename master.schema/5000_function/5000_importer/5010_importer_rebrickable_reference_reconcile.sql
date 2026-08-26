/*
===============================================================================
 File:           5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Reconcile validated Rebrickable Phase-1 staging into canonical
                 colors, themes and part categories.
 Depends On:     5000_function/5000_importer/5000_importer_common.sql
                 reference.external_sources
                 reference.external_color_mappings
                 reference.external_theme_mappings
                 reference.external_category_mappings
                 reference.colors
                 reference.themes
                 reference.categories
 Creates:        import.reconcile_rebrickable_reference(uuid)
 Security:       SECURITY DEFINER; callable only by lego_importer after grants.
                 lego_importer receives no direct canonical DML.
===============================================================================
*/

\set ON_ERROR_STOP on

SELECT pg_temp.bt_preflight('5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', ARRAY['5000_function/5000_importer/5000_importer_common.sql', 'reference.external_sources', 'reference.external_color_mappings', 'reference.external_theme_mappings', 'reference.external_category_mappings', 'reference.colors', 'reference.themes', 'reference.categories']::text[]);





CREATE OR REPLACE FUNCTION import.reconcile_rebrickable_reference(
    p_source_run_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_source_id smallint;
    v_run_status import.source_run_status;

    v_record record;
    v_color_id bigint;
    v_theme_id integer;
    v_parent_theme_id integer;
    v_category_id integer;

    v_progress boolean;
    v_remaining integer;

    v_colors integer := 0;
    v_themes integer := 0;
    v_categories integer := 0;

    v_created_colors integer := 0;
    v_created_themes integer := 0;
    v_created_categories integer := 0;

    v_now timestamptz := clock_timestamp();
    v_result jsonb;
BEGIN
    /* ----------------------------------------------------------------------
     * Lock and validate the source run.
     * ---------------------------------------------------------------------- */

    SELECT r.source_id, r.status
      INTO v_source_id, v_run_status
    FROM import.source_runs AS r
    JOIN reference.external_sources AS s
      ON s.source_id = r.source_id
    WHERE r.source_run_id = p_source_run_id
      AND s.source_code = 'REBRICKABLE'
    FOR UPDATE OF r;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Rebrickable source run % does not exist',
            p_source_run_id
            USING ERRCODE = '22023';
    END IF;

    IF v_run_status NOT IN ('VALIDATING', 'FINALIZING') THEN
        RAISE EXCEPTION
            'Rebrickable source run % must be VALIDATING or FINALIZING; current status=%',
            p_source_run_id,
            v_run_status
            USING ERRCODE = '55000';
    END IF;

    /* Exactly the required Phase-1 datasets must be validated/completed. */
    IF EXISTS (
        SELECT 1
        FROM (
            VALUES ('themes'), ('colors'), ('part_categories')
        ) AS required(dataset_name)
        LEFT JOIN import.source_run_datasets AS d
          ON d.source_run_id = p_source_run_id
         AND d.dataset_name = required.dataset_name
        WHERE d.source_run_dataset_id IS NULL
           OR d.status NOT IN ('VALIDATED', 'COMPLETED')
           OR d.source_row_count IS NULL
           OR d.staged_row_count IS NULL
           OR d.source_row_count <> d.staged_row_count
           OR d.checksum_sha256 IS NULL
    ) THEN
        RAISE EXCEPTION
            'Source run % does not have a complete validated Phase-1 dataset contract',
            p_source_run_id
            USING ERRCODE = '55000';
    END IF;

    /* Staged counts must still agree with recorded evidence. */
    IF EXISTS (
        SELECT 1
        FROM import.source_run_datasets AS d
        WHERE d.source_run_id = p_source_run_id
          AND d.dataset_name IN ('themes', 'colors', 'part_categories')
          AND d.staged_row_count <> (
              SELECT count(*)
              FROM import.source_stage_records AS sr
              WHERE sr.source_run_id = d.source_run_id
                AND sr.dataset_name = d.dataset_name
          )
    ) THEN
        RAISE EXCEPTION
            'Source run % staging evidence changed after validation',
            p_source_run_id
            USING ERRCODE = '55000';
    END IF;

    UPDATE import.source_runs
    SET status = 'FINALIZING'
    WHERE source_run_id = p_source_run_id;


    /* ======================================================================
     * COLORS
     * ====================================================================== */

    FOR v_record IN
        SELECT
            sr.normalized_payload->>'id' AS external_id,
            sr.normalized_payload->>'name' AS external_name,
            upper(sr.normalized_payload->>'rgb') AS rgb_hex,
            (sr.normalized_payload->>'is_trans')::boolean AS is_transparent
        FROM import.source_stage_records AS sr
        WHERE sr.source_run_id = p_source_run_id
          AND sr.dataset_name = 'colors'
          AND sr.entity_namespace = 'COLOR'
        ORDER BY sr.source_row_number
    LOOP
        v_color_id := NULL;

        /* Existing active mapping wins. */
        SELECT m.color_id
          INTO v_color_id
        FROM reference.external_color_mappings AS m
        WHERE m.source_id = v_source_id
          AND m.external_color_id = v_record.external_id
          AND m.valid_to IS NULL
        LIMIT 1;

        IF v_color_id IS NOT NULL THEN
            UPDATE reference.external_color_mappings
            SET
                external_color_name = v_record.external_name,
                external_rgb_hex = v_record.rgb_hex,
                last_seen_at = v_now
            WHERE source_id = v_source_id
              AND external_color_id = v_record.external_id
              AND valid_to IS NULL;

        ELSE
            /* If the source ID existed historically, preserve its canonical
             * identity when it reappears. */
            SELECT m.color_id
              INTO v_color_id
            FROM reference.external_color_mappings AS m
            WHERE m.source_id = v_source_id
              AND m.external_color_id = v_record.external_id
            ORDER BY m.valid_from DESC
            LIMIT 1;

            /* Otherwise exact canonical name is the conservative merge key.
             * reference.colors enforces that name as unique. */
            IF v_color_id IS NULL THEN
                SELECT c.color_id
                  INTO v_color_id
                FROM reference.colors AS c
                WHERE c.canonical_name = v_record.external_name
                LIMIT 1;
            END IF;

            IF v_color_id IS NULL THEN
                INSERT INTO reference.colors (
                    canonical_name,
                    rgb_hex,
                    is_transparent
                )
                VALUES (
                    v_record.external_name,
                    v_record.rgb_hex,
                    v_record.is_transparent
                )
                RETURNING color_id INTO v_color_id;

                v_created_colors := v_created_colors + 1;
            END IF;

            INSERT INTO reference.external_color_mappings (
                source_id,
                external_color_id,
                color_id,
                external_color_name,
                external_rgb_hex,
                first_seen_at,
                last_seen_at,
                valid_from
            )
            VALUES (
                v_source_id,
                v_record.external_id,
                v_color_id,
                v_record.external_name,
                v_record.rgb_hex,
                v_now,
                v_now,
                v_now
            );
        END IF;

        v_colors := v_colors + 1;
    END LOOP;

    /* A complete authoritative colors snapshot may close active source
     * mappings that were not observed. Canonical colors are never deleted. */
    UPDATE reference.external_color_mappings AS m
    SET valid_to = v_now
    WHERE m.source_id = v_source_id
      AND m.valid_to IS NULL
      AND NOT EXISTS (
          SELECT 1
          FROM import.source_stage_records AS sr
          WHERE sr.source_run_id = p_source_run_id
            AND sr.dataset_name = 'colors'
            AND sr.entity_namespace = 'COLOR'
            AND sr.normalized_payload->>'id' = m.external_color_id
      );


    /* ======================================================================
     * THEMES
     * ====================================================================== */

    /* Complete authoritative snapshot: mark all source mappings absent first;
     * each staged record turns its mapping back on. */
    UPDATE reference.external_theme_mappings
    SET source_present = false
    WHERE source_id = v_source_id;

    CREATE TEMP TABLE bt_phase2_pending_themes (
        external_id text PRIMARY KEY,
        external_name text NOT NULL,
        parent_external_id text
    ) ON COMMIT DROP;

    INSERT INTO bt_phase2_pending_themes (
        external_id,
        external_name,
        parent_external_id
    )
    SELECT
        sr.normalized_payload->>'id',
        sr.normalized_payload->>'name',
        NULLIF(sr.normalized_payload->>'parent_id', '')
    FROM import.source_stage_records AS sr
    WHERE sr.source_run_id = p_source_run_id
      AND sr.dataset_name = 'themes'
      AND sr.entity_namespace = 'THEME';

    LOOP
        v_progress := false;

        FOR v_record IN
            SELECT p.*
            FROM bt_phase2_pending_themes AS p
            ORDER BY p.external_id
        LOOP
            v_parent_theme_id := NULL;

            IF v_record.parent_external_id IS NOT NULL THEN
                SELECT m.theme_id
                  INTO v_parent_theme_id
                FROM reference.external_theme_mappings AS m
                WHERE m.source_id = v_source_id
                  AND m.external_theme_id = v_record.parent_external_id
                  AND m.source_present
                LIMIT 1;

                IF v_parent_theme_id IS NULL THEN
                    CONTINUE;
                END IF;
            END IF;

            v_theme_id := NULL;

            SELECT m.theme_id
              INTO v_theme_id
            FROM reference.external_theme_mappings AS m
            WHERE m.source_id = v_source_id
              AND m.external_theme_id = v_record.external_id
            LIMIT 1;

            IF v_theme_id IS NULL THEN
                SELECT t.theme_id
                  INTO v_theme_id
                FROM reference.themes AS t
                WHERE t.theme_name = v_record.external_name
                  AND t.parent_theme_id IS NOT DISTINCT FROM v_parent_theme_id
                LIMIT 1;
            END IF;

            IF v_theme_id IS NULL THEN
                INSERT INTO reference.themes (
                    parent_theme_id,
                    theme_name
                )
                VALUES (
                    v_parent_theme_id,
                    v_record.external_name
                )
                RETURNING theme_id INTO v_theme_id;

                v_created_themes := v_created_themes + 1;
            ELSE
                /* Existing source mapping makes this source relationship
                 * authoritative for the mapped canonical theme. Conflicts fail
                 * through canonical uniqueness constraints instead of silently
                 * remapping identity. */
                UPDATE reference.themes
                SET
                    parent_theme_id = v_parent_theme_id,
                    theme_name = v_record.external_name,
                    is_retired = false
                WHERE theme_id = v_theme_id;
            END IF;

            INSERT INTO reference.external_theme_mappings (
                source_id,
                external_theme_id,
                external_theme_name,
                theme_id,
                source_present,
                first_seen_at,
                last_seen_at
            )
            VALUES (
                v_source_id,
                v_record.external_id,
                v_record.external_name,
                v_theme_id,
                true,
                v_now,
                v_now
            )
            ON CONFLICT (source_id, external_theme_id)
            DO UPDATE SET
                external_theme_name = EXCLUDED.external_theme_name,
                source_present = true,
                last_seen_at = EXCLUDED.last_seen_at;

            DELETE FROM bt_phase2_pending_themes
            WHERE external_id = v_record.external_id;

            v_themes := v_themes + 1;
            v_progress := true;
        END LOOP;

        SELECT count(*)::integer
          INTO v_remaining
        FROM bt_phase2_pending_themes;

        EXIT WHEN v_remaining = 0;

        IF NOT v_progress THEN
            RAISE EXCEPTION
                'Unable to reconcile Rebrickable theme hierarchy for source run %; % unresolved theme(s) remain',
                p_source_run_id,
                v_remaining
                USING ERRCODE = '23514';
        END IF;
    END LOOP;


    /* ======================================================================
     * PART CATEGORIES
     * ====================================================================== */

    UPDATE reference.external_category_mappings
    SET source_present = false
    WHERE source_id = v_source_id;

    FOR v_record IN
        SELECT
            sr.normalized_payload->>'id' AS external_id,
            sr.normalized_payload->>'name' AS external_name
        FROM import.source_stage_records AS sr
        WHERE sr.source_run_id = p_source_run_id
          AND sr.dataset_name = 'part_categories'
          AND sr.entity_namespace = 'PART_CATEGORY'
        ORDER BY sr.source_row_number
    LOOP
        v_category_id := NULL;

        SELECT m.category_id
          INTO v_category_id
        FROM reference.external_category_mappings AS m
        WHERE m.source_id = v_source_id
          AND m.external_category_id = v_record.external_id
        LIMIT 1;

        IF v_category_id IS NULL THEN
            SELECT c.category_id
              INTO v_category_id
            FROM reference.categories AS c
            WHERE c.category_namespace = 'PART'
              AND c.parent_category_id IS NULL
              AND c.category_name = v_record.external_name
            LIMIT 1;
        END IF;

        IF v_category_id IS NULL THEN
            INSERT INTO reference.categories (
                parent_category_id,
                category_namespace,
                category_name
            )
            VALUES (
                NULL,
                'PART',
                v_record.external_name
            )
            RETURNING category_id INTO v_category_id;

            v_created_categories := v_created_categories + 1;
        ELSE
            UPDATE reference.categories
            SET
                category_name = v_record.external_name,
                is_retired = false
            WHERE category_id = v_category_id;
        END IF;

        INSERT INTO reference.external_category_mappings (
            source_id,
            external_category_id,
            external_category_name,
            category_id,
            source_present,
            first_seen_at,
            last_seen_at
        )
        VALUES (
            v_source_id,
            v_record.external_id,
            v_record.external_name,
            v_category_id,
            true,
            v_now,
            v_now
        )
        ON CONFLICT (source_id, external_category_id)
        DO UPDATE SET
            external_category_name = EXCLUDED.external_category_name,
            source_present = true,
            last_seen_at = EXCLUDED.last_seen_at;

        v_categories := v_categories + 1;
    END LOOP;


    /* ======================================================================
     * DATASET / RUN COMPLETION
     * ====================================================================== */

    UPDATE import.source_run_datasets
    SET
        status = 'COMPLETED',
        completed_at = COALESCE(completed_at, v_now)
    WHERE source_run_id = p_source_run_id
      AND dataset_name IN ('themes', 'colors', 'part_categories')
      AND status <> 'COMPLETED';

    v_result := jsonb_build_object(
        'source_run_id', p_source_run_id,
        'phase', 2,
        'reconciled', jsonb_build_object(
            'colors', v_colors,
            'themes', v_themes,
            'part_categories', v_categories
        ),
        'canonical_created', jsonb_build_object(
            'colors', v_created_colors,
            'themes', v_created_themes,
            'part_categories', v_created_categories
        ),
        'completed_at', v_now
    );

    UPDATE import.source_runs
    SET
        summary = COALESCE(summary, '{}'::jsonb)
                  || jsonb_build_object('reference_reconciliation', v_result),
        status = CASE
            WHEN NOT EXISTS (
                SELECT 1
                FROM import.source_run_datasets AS d
                WHERE d.source_run_id = p_source_run_id
                  AND d.is_authoritative_scope
                  AND d.status <> 'COMPLETED'
            )
            THEN 'COMPLETED'::import.source_run_status
            ELSE 'VALIDATING'::import.source_run_status
        END,
        completed_at = CASE
            WHEN NOT EXISTS (
                SELECT 1
                FROM import.source_run_datasets AS d
                WHERE d.source_run_id = p_source_run_id
                  AND d.is_authoritative_scope
                  AND d.status <> 'COMPLETED'
            )
            THEN v_now
            ELSE NULL
        END
    WHERE source_run_id = p_source_run_id;

    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION import.reconcile_rebrickable_reference(uuid) FROM PUBLIC;

COMMENT ON FUNCTION import.reconcile_rebrickable_reference(uuid) IS
    'Atomically reconciles validated Rebrickable Phase-1 reference staging '
    'into canonical colors, themes, part categories and external mappings.';

SELECT pg_temp.bt_mark_completed('5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql');
