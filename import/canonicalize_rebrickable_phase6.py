#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

TARGET_1016 = '1000_function/1016_rebrickable_catalog_reconcile.sql'
MARKER = '-- BRICKTRACKR_PHASE6_CANONICAL_RELATIONSHIPS_V1'
FUNC_MARKER = '-- BRICKTRACKR_PHASE6B_RECONCILE_V1'
GRANT_MARKER = '-- BRICKTRACKR_PHASE6_GRANTS_V1'

TABLE_DDL = r'''
-- BRICKTRACKR_PHASE6_CANONICAL_RELATIONSHIPS_V1
CREATE TABLE catalog.external_item_relationships (
    external_item_relationship_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    source_id smallint NOT NULL
        REFERENCES reference.external_sources(source_id) ON DELETE RESTRICT,
    entity_namespace text NOT NULL DEFAULT 'PART_RELATIONSHIP',
    external_relationship_key text NOT NULL,
    source_relationship_code text NOT NULL,
    child_external_id text NOT NULL,
    parent_external_id text NOT NULL,
    child_catalog_item_id uuid
        REFERENCES catalog.items(catalog_item_id) ON DELETE RESTRICT,
    parent_catalog_item_id uuid
        REFERENCES catalog.items(catalog_item_id) ON DELETE RESTRICT,
    catalog_item_relationship_id uuid
        REFERENCES catalog.item_relationships(catalog_item_relationship_id) ON DELETE SET NULL,
    reconciliation_status text NOT NULL,
    reconciliation_note text,
    source_present boolean NOT NULL DEFAULT true,
    first_seen_run_id uuid NOT NULL
        REFERENCES import.source_runs(source_run_id) ON DELETE RESTRICT,
    last_seen_run_id uuid NOT NULL
        REFERENCES import.source_runs(source_run_id) ON DELETE RESTRICT,
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

CREATE INDEX ix_external_item_relationships_source_present
    ON catalog.external_item_relationships (source_id, entity_namespace, source_present);

CREATE INDEX ix_external_item_relationships_child
    ON catalog.external_item_relationships (child_catalog_item_id)
    WHERE child_catalog_item_id IS NOT NULL;

CREATE INDEX ix_external_item_relationships_parent
    ON catalog.external_item_relationships (parent_catalog_item_id)
    WHERE parent_catalog_item_id IS NOT NULL;

CREATE INDEX ix_external_item_relationships_canonical
    ON catalog.external_item_relationships (catalog_item_relationship_id)
    WHERE catalog_item_relationship_id IS NOT NULL;
'''

FUNC_DDL = r'''
-- BRICKTRACKR_PHASE6B_RECONCILE_V1
CREATE OR REPLACE FUNCTION import.phase6b_reconcile(p_source_run_id uuid)
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
        RAISE EXCEPTION 'no staged part relationships for source run %', p_source_run_id;
    END IF;

    WITH resolved AS (
        SELECT
            s.normalized_payload ->> 'rel_type' AS rel_type,
            s.normalized_payload ->> 'child_part_num' AS child_part_num,
            s.normalized_payload ->> 'parent_part_num' AS parent_part_num,
            ce.catalog_item_id AS child_catalog_item_id,
            pe.catalog_item_id AS parent_catalog_item_id,
            ((s.normalized_payload ->> 'child_part_num') =
             (s.normalized_payload ->> 'parent_part_num')) AS is_self_link
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
        source_id, entity_namespace, external_relationship_key,
        source_relationship_code, child_external_id, parent_external_id,
        child_catalog_item_id, parent_catalog_item_id,
        catalog_item_relationship_id, reconciliation_status,
        reconciliation_note, source_present, first_seen_run_id,
        last_seen_run_id, created_at, updated_at
    )
    SELECT
        v_source_id,
        'PART_RELATIONSHIP',
        r.rel_type || E'\\x1f' || r.child_part_num || E'\\x1f' || r.parent_part_num,
        r.rel_type, r.child_part_num, r.parent_part_num,
        r.child_catalog_item_id, r.parent_catalog_item_id,
        NULL,
        CASE
            WHEN r.is_self_link THEN 'QUARANTINED'
            WHEN r.rel_type = 'A' THEN 'MAPPED'
            ELSE 'UNMAPPED'
        END,
        CASE
            WHEN r.is_self_link THEN
                'Source self-link preserved; canonical table forbids self relationships'
            WHEN r.rel_type = 'A' THEN
                'Rebrickable A maps exactly to catalog.relationship_kind ALTERNATE'
            ELSE
                'No lossless BrickTrackr relationship_kind mapping defined for this source code'
        END,
        true, p_source_run_id, p_source_run_id, now(), now()
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

    UPDATE catalog.external_item_relationships e
       SET source_present = false,
           last_seen_run_id = p_source_run_id,
           updated_at = now(),
           reconciliation_note = CASE
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
               AND ((s.normalized_payload ->> 'rel_type') || E'\\x1f' ||
                    (s.normalized_payload ->> 'child_part_num') || E'\\x1f' ||
                    (s.normalized_payload ->> 'parent_part_num')) = e.external_relationship_key
       );

    GET DIAGNOSTICS v_missing = ROW_COUNT;

    INSERT INTO catalog.item_relationships (
        from_catalog_item_id, to_catalog_item_id, relationship_kind
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
    ON CONFLICT (from_catalog_item_id, to_catalog_item_id, relationship_kind)
    DO NOTHING;

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

    SELECT count(*)::bigint INTO v_mapped
      FROM catalog.external_item_relationships e
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND e.last_seen_run_id = p_source_run_id
       AND e.reconciliation_status = 'MAPPED';

    SELECT count(*)::bigint INTO v_unmapped
      FROM catalog.external_item_relationships e
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND e.last_seen_run_id = p_source_run_id
       AND e.reconciliation_status = 'UNMAPPED';

    SELECT count(*)::bigint INTO v_quarantined
      FROM catalog.external_item_relationships e
     WHERE e.source_id = v_source_id
       AND e.entity_namespace = 'PART_RELATIONSHIP'
       AND e.source_present
       AND e.last_seen_run_id = p_source_run_id
       AND e.reconciliation_status = 'QUARANTINED';

    SELECT count(*)::bigint INTO v_canonical
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

    RETURN QUERY SELECT
        v_stage_count, v_provenance_count, v_mapped, v_unmapped,
        v_quarantined, v_canonical, v_missing;
END
$function$;
'''

