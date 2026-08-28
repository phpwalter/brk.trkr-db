/*
===============================================================================
 File:           5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Execute-only importer surface for SET manifest enrichment.
 Depends On:     0400_definitions/0410_set_manifest_components.sql
                 1100_security/1100_roles.sql
                 0300_catalog/0317_external_identifiers.sql
                 0300_catalog/0302_catalog_parts.sql
                 0300_catalog/0306_catalog_sticker_sheets.sql
                 5000_function/5700_system/5702_system_catalog.sql
                 import.source_stage_records
                 reference.categories
                 app.set_import_context(uuid)
 Creates:        import.upsert_set_manifest_component(...)
                 import.mark_set_manifest_component_missing(...)
                 import.reconcile_rebrickable_sticker_sheets(uuid)
 Key Rules:      SECURITY DEFINER; lego_importer membership required.
                 lego_importer has no direct DML on definition tables.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql', ARRAY['0400_definitions/0410_set_manifest_components.sql', '1100_security/1100_roles.sql', '0300_catalog/0317_external_identifiers.sql', '0300_catalog/0302_catalog_parts.sql', '0300_catalog/0306_catalog_sticker_sheets.sql', '5000_function/5700_system/5702_system_catalog.sql', 'import.source_stage_records', 'reference.categories', 'app.set_import_context(uuid)']::text[]);

CREATE OR REPLACE FUNCTION import.upsert_set_manifest_component(
    p_set_num text,
    p_component_kind text,
    p_source_code text,
    p_external_id text,
    p_display_name text DEFAULT NULL,
    p_source_url text DEFAULT NULL,
    p_quantity integer DEFAULT 1,
    p_source_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_set_id uuid;
    v_kind catalog.item_kind;
    v_row definition.set_manifest_components%ROWTYPE;
BEGIN
    IF NOT pg_has_role(session_user, 'lego_importer', 'MEMBER') THEN
        RAISE EXCEPTION
            'import.upsert_set_manifest_component requires lego_importer membership'
            USING ERRCODE = '42501';
    END IF;

    IF p_set_num IS NULL OR btrim(p_set_num) = '' THEN
        RAISE EXCEPTION 'set number is required' USING ERRCODE = '22023';
    END IF;

    IF upper(btrim(p_component_kind))
       NOT IN ('STICKER_SHEET','INSTRUCTIONS','PACKAGING')
    THEN
        RAISE EXCEPTION
            'unsupported manifest component kind: %', p_component_kind
            USING ERRCODE = '22023';
    END IF;

    IF p_source_code IS NULL OR btrim(p_source_code) = ''
       OR p_external_id IS NULL OR btrim(p_external_id) = ''
       OR p_quantity IS NULL OR p_quantity <= 0
    THEN
        RAISE EXCEPTION
            'source_code, external_id and positive quantity are required'
            USING ERRCODE = '22023';
    END IF;

    v_kind := upper(btrim(p_component_kind))::catalog.item_kind;

    SELECT ei.catalog_item_id
      INTO v_set_id
      FROM catalog.external_identifiers ei
      JOIN reference.external_sources es
        ON es.source_id = ei.source_id
      JOIN catalog.items ci
        ON ci.catalog_item_id = ei.catalog_item_id
     WHERE es.source_code = 'REBRICKABLE'
       AND ei.entity_namespace = 'SET'
       AND ei.catalog_item_id IS NOT NULL
       AND ei.source_present
       AND ci.item_kind = 'SET'::catalog.item_kind
       AND (
           ei.external_id = btrim(p_set_num)
           OR ei.external_id = btrim(p_set_num) || '-1'
           OR split_part(ei.external_id, '-', 1) = btrim(p_set_num)
       )
     ORDER BY
       CASE
         WHEN ei.external_id = btrim(p_set_num) || '-1' THEN 0
         WHEN ei.external_id = btrim(p_set_num) THEN 1
         ELSE 2
       END,
       ei.external_id
     LIMIT 1;

    IF v_set_id IS NULL THEN
        RAISE EXCEPTION
            'canonical SET % was not found', p_set_num
            USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO definition.set_manifest_components (
        set_catalog_item_id,
        component_kind,
        source_code,
        external_id,
        display_name,
        source_url,
        quantity,
        source_present,
        source_payload,
        first_seen_at,
        last_seen_at
    )
    VALUES (
        v_set_id,
        v_kind,
        upper(btrim(p_source_code)),
        btrim(p_external_id),
        NULLIF(btrim(p_display_name), ''),
        NULLIF(btrim(p_source_url), ''),
        p_quantity,
        true,
        COALESCE(p_source_payload, '{}'::jsonb),
        clock_timestamp(),
        clock_timestamp()
    )
    ON CONFLICT (
        set_catalog_item_id,
        component_kind,
        source_code,
        external_id
    )
    DO UPDATE
       SET display_name = EXCLUDED.display_name,
           source_url = EXCLUDED.source_url,
           quantity = EXCLUDED.quantity,
           source_present = true,
           source_payload = EXCLUDED.source_payload,
           last_seen_at = clock_timestamp()
    RETURNING *
      INTO v_row;

    RETURN jsonb_build_object(
        'set_catalog_item_id', v_row.set_catalog_item_id,
        'component_kind', v_row.component_kind::text,
        'source_code', v_row.source_code,
        'external_id', v_row.external_id,
        'quantity', v_row.quantity,
        'source_present', v_row.source_present
    );
END;
$function$;


CREATE OR REPLACE FUNCTION import.mark_set_manifest_component_missing(
    p_set_num text,
    p_component_kind text,
    p_source_code text,
    p_external_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_set_id uuid;
    v_kind catalog.item_kind;
    v_count integer;
BEGIN
    IF NOT pg_has_role(session_user, 'lego_importer', 'MEMBER') THEN
        RAISE EXCEPTION
            'import.mark_set_manifest_component_missing requires lego_importer membership'
            USING ERRCODE = '42501';
    END IF;

    v_kind := upper(btrim(p_component_kind))::catalog.item_kind;

    SELECT ei.catalog_item_id
      INTO v_set_id
      FROM catalog.external_identifiers ei
      JOIN reference.external_sources es ON es.source_id = ei.source_id
      JOIN catalog.items ci ON ci.catalog_item_id = ei.catalog_item_id
     WHERE es.source_code = 'REBRICKABLE'
       AND ei.entity_namespace = 'SET'
       AND ci.item_kind = 'SET'::catalog.item_kind
       AND (
           ei.external_id = btrim(p_set_num)
           OR ei.external_id = btrim(p_set_num) || '-1'
           OR split_part(ei.external_id, '-', 1) = btrim(p_set_num)
       )
     ORDER BY
       CASE WHEN ei.external_id = btrim(p_set_num) || '-1' THEN 0 ELSE 1 END
     LIMIT 1;

    UPDATE definition.set_manifest_components
       SET source_present = false,
           last_seen_at = clock_timestamp()
     WHERE set_catalog_item_id = v_set_id
       AND component_kind = v_kind
       AND source_code = upper(btrim(p_source_code))
       AND external_id = btrim(p_external_id);

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'rows_updated', v_count,
        'set_catalog_item_id', v_set_id,
        'component_kind', v_kind::text,
        'source_code', upper(btrim(p_source_code)),
        'external_id', btrim(p_external_id)
    );
END;
$function$;


REVOKE ALL ON FUNCTION import.upsert_set_manifest_component(
    text,text,text,text,text,text,integer,jsonb
) FROM PUBLIC;

REVOKE ALL ON FUNCTION import.mark_set_manifest_component_missing(
    text,text,text,text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION import.upsert_set_manifest_component(
    text,text,text,text,text,text,integer,jsonb
) TO lego_importer;

GRANT EXECUTE ON FUNCTION import.mark_set_manifest_component_missing(
    text,text,text,text
) TO lego_importer;


/* -------------------------------------------------------------------------- */
/* Automatic Rebrickable sticker-sheet promotion                              */
/* -------------------------------------------------------------------------- */

