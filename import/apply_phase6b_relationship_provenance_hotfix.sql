/*
===============================================================================
 BrickTrackr Rebrickable Phase 6B - relationship provenance + reconcile
===============================================================================

 Live hotfix / pre-canonicalization artifact.

 Purpose:
   1. Preserve every Rebrickable relationship row in a durable source-aware
      relationship provenance table.
   2. Materialize only semantically exact canonical mappings.
   3. Quarantine self-links which catalog.item_relationships forbids.

 Exact canonical mapping in v1:
   Rebrickable A -> catalog.relationship_kind = ALTERNATE

 Intentionally NOT mapped:
   B, M, P, R, T

 These remain durable source evidence with reconciliation_status = UNMAPPED.

 Runtime caller:
   lego_importer via SECURITY DEFINER function only.
===============================================================================
*/

\set ON_ERROR_STOP on

BEGIN;

CREATE TABLE IF NOT EXISTS catalog.external_item_relationships (
    external_item_relationship_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),

    source_id smallint NOT NULL
        REFERENCES reference.external_sources(source_id)
        ON DELETE RESTRICT,

    entity_namespace text NOT NULL
        DEFAULT 'PART_RELATIONSHIP',

    external_relationship_key text NOT NULL,

    source_relationship_code text NOT NULL,

    child_external_id text NOT NULL,
    parent_external_id text NOT NULL,

    child_catalog_item_id uuid
        REFERENCES catalog.items(catalog_item_id)
        ON DELETE RESTRICT,

    parent_catalog_item_id uuid
        REFERENCES catalog.items(catalog_item_id)
        ON DELETE RESTRICT,

    catalog_item_relationship_id uuid
        REFERENCES catalog.item_relationships(catalog_item_relationship_id)
        ON DELETE SET NULL,

    reconciliation_status text NOT NULL,
    reconciliation_note text,

    source_present boolean NOT NULL DEFAULT true,

    first_seen_run_id uuid NOT NULL
        REFERENCES import.source_runs(source_run_id)
        ON DELETE RESTRICT,

    last_seen_run_id uuid NOT NULL
        REFERENCES import.source_runs(source_run_id)
        ON DELETE RESTRICT,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_external_item_relationships_namespace
        CHECK (btrim(entity_namespace) <> ''),

    CONSTRAINT ck_external_item_relationships_key
        CHECK (btrim(external_relationship_key) <> ''),

    CONSTRAINT ck_external_item_relationships_code
        CHECK (btrim(source_relationship_code) <> ''),

    CONSTRAINT ck_external_item_relationships_child_external
        CHECK (btrim(child_external_id) <> ''),

    CONSTRAINT ck_external_item_relationships_parent_external
        CHECK (btrim(parent_external_id) <> ''),

    CONSTRAINT ck_external_item_relationships_status
        CHECK (reconciliation_status IN ('MAPPED', 'UNMAPPED', 'QUARANTINED')),

    CONSTRAINT uq_external_item_relationships_source_key
        UNIQUE (source_id, entity_namespace, external_relationship_key)
);

CREATE INDEX IF NOT EXISTS ix_external_item_relationships_source_present
    ON catalog.external_item_relationships (
        source_id,
        entity_namespace,
        source_present
    );

CREATE INDEX IF NOT EXISTS ix_external_item_relationships_child
    ON catalog.external_item_relationships (child_catalog_item_id)
    WHERE child_catalog_item_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_external_item_relationships_parent
    ON catalog.external_item_relationships (parent_catalog_item_id)
    WHERE parent_catalog_item_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_external_item_relationships_canonical
    ON catalog.external_item_relationships (catalog_item_relationship_id)
    WHERE catalog_item_relationship_id IS NOT NULL;

ALTER TABLE catalog.external_item_relationships OWNER TO lego_owner;

REVOKE ALL ON TABLE catalog.external_item_relationships FROM PUBLIC;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_api;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_app;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_importer;