GRANTS_DDL = r'''
-- BRICKTRACKR_PHASE6_GRANTS_V1
ALTER TABLE catalog.external_item_relationships OWNER TO lego_owner;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM PUBLIC;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_api;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_app;
REVOKE ALL ON TABLE catalog.external_item_relationships FROM lego_importer;

ALTER FUNCTION import.phase6b_reconcile(uuid) OWNER TO lego_owner;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM lego_api;
REVOKE ALL ON FUNCTION import.phase6b_reconcile(uuid) FROM lego_app;
GRANT EXECUTE ON FUNCTION import.phase6b_reconcile(uuid) TO lego_importer;

GRANT EXECUTE ON FUNCTION app.set_import_context(uuid) TO lego_owner;
'''

def read(p: Path) -> str:
    return p.read_text(encoding='utf-8-sig').replace('\r\n','\n').replace('\r','\n')

def write(p: Path, s: str):
    p.write_text(s, encoding='utf-8', newline='\n')

def find_file_containing(root: Path, needle: str, exclude=()):
    hits = []
    for p in root.rglob('*.sql'):
        rel = p.relative_to(root).as_posix()
        if rel in exclude:
            continue
        try:
            t = read(p)
        except Exception:
            continue
        if needle.lower() in t.lower():
            hits.append(p)
    if len(hits) != 1:
        raise RuntimeError(
            f"Expected exactly one SQL file containing {needle!r}; "
            f"found {len(hits)}: {[str(x) for x in hits]}"
        )
    return hits[0]

def inject_before_mark_completed(text: str, rel: str, block: str) -> str:
    pattern = re.compile(
        r"(?m)^SELECT\s+pg_temp\.bt_mark_completed\(\s*['\"]"
        + re.escape(rel)
        + r"['\"]\s*\)\s*;\s*$",
        re.I,
    )
    m = pattern.search(text)
    if not m:
        raise RuntimeError(f'bt_mark_completed not found in {rel}')
    return text[:m.start()] + '\n' + block.strip() + '\n\n' + text[m.start():]

def find_manifest(root: Path):
    hits = []
    for p in root.rglob('*.json'):
        try:
            obj = json.loads(read(p))
        except Exception:
            continue
        if TARGET_1016 in json.dumps(obj):
            hits.append((p, obj))
    if len(hits) != 1:
        raise RuntimeError(f'Expected one dependency manifest containing 1016; found {len(hits)}')
    return hits[0]

def find_entry(obj, target):
    hits = []
    def walk(x):
        if isinstance(x, dict):
            path = None
            for k in ('path','file','sql_file','filename'):
                if isinstance(x.get(k), str):
                    path = x[k].replace('\\','/')
                    break
            if path and path.endswith(target):
                hits.append(x)
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(obj)
    if len(hits) != 1:
        raise RuntimeError(f'Expected one manifest entry for {target}; found {len(hits)}')
    return hits[0]

def dep_field(entry):
    for k in ('depends_on','dependencies','dependsOn'):
        if k in entry:
            return k
    raise RuntimeError('manifest entry has no dependency field')