CREATE OR REPLACE FUNCTION import.reconcile_rebrickable_sticker_sheets(
    p_source_run_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_source_id smallint;
    v_run_status text;
    v_record record;
    v_sticker_item_id uuid;
    v_existing_kind catalog.item_kind;
    v_created_items bigint := 0;
    v_sticker_types bigint := 0;
    v_manifest_rows bigint := 0;
BEGIN
    IF NOT pg_has_role(session_user, 'lego_importer', 'MEMBER') THEN
        RAISE EXCEPTION
            'import.reconcile_rebrickable_sticker_sheets requires lego_importer membership'
            USING ERRCODE = '42501';
    END IF;

    IF p_source_run_id IS NULL THEN
        RAISE EXCEPTION 'p_source_run_id is required'
            USING ERRCODE = '22023';
    END IF;

    SELECT sr.source_id, sr.status::text
      INTO v_source_id, v_run_status
      FROM import.source_runs sr
      JOIN reference.external_sources es
        ON es.source_id = sr.source_id
     WHERE sr.source_run_id = p_source_run_id
       AND es.source_code = 'REBRICKABLE';

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Rebrickable source run % does not exist',
            p_source_run_id
            USING ERRCODE = '22023';
    END IF;

    IF v_run_status NOT IN ('VALIDATING','FINALIZING','COMPLETED') THEN
        RAISE EXCEPTION
            'Rebrickable inventory run % is not reconcilable; status=%',
            p_source_run_id, v_run_status
            USING ERRCODE = '55000';
    END IF;

    IF (
        SELECT count(*)
        FROM import.source_run_datasets d
        WHERE d.source_run_id = p_source_run_id
          AND d.dataset_name IN ('inventories','inventory_parts')
          AND d.status::text IN ('VALIDATED','COMPLETED')
    ) <> 2 THEN
        RAISE EXCEPTION
            'source run % does not contain validated/completed inventories and inventory_parts',
            p_source_run_id
            USING ERRCODE = '55000';
    END IF;

    PERFORM app.set_import_context(p_source_run_id);

    /*
     * Rebrickable carries sticker sheets through the PART / inventory_parts
     * datasets. BrickTrackr promotes parts whose imported part-category name
     * identifies them as sticker material into first-class STICKER_SHEET
     * catalog items.
     *
     * For a set with multiple source inventory versions, only the highest
     * imported version is treated as the current SET manifest.
     */
    CREATE TEMP TABLE bt_rb_sticker_manifest
    ON COMMIT DROP
    AS
    WITH ranked_inventory AS (
        SELECT
            inv.normalized_payload->>'inventory_id' AS inventory_id,
            inv.normalized_payload->>'set_num' AS set_num,
            (inv.normalized_payload->>'version')::integer AS inventory_version,
            row_number() OVER (
                PARTITION BY inv.normalized_payload->>'set_num'
                ORDER BY (inv.normalized_payload->>'version')::integer DESC,
                         inv.source_row_number DESC
            ) AS rn
        FROM import.source_stage_records inv
        WHERE inv.source_run_id = p_source_run_id
          AND inv.dataset_name = 'inventories'
          AND inv.entity_namespace = 'INVENTORY'
    ),
    sticker_rows AS (
        SELECT
            ri.set_num,
            ri.inventory_id,
            ri.inventory_version,
            ip.normalized_payload->>'part_num' AS part_num,
            p.design_name,
            sum((ip.normalized_payload->>'quantity')::integer)::integer AS quantity,
            bool_or((ip.normalized_payload->>'is_spare')::boolean) AS has_spare,
            max(ip.normalized_payload->>'img_url') AS image_url
        FROM ranked_inventory ri
        JOIN import.source_stage_records ip
          ON ip.source_run_id = p_source_run_id
         AND ip.dataset_name = 'inventory_parts'
         AND ip.entity_namespace = 'INVENTORY_PART'
         AND ip.normalized_payload->>'inventory_id' = ri.inventory_id
        JOIN catalog.external_identifiers pei
          ON pei.source_id = v_source_id
         AND pei.entity_namespace = 'PART'
         AND pei.external_id = ip.normalized_payload->>'part_num'
         AND pei.external_version IS NULL
         AND pei.source_present
        JOIN catalog.parts p
          ON p.catalog_item_id = pei.catalog_item_id
        JOIN reference.categories c
          ON c.category_id = p.category_id
        WHERE ri.rn = 1
          AND c.category_namespace = 'PART'
          AND lower(c.category_name) LIKE '%sticker%'
        GROUP BY
            ri.set_num,
            ri.inventory_id,
            ri.inventory_version,
            ip.normalized_payload->>'part_num',
            p.design_name
    )
    SELECT * FROM sticker_rows;

    /*
     * The inventory snapshot is authoritative for Rebrickable-backed sticker
     * manifest evidence. Rows found below are turned back on.
     */
    UPDATE definition.set_manifest_components
       SET source_present = false,
           last_seen_at = clock_timestamp()
     WHERE component_kind = 'STICKER_SHEET'::catalog.item_kind
       AND source_code = 'REBRICKABLE';

    FOR v_record IN
        SELECT DISTINCT part_num, design_name
        FROM bt_rb_sticker_manifest
        ORDER BY part_num
    LOOP
        v_sticker_item_id := NULL;
        v_existing_kind := NULL;

        SELECT ei.catalog_item_id, ci.item_kind
          INTO v_sticker_item_id, v_existing_kind
          FROM catalog.external_identifiers ei
          JOIN catalog.items ci
            ON ci.catalog_item_id = ei.catalog_item_id
         WHERE ei.source_id = v_source_id
           AND ei.entity_namespace = 'STICKER_SHEET'
           AND ei.external_id = v_record.part_num
           AND ei.external_version IS NULL
         ORDER BY ei.source_present DESC, ei.last_seen_at DESC
         LIMIT 1;

        IF v_sticker_item_id IS NOT NULL
           AND v_existing_kind <> 'STICKER_SHEET'::catalog.item_kind
        THEN
            RAISE EXCEPTION
                'Rebrickable sticker identity % points to catalog kind %',
                v_record.part_num, v_existing_kind
                USING ERRCODE = '23514';
        END IF;

        IF v_sticker_item_id IS NULL THEN
            v_sticker_item_id := app.uuid_v7();

            INSERT INTO catalog.items (
                catalog_item_id,
                item_kind,
                canonical_name,
                status
            )
            VALUES (
                v_sticker_item_id,
                'STICKER_SHEET'::catalog.item_kind,
                v_record.design_name,
                'ACTIVE'::catalog.item_status
            );

            INSERT INTO catalog.external_identifiers (
                source_id,
                entity_namespace,
                external_id,
                external_version,
                catalog_item_id,
                source_present,
                valid_from,
                first_seen_at,
                last_seen_at
            )
            VALUES (
                v_source_id,
                'STICKER_SHEET',
                v_record.part_num,
                NULL,
                v_sticker_item_id,
                true,
                CURRENT_DATE,
                clock_timestamp(),
                clock_timestamp()
            );

            v_created_items := v_created_items + 1;
        ELSE
            UPDATE catalog.items
               SET canonical_name = v_record.design_name
             WHERE catalog_item_id = v_sticker_item_id
               AND canonical_name IS DISTINCT FROM v_record.design_name;

            UPDATE catalog.external_identifiers
               SET source_present = true,
                   valid_to = NULL,
                   last_seen_at = clock_timestamp()
             WHERE source_id = v_source_id
               AND entity_namespace = 'STICKER_SHEET'
               AND external_id = v_record.part_num
               AND external_version IS NULL;
        END IF;

        INSERT INTO catalog.sticker_sheets (
            catalog_item_id,
            sheet_code,
            description
        )
        VALUES (
            v_sticker_item_id,
            v_record.part_num,
            v_record.design_name
        )
        ON CONFLICT (catalog_item_id)
        DO UPDATE SET
            sheet_code = EXCLUDED.sheet_code,
            description = EXCLUDED.description;

        v_sticker_types := v_sticker_types + 1;
    END LOOP;

    /*
     * Bind the promoted sticker catalog item to each SET manifest.
     */
    INSERT INTO definition.set_manifest_components (
        set_catalog_item_id,
        component_kind,
        component_catalog_item_id,
        source_code,
        external_id,
        display_name,
        source_url,
        quantity,
        source_present,
        source_payload,
        first_seen_at,
        last_seen_at
    )
    SELECT
        set_ei.catalog_item_id,
        'STICKER_SHEET'::catalog.item_kind,
        sticker_ei.catalog_item_id,
        'REBRICKABLE',
        sm.part_num,
        sm.design_name,
        sm.image_url,
        sm.quantity,
        true,
        jsonb_build_object(
            'source_run_id', p_source_run_id,
            'inventory_id', sm.inventory_id,
            'inventory_version', sm.inventory_version,
            'rebrickable_part_num', sm.part_num,
            'has_spare', sm.has_spare
        ),
        clock_timestamp(),
        clock_timestamp()
    FROM bt_rb_sticker_manifest sm
    JOIN catalog.external_identifiers set_ei
      ON set_ei.source_id = v_source_id
     AND set_ei.entity_namespace = 'SET'
     AND set_ei.external_id = sm.set_num
     AND set_ei.external_version IS NULL
     AND set_ei.source_present
    JOIN catalog.external_identifiers sticker_ei
      ON sticker_ei.source_id = v_source_id
     AND sticker_ei.entity_namespace = 'STICKER_SHEET'
     AND sticker_ei.external_id = sm.part_num
     AND sticker_ei.external_version IS NULL
     AND sticker_ei.source_present
    ON CONFLICT (
        set_catalog_item_id,
        component_kind,
        source_code,
        external_id
    )
    DO UPDATE SET
        component_catalog_item_id = EXCLUDED.component_catalog_item_id,
        display_name = EXCLUDED.display_name,
        source_url = EXCLUDED.source_url,
        quantity = EXCLUDED.quantity,
        source_present = true,
        source_payload = EXCLUDED.source_payload,
        last_seen_at = clock_timestamp();

    GET DIAGNOSTICS v_manifest_rows = ROW_COUNT;

    RETURN jsonb_build_object(
        'source_run_id', p_source_run_id,
        'sticker_sheet_types', v_sticker_types,
        'catalog_items_created', v_created_items,
        'set_manifest_rows_upserted', v_manifest_rows,
        'classification_rule', 'Rebrickable PART category name contains sticker'
    );
END;
$function$;

REVOKE ALL
ON FUNCTION import.reconcile_rebrickable_sticker_sheets(uuid)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION import.reconcile_rebrickable_sticker_sheets(uuid)
TO lego_importer;


SELECT pg_temp.bt_mark_completed('5000_function/5000_importer/5030_importer_set_manifest_enrichment.sql');