CREATE OR REPLACE FUNCTION import.phase6b_reconcile(
    p_source_run_id uuid
)
RETURNS TABLE (
    staged_rows bigint,
    provenance_rows bigint,
    mapped_rows bigint,
    unmapped_rows bigint,
    quarantined_rows bigint,
    canonical_alternate_rows bigint,
    source_missing_rows bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
    v_source_id smallint;
    v_stage_count bigint;
    v_provenance_count bigint;
    v_mapped bigint;
    v_unmapped bigint;
    v_quarantined bigint;
    v_canonical bigint;
    v_missing bigint;
BEGIN
    IF p_source_run_id IS NULL THEN
        RAISE EXCEPTION 'p_source_run_id must not be NULL';
    END IF;

    PERFORM app.set_import_context(p_source_run_id);

    SELECT sr.source_id
      INTO v_source_id
      FROM import.source_runs sr
     WHERE sr.source_run_id = p_source_run_id
     FOR UPDATE;

    IF v_source_id IS NULL THEN
        RAISE EXCEPTION 'unknown source_run_id: %', p_source_run_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM import.source_run_datasets d
         WHERE d.source_run_id = p_source_run_id
           AND d.dataset_name = 'part_relationships'
           AND d.status::text = 'VALIDATED'
    ) THEN
        RAISE EXCEPTION
            'source run % does not have VALIDATED part_relationships dataset',
            p_source_run_id;
    END IF;

    SELECT count(*)::bigint
      INTO v_stage_count
      FROM import.source_stage_records s
     WHERE s.source_run_id = p_source_run_id
       AND s.dataset_name = 'part_relationships'
       AND s.entity_namespace = 'PART_RELATIONSHIP';

    IF v_stage_count = 0 THEN
        RAISE EXCEPTION 'no staged part relationships for source run %',
            p_source_run_id;
    END IF;

    /*
     * Resolve child/parent source IDs and upsert durable source provenance.
     *
     * external_relationship_key is source-native and deterministic. Exact
     * triple duplicates were already rejected by Phase 6A.
     */
    WITH resolved AS (
        SELECT
            s.source_row_number,
            s.normalized_payload ->> 'rel_type' AS rel_type,
            s.normalized_payload ->> 'child_part_num' AS child_part_num,
            s.normalized_payload ->> 'parent_part_num' AS parent_part_num,
            ce.catalog_item_id AS child_catalog_item_id,
            pe.catalog_item_id AS parent_catalog_item_id,
            (
                (s.normalized_payload ->> 'child_part_num')
                =
                (s.normalized_payload ->> 'parent_part_num')
            ) AS is_self_link
        FROM import.source_stage_records s
        JOIN catalog.external_identifiers ce
          ON ce.source_id = v_source_id
         AND ce.entity_namespace = 'PART'
         AND ce.external_id = s.normalized_payload ->> 'child_part_num'
         AND ce.source_present
         AND ce.catalog_item_id IS NOT NULL
        JOIN catalog.external_identifiers pe
          ON pe.source_id = v_source_id
         AND pe.entity_namespace = 'PART'
         AND pe.external_id = s.normalized_payload ->> 'parent_part_num'
         AND pe.source_present
         AND pe.catalog_item_id IS NOT NULL
        WHERE s.source_run_id = p_source_run_id
          AND s.dataset_name = 'part_relationships'
          AND s.entity_namespace = 'PART_RELATIONSHIP'
    )
    INSERT INTO catalog.external_item_relationships (
        source_id,
        entity_namespace,
        external_relationship_key,
        source_relationship_code,
        child_external_id,
        parent_external_id,
        child_catalog_item_id,
        parent_catalog_item_id,
        catalog_item_relationship_id,
        reconciliation_status,
        reconciliation_note,
        source_present,
        first_seen_run_id,
        last_seen_run_id,
        created_at,
        updated_at
    )
    SELECT
        v_source_id,
        'PART_RELATIONSHIP',
        r.rel_type || E'\x1f' || r.child_part_num || E'\x1f' || r.parent_part_num,
        r.rel_type,
        r.child_part_num,
        r.parent_part_num,
        r.child_catalog_item_id,
        r.parent_catalog_item_id,
        NULL,
        CASE
            WHEN r.is_self_link THEN 'QUARANTINED'
            WHEN r.rel_type = 'A' THEN 'MAPPED'
            ELSE 'UNMAPPED'
        END,
        CASE
            WHEN r.is_self_link
                THEN 'Source self-link preserved; canonical table forbids self relationships'
            WHEN r.rel_type = 'A'
                THEN 'Rebrickable A maps exactly to catalog.relationship_kind ALTERNATE'
            ELSE
                'No lossless BrickTrackr relationship_kind mapping defined for this source code'
        END,
        true,
        p_source_run_id,
        p_source_run_id,
        now(),
        now()
    FROM resolved r
    ON CONFLICT (source_id, entity_namespace, external_relationship_key)
    DO UPDATE SET
        source_relationship_code = EXCLUDED.source_relationship_code,
        child_external_id = EXCLUDED.child_external_id,
        parent_external_id = EXCLUDED.parent_external_id,
        child_catalog_item_id = EXCLUDED.child_catalog_item_id,
        parent_catalog_item_id = EXCLUDED.parent_catalog_item_id,
        catalog_item_relationship_id = NULL,
        reconciliation_status = EXCLUDED.reconciliation_status,
        reconciliation_note = EXCLUDED.reconciliation_note,
        source_present = true,
        last_seen_run_id = p_source_run_id,
        updated_at = now();

    GET DIAGNOSTICS v_provenance_count = ROW_COUNT;

    /*
     * Full authoritative snapshot semantics for durable source provenance.
     * Canonical relationships are NOT deleted here because they may have
     * additional non-Rebrickable authority; source provenance owns only the
     * external_item_relationships row.
     */
    UPDATE catalog.external_item_relationships e
       SET source_present = false,
           last_seen_run_id = p_source_run_id,
           updated_at = now(),
           reconciliation_note =
               CASE
                   WHEN e.reconciliation_status = 'MAPPED'
                       THEN 'SOURCE_MISSING in latest authoritative Rebrickable snapshot'
                   ELSE e.reconciliation_note
               END
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND NOT EXISTS (
            SELECT 1
              FROM import.source_stage_records s
             WHERE s.source_run_id = p_source_run_id
               AND s.dataset_name = 'part_relationships'
               AND s.entity_namespace = 'PART_RELATIONSHIP'
               AND (
                    (s.normalized_payload ->> 'rel_type')
                    || E'\x1f'
                    || (s.normalized_payload ->> 'child_part_num')
                    || E'\x1f'
                    || (s.normalized_payload ->> 'parent_part_num')
               ) = e.external_relationship_key
       );

    GET DIAGNOSTICS v_missing = ROW_COUNT;

    /*
     * Materialize the one exact semantic mapping:
     * Rebrickable A -> ALTERNATE.
     *
     * Direction is preserved as source child -> parent. ALTERNATE is semantic,
     * not structural; the provenance table retains the original source IDs.
     */
    INSERT INTO catalog.item_relationships (
        from_catalog_item_id,
        to_catalog_item_id,
        relationship_kind
    )
    SELECT
        e.child_catalog_item_id,
        e.parent_catalog_item_id,
        'ALTERNATE'::catalog.relationship_kind
    FROM catalog.external_item_relationships e
    WHERE e.source_id = v_source_id
      AND e.entity_namespace = 'PART_RELATIONSHIP'
      AND e.source_present
      AND e.source_relationship_code = 'A'
      AND e.reconciliation_status = 'MAPPED'
      AND e.child_catalog_item_id IS NOT NULL
      AND e.parent_catalog_item_id IS NOT NULL
      AND e.child_catalog_item_id <> e.parent_catalog_item_id
    ON CONFLICT (
        from_catalog_item_id,
        to_catalog_item_id,
        relationship_kind
    )
    DO NOTHING;

    /*
     * Attach provenance to the canonical ALTERNATE row, including rows that
     * existed before this import.
     */
    UPDATE catalog.external_item_relationships e
       SET catalog_item_relationship_id = r.catalog_item_relationship_id,
           updated_at = now()
      FROM catalog.item_relationships r
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND e.source_relationship_code = 'A'
       AND e.reconciliation_status = 'MAPPED'
       AND r.from_catalog_item_id = e.child_catalog_item_id
       AND r.to_catalog_item_id = e.parent_catalog_item_id
       AND r.relationship_kind = 'ALTERNATE'::catalog.relationship_kind;

    SELECT count(*)::bigint
      INTO v_mapped
      FROM catalog.external_item_relationships e
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND e.last_seen_run_id = p_source_run_id
       AND e.reconciliation_status = 'MAPPED';

    SELECT count(*)::bigint
      INTO v_unmapped
      FROM catalog.external_item_relationships e
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND e.last_seen_run_id = p_source_run_id
       AND e.reconciliation_status = 'UNMAPPED';

    SELECT count(*)::bigint
      INTO v_quarantined
      FROM catalog.external_item_relationships e
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND e.last_seen_run_id = p_source_run_id
       AND e.reconciliation_status = 'QUARANTINED';

    SELECT count(*)::bigint
      INTO v_canonical
      FROM catalog.external_item_relationships e
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND e.last_seen_run_id = p_source_run_id
       AND e.source_relationship_code = 'A'
       AND e.reconciliation_status = 'MAPPED'
       AND e.catalog_item_relationship_id IS NOT NULL;

    IF (v_mapped + v_unmapped + v_quarantined) <> v_stage_count THEN
        RAISE EXCEPTION
            'Phase 6B reconciliation count mismatch: staged %, mapped %, unmapped %, quarantined %',
            v_stage_count, v_mapped, v_unmapped, v_quarantined;
    END IF;

    IF v_canonical <> v_mapped THEN
        RAISE EXCEPTION
            'Phase 6B canonical ALTERNATE linkage mismatch: mapped %, linked %',
            v_mapped, v_canonical;
    END IF;

    RETURN QUERY
    SELECT
        v_stage_count,
        v_provenance_count,
        v_mapped,
        v_unmapped,
        v_quarantined,
        v_canonical,
        v_missing;
END
$function$;

ALTER FUNCTION import.phase6b_reconcile(uuid) OWNER TO lego_owner;

REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM lego_api;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM lego_app;
GRANT EXECUTE ON FUNCTION import.phase6b_reconcile(uuid) TO lego_importer;

COMMIT;

\echo '[PASS] Phase 6B relationship provenance/reconcile hotfix installed.'