def patch_1016_contract(text: str, manifest_obj, table_rel: str):
    entry = find_entry(manifest_obj, TARGET_1016)
    key = dep_field(entry)
    deps = list(entry[key])
    if table_rel not in deps:
        deps.append(table_rel)
    entry[key] = deps

    lines = text.splitlines()
    dep_i = None
    boundary_i = None
    for i, line in enumerate(lines):
        if re.match(r'^\s*Depends On:\s*', line, re.I):
            dep_i = i
            break
    if dep_i is None:
        raise RuntimeError('1016 Depends On header not found')

    for j in range(dep_i + 1, len(lines)):
        if re.match(
            r'^\s*(Creates:|Purpose:|Key Rules:|Validation:|Notes:|Seed Data:)',
            lines[j],
            re.I,
        ) or re.match(r'^\s*[=-]{5,}\s*$', lines[j]):
            boundary_i = j
            break
    if boundary_i is None:
        raise RuntimeError('1016 dependency header boundary not found')

    dep_block = []
    if deps:
        dep_block.append(f' Depends On:     {deps[0]}')
        dep_block.extend(f'                 {d}' for d in deps[1:])
    else:
        dep_block.append(' Depends On:')

    lines[dep_i:boundary_i] = dep_block
    text = '\n'.join(lines) + ('\n' if text.endswith('\n') else '')

    dep_sql = ', '.join("'" + d.replace("'", "''") + "'" for d in deps)
    preflight = (
        f"SELECT pg_temp.bt_preflight('{TARGET_1016}', "
        f"ARRAY[{dep_sql}]::text[]);"
    )
    pat = re.compile(
        r"SELECT\s+pg_temp\.bt_preflight\(\s*['\"]"
        + re.escape(TARGET_1016)
        + r"['\"]\s*,\s*ARRAY\s*\[.*?\]\s*::text\[\]\s*\)\s*;",
        re.I | re.S,
    )
    text, n = pat.subn(preflight, text, count=1)
    if n != 1:
        raise RuntimeError(f'Expected one 1016 inline preflight; found {n}')
    return text

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--schema-root', required=True)
    ap.add_argument('--apply', action='store_true')
    a = ap.parse_args()

    root = Path(a.schema_root).resolve()
    p1016 = root / TARGET_1016
    if not p1016.exists():
        raise RuntimeError(f'Missing {TARGET_1016}')

    item_file = find_file_containing(
        root,
        'CREATE TABLE catalog.item_relationships',
        exclude=(TARGET_1016,),
    )
    item_rel = item_file.relative_to(root).as_posix()

    grant_hits = list(root.rglob('1107_grants.sql'))
    if len(grant_hits) != 1:
        raise RuntimeError(f'Could not uniquely locate 1107_grants.sql; found {len(grant_hits)}')
    grants = grant_hits[0]
    grants_rel = grants.relative_to(root).as_posix()

    manifest_path, manifest_obj = find_manifest(root)

    item_text = read(item_file)
    if MARKER not in item_text:
        item_text = inject_before_mark_completed(item_text, item_rel, TABLE_DDL)

    text1016 = read(p1016)
    if FUNC_MARKER not in text1016:
        text1016 = inject_before_mark_completed(text1016, TARGET_1016, FUNC_DDL)
    text1016 = patch_1016_contract(text1016, manifest_obj, item_rel)

    grant_text = read(grants)
    if GRANT_MARKER not in grant_text:
        grant_text = inject_before_mark_completed(grant_text, grants_rel, GRANTS_DDL)

    manifest_text = json.dumps(manifest_obj, indent=2, ensure_ascii=False) + '\n'

    print('==============================================================================')
    print(' BrickTrackr Rebrickable Phase 6 canonicalization')
    print('==============================================================================')
    print(f'[INFO] relationship table file: {item_rel}')
    print(f'[INFO] reconcile file:          {TARGET_1016}')
    print(f'[INFO] grants file:             {grants_rel}')
    print(f'[INFO] manifest:                {manifest_path.relative_to(root).as_posix()}')
    print(f"[INFO] mode:                    {'APPLY' if a.apply else 'DRY RUN'}")

    if not a.apply:
        print('[PASS] dry run generated canonical Phase 6 changes')
        print('[NEXT] rerun with -Apply')
        return 0

    for p, new in (
        (item_file, item_text),
        (p1016, text1016),
        (grants, grant_text),
        (manifest_path, manifest_text),
    ):
        old = read(p)
        if old == new:
            print(f'[SKIP] {p.relative_to(root).as_posix()}')
            continue
        bak = p.with_suffix(p.suffix + '.phase6.bak')
        if not bak.exists():
            shutil.copy2(p, bak)
        write(p, new)
        print(f'[WRITE] {p.relative_to(root).as_posix()}')

    verifier = root / 'tools' / 'verify_dependencies.py'
    if not verifier.exists():
        raise RuntimeError(f'Missing {verifier}')

    result = subprocess.run(
        [sys.executable, str(verifier)],
        cwd=str(root),
        text=True,
        capture_output=True,
    )

    print('\n=== verify_dependencies.py ===')
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr)

    if result.returncode != 0:
        raise RuntimeError(
            'Phase 6 canonicalization applied, but dependency verification failed'
        )

    print('\n[PASS] Phase 6 canonicalization applied and dependency contract passed')
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'[FAIL] {type(exc).__name__}: {exc}', file=sys.stderr)
        raise SystemExit(1)
