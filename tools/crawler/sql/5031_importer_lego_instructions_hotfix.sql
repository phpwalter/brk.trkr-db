\set ON_ERROR_STOP on

/*
===============================================================================
 BrickTrackr LEGO instruction importer — parser v2 reconciliation overlay

 Requires the v1.7.x begin/complete/fail LEGO sync functions to already exist.

 Key correction:
 - LEGO instruction identity is now a LOGICAL BOOKLET ID:
     <set>:booklet:<n>-of-<m>
 - before reasserting a corrected set, all prior LEGO instruction manifest
   links for that set are soft-retired (source_present=false)
 - no catalog rows are hard-deleted
===============================================================================
*/

CREATE OR REPLACE FUNCTION import.reconcile_lego_instruction_batch(
    p_source_run_id uuid,
    p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_lego_source_id smallint;
    v_run_source_id smallint;
    v_run_status import.source_run_status;

    v_set jsonb;
    v_instruction jsonb;

    v_set_num integer;
    v_set_id uuid;

    v_instruction_id text;
    v_pdf_url text;
    v_label text;
    v_language text;
    v_booklet smallint;

    v_instruction_item_id uuid;
    v_existing_kind catalog.item_kind;
    v_canonical_name text;

    v_sets_seen integer := 0;
    v_sets_missing integer := 0;
    v_instructions_seen integer := 0;
    v_instructions_created integer := 0;
    v_instructions_updated integer := 0;
    v_manifest_links integer := 0;
    v_manifest_links_retired integer := 0;
    v_retired_this_set integer := 0;
BEGIN
    IF NOT pg_has_role(session_user, 'brktrkr_import', 'MEMBER') THEN
        RAISE EXCEPTION
            'import.reconcile_lego_instruction_batch requires brktrkr_import membership'
            USING ERRCODE = '42501';
    END IF;

    IF p_source_run_id IS NULL THEN
        RAISE EXCEPTION 'source_run_id is required'
            USING ERRCODE = '22004';
    END IF;

    IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'array' THEN
        RAISE EXCEPTION 'payload must be a JSON array'
            USING ERRCODE = '22023';
    END IF;

    SELECT es.source_id
      INTO v_lego_source_id
      FROM reference.external_sources es
     WHERE es.source_code = 'LEGO';

    SELECT sr.source_id, sr.status
      INTO v_run_source_id, v_run_status
      FROM import.source_runs sr
     WHERE sr.source_run_id = p_source_run_id
     FOR UPDATE;

    IF v_run_source_id IS NULL THEN
        RAISE EXCEPTION 'source run % does not exist', p_source_run_id
            USING ERRCODE = 'P0002';
    END IF;

    IF v_run_source_id <> v_lego_source_id THEN
        RAISE EXCEPTION 'source run % is not a LEGO run', p_source_run_id
            USING ERRCODE = '22023';
    END IF;

    IF v_run_status NOT IN (
        'STARTED'::import.source_run_status,
        'STAGING'::import.source_run_status,
        'VALIDATING'::import.source_run_status
    ) THEN
        RAISE EXCEPTION
            'source run % has invalid status % for reconciliation',
            p_source_run_id, v_run_status
            USING ERRCODE = '55000';
    END IF;

    UPDATE import.source_runs
       SET status = 'STAGING'::import.source_run_status
     WHERE source_run_id = p_source_run_id;

    PERFORM app.set_import_context(p_source_run_id);

    FOR v_set IN
        SELECT value
          FROM jsonb_array_elements(p_payload)
    LOOP
        v_sets_seen := v_sets_seen + 1;

        IF COALESCE(v_set->>'parser_version', '') <> '2.0-visible-booklets' THEN
            CONTINUE;
        END IF;

        IF COALESCE(v_set->>'set_number', '') !~ '^[0-9]{3,5}$' THEN
            CONTINUE;
        END IF;

        v_set_num := (v_set->>'set_number')::integer;

        SELECT ci.catalog_item_id
          INTO v_set_id
          FROM catalog.sets cs
          JOIN catalog.items ci
            ON ci.catalog_item_id = cs.catalog_item_id
         WHERE cs.lego_set_id = v_set_num
           AND ci.item_kind = 'SET'::catalog.item_kind
           AND ci.status <> 'ARCHIVED'::catalog.item_status
         ORDER BY
           CASE WHEN ci.status = 'ACTIVE'::catalog.item_status THEN 0 ELSE 1 END,
           ci.created_at
         LIMIT 1;

        IF v_set_id IS NULL THEN
            v_sets_missing := v_sets_missing + 1;
            CONTINUE;
        END IF;

        /*
         * Corrected parser-v2 data is authoritative for LEGO instruction
         * relationships on this SET. Soft-retire prior links, then reassert
         * only the visible logical booklet list.
         */
        UPDATE definition.set_manifest_components smc
           SET source_present = false,
               last_seen_at = clock_timestamp(),
               source_payload =
                   COALESCE(smc.source_payload, '{}'::jsonb)
                   || jsonb_build_object(
                        'retired_reason',
                        'SUPERSEDED_BY_VISIBLE_BOOKLET_RECONCILIATION',
                        'retired_at',
                        clock_timestamp()
                      )
         WHERE smc.set_catalog_item_id = v_set_id
           AND smc.component_kind = 'INSTRUCTIONS'::catalog.item_kind
           AND smc.source_code = 'LEGO'
           AND smc.source_present = true;

        GET DIAGNOSTICS v_retired_this_set = ROW_COUNT;
        v_manifest_links_retired :=
            v_manifest_links_retired + v_retired_this_set;

        IF jsonb_typeof(COALESCE(v_set->'instructions', '[]'::jsonb)) <> 'array' THEN
            CONTINUE;
        END IF;

        FOR v_instruction IN
            SELECT value
              FROM jsonb_array_elements(
                  COALESCE(v_set->'instructions', '[]'::jsonb)
              )
        LOOP
            v_instruction_id :=
                NULLIF(btrim(v_instruction->>'instruction_id'), '');
            v_pdf_url :=
                NULLIF(btrim(v_instruction->>'pdf_url'), '');
            v_label :=
                NULLIF(btrim(v_instruction->>'label'), '');
            v_language :=
                NULLIF(btrim(v_instruction->>'language'), '');

            IF v_instruction_id IS NULL OR v_pdf_url IS NULL THEN
                CONTINUE;
            END IF;

            /*
             * Enforce the logical parser-v2 identity shape. This prevents a
             * legacy raw PDF document ID from being promoted accidentally.
             */
            IF v_instruction_id !~
               '^[0-9]{3,5}:booklet:[0-9]+-of-[0-9]+$'
            THEN
                CONTINUE;
            END IF;

            v_instructions_seen := v_instructions_seen + 1;

            BEGIN
                v_booklet :=
                    NULLIF(v_instruction->>'booklet_number', '')::smallint;
            EXCEPTION
                WHEN numeric_value_out_of_range
                  OR invalid_text_representation
                THEN
                    v_booklet := NULL;
            END;

            v_instruction_item_id := NULL;
            v_existing_kind := NULL;

            SELECT ei.catalog_item_id, ci.item_kind
              INTO v_instruction_item_id, v_existing_kind
              FROM catalog.external_identifiers ei
              JOIN catalog.items ci
                ON ci.catalog_item_id = ei.catalog_item_id
             WHERE ei.source_id = v_lego_source_id
               AND ei.entity_namespace = 'INSTRUCTIONS'
               AND ei.external_id = v_instruction_id
               AND ei.external_version IS NULL
             ORDER BY ei.source_present DESC, ei.last_seen_at DESC
             LIMIT 1
             FOR UPDATE OF ei;

            IF v_instruction_item_id IS NOT NULL
               AND v_existing_kind <> 'INSTRUCTIONS'::catalog.item_kind
            THEN
                RAISE EXCEPTION
                    'LEGO instruction id % maps to catalog kind %',
                    v_instruction_id, v_existing_kind
                    USING ERRCODE = '23514';
            END IF;

            IF v_instruction_item_id IS NULL THEN
                v_canonical_name := format(
                    'LEGO Instructions %s - Booklet %s/%s',
                    v_set_num,
                    COALESCE(v_instruction->>'booklet_number', '?'),
                    COALESCE(v_instruction->>'booklet_count', '?')
                );

                INSERT INTO catalog.items (
                    item_kind,
                    canonical_name,
                    status
                )
                VALUES (
                    'INSTRUCTIONS'::catalog.item_kind,
                    v_canonical_name,
                    'ACTIVE'::catalog.item_status
                )
                RETURNING catalog_item_id
                  INTO v_instruction_item_id;

                INSERT INTO catalog.instructions (
                    catalog_item_id,
                    booklet_number,
                    language_code,
                    document_code
                )
                VALUES (
                    v_instruction_item_id,
                    v_booklet,
                    v_language,
                    NULLIF(v_instruction->>'document_id', '')
                );

                INSERT INTO catalog.external_identifiers (
                    source_id,
                    entity_namespace,
                    external_id,
                    external_version,
                    catalog_item_id,
                    source_present,
                    first_seen_at,
                    last_seen_at
                )
                VALUES (
                    v_lego_source_id,
                    'INSTRUCTIONS',
                    v_instruction_id,
                    NULL,
                    v_instruction_item_id,
                    true,
                    clock_timestamp(),
                    clock_timestamp()
                );

                v_instructions_created := v_instructions_created + 1;
            ELSE
                UPDATE catalog.external_identifiers
                   SET source_present = true,
                       last_seen_at = clock_timestamp()
                 WHERE source_id = v_lego_source_id
                   AND entity_namespace = 'INSTRUCTIONS'
                   AND external_id = v_instruction_id
                   AND external_version IS NULL
                   AND catalog_item_id = v_instruction_item_id;

                INSERT INTO catalog.instructions (
                    catalog_item_id,
                    booklet_number,
                    language_code,
                    document_code
                )
                VALUES (
                    v_instruction_item_id,
                    v_booklet,
                    v_language,
                    NULLIF(v_instruction->>'document_id', '')
                )
                ON CONFLICT (catalog_item_id)
                DO UPDATE
                   SET booklet_number = COALESCE(
                           EXCLUDED.booklet_number,
                           catalog.instructions.booklet_number
                       ),
                       language_code = COALESCE(
                           EXCLUDED.language_code,
                           catalog.instructions.language_code
                       ),
                       document_code = COALESCE(
                           EXCLUDED.document_code,
                           catalog.instructions.document_code
                       );

                v_instructions_updated := v_instructions_updated + 1;
            END IF;

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
            VALUES (
                v_set_id,
                'INSTRUCTIONS'::catalog.item_kind,
                v_instruction_item_id,
                'LEGO',
                v_instruction_id,
                v_label,
                v_pdf_url,
                1,
                true,
                jsonb_strip_nulls(
                    jsonb_build_object(
                        'parser_version', v_set->>'parser_version',
                        'set_number', v_set->>'set_number',
                        'release_year', v_set->'release_year',
                        'lego_url', v_set->>'lego_url',
                        'checked_at', v_set->>'checked_at',
                        'instruction_id', v_instruction_id,
                        'booklet_number',
                            v_instruction->'booklet_number',
                        'booklet_count',
                            v_instruction->'booklet_count',
                        'document_id',
                            v_instruction->>'document_id',
                        'pdf_url', v_pdf_url,
                        'pdf_variants',
                            v_instruction->'pdf_variants',
                        'language', v_language
                    )
                ),
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
               SET component_catalog_item_id =
                       EXCLUDED.component_catalog_item_id,
                   display_name = EXCLUDED.display_name,
                   source_url = EXCLUDED.source_url,
                   quantity = 1,
                   source_present = true,
                   source_payload = EXCLUDED.source_payload,
                   last_seen_at = clock_timestamp();

            v_manifest_links := v_manifest_links + 1;
        END LOOP;
    END LOOP;

    RETURN jsonb_build_object(
        'sets_seen', v_sets_seen,
        'sets_missing', v_sets_missing,
        'instructions_seen', v_instructions_seen,
        'instructions_created', v_instructions_created,
        'instructions_updated', v_instructions_updated,
        'manifest_links_upserted', v_manifest_links,
        'manifest_links_retired', v_manifest_links_retired
    );
END;
$function$;

REVOKE ALL
ON FUNCTION import.reconcile_lego_instruction_batch(uuid,jsonb)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION import.reconcile_lego_instruction_batch(uuid,jsonb)
TO brktrkr_import;

\echo '[PASS] parser-v2 LEGO instruction reconciler installed'
