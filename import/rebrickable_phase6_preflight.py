#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import os
import sys
import urllib.request
from collections import Counter
from pathlib import Path

import psycopg

URL = "https://cdn.rebrickable.com/media/downloads/part_relationships.csv.gz"
FILENAME = "part_relationships.csv.gz"
EXPECTED_HEADER = ["rel_type", "child_part_num", "parent_part_num"]
KNOWN_REL_TYPES = {"A", "B", "M", "P", "R", "T"}


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--import-root", required=True)
    p.add_argument("--dsn", default=os.getenv("BRICKTRACKR_ADMIN_DATABASE_URL"))
    p.add_argument("--refresh", action="store_true")
    p.add_argument("--report", default="phase6_preflight_report.txt")
    return p.parse_args()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_uncompressed_gzip(path: Path) -> str:
    h = hashlib.sha256()
    with gzip.open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, target: Path):
    tmp = target.with_suffix(target.suffix + ".tmp")
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "BrickTrackr-Rebrickable-Importer/Phase6"},
    )
    with urllib.request.urlopen(req, timeout=120) as r, tmp.open("wb") as f:
        while True:
            chunk = r.read(1024 * 1024)
            if not chunk:
                break
            f.write(chunk)
    tmp.replace(target)


def profile_csv(path: Path):
    rel_types = Counter()
    duplicates = 0
    self_links = 0
    blank_child = 0
    blank_parent = 0
    blank_type = 0
    seen = set()
    sample_by_type = {}
    rows = 0
    part_ids = set()

    with gzip.open(path, "rt", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            raise RuntimeError("part_relationships CSV is empty")

        if header != EXPECTED_HEADER:
            raise RuntimeError(
                f"unexpected header: {header!r}; expected {EXPECTED_HEADER!r}"
            )

        for rownum, row in enumerate(reader, start=2):
            if len(row) != 3:
                raise RuntimeError(
                    f"row {rownum}: expected 3 columns, found {len(row)}"
                )

            rel_type, child, parent = row
            rows += 1

            if not rel_type:
                blank_type += 1
            if not child:
                blank_child += 1
            if not parent:
                blank_parent += 1

            rel_types[rel_type] += 1

            key = (rel_type, child, parent)
            if key in seen:
                duplicates += 1
            else:
                seen.add(key)

            if child == parent:
                self_links += 1

            if rel_type not in sample_by_type:
                sample_by_type[rel_type] = key

            if child:
                part_ids.add(child)
            if parent:
                part_ids.add(parent)

    unknown = sorted(set(rel_types) - KNOWN_REL_TYPES)

    return {
        "header": EXPECTED_HEADER,
        "rows": rows,
        "rel_types": dict(sorted(rel_types.items())),
        "unknown_rel_types": unknown,
        "duplicate_triples": duplicates,
        "self_links": self_links,
        "blank_rel_type": blank_type,
        "blank_child_part_num": blank_child,
        "blank_parent_part_num": blank_parent,
        "distinct_part_ids": len(part_ids),
        "part_ids": part_ids,
        "sample_by_type": dict(sorted(sample_by_type.items())),
    }


def inspect_database(conn, part_ids: set[str]):
    result = {}

    with conn.cursor() as cur:
        cur.execute("""
            SELECT source_id, source_name
            FROM reference.external_sources
            WHERE lower(source_name) LIKE '%%rebrickable%%'
            ORDER BY source_id
        """)
        sources = cur.fetchall()
        result["rebrickable_sources"] = sources

        cur.execute("""
            SELECT n.nspname, c.relname
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r','p','v','m')
              AND n.nspname NOT IN ('pg_catalog','information_schema')
              AND (
                    lower(c.relname) LIKE '%%relationship%%'
                 OR lower(c.relname) LIKE '%%relation%%'
                 OR lower(c.relname) LIKE '%%alternate%%'
                 OR lower(c.relname) LIKE '%%equiv%%'
                 OR lower(c.relname) LIKE '%%mold%%'
                 OR lower(c.relname) LIKE '%%supersed%%'
                 OR lower(c.relname) LIKE '%%compat%%'
              )
            ORDER BY n.nspname, c.relname
        """)
        candidate_tables = cur.fetchall()
        result["candidate_tables"] = candidate_tables

        candidate_columns = []
        for schema, table in candidate_tables:
            cur.execute("""
                SELECT
                    a.attnum,
                    a.attname,
                    pg_catalog.format_type(a.atttypid, a.atttypmod),
                    a.attnotnull,
                    pg_get_expr(ad.adbin, ad.adrelid)
                FROM pg_attribute a
                JOIN pg_class c ON c.oid = a.attrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                LEFT JOIN pg_attrdef ad
                  ON ad.adrelid = a.attrelid
                 AND ad.adnum = a.attnum
                WHERE n.nspname = %s
                  AND c.relname = %s
                  AND a.attnum > 0
                  AND NOT a.attisdropped
                ORDER BY a.attnum
            """, (schema, table))
            cols = cur.fetchall()

            cur.execute("""
                SELECT con.conname, con.contype, pg_get_constraintdef(con.oid, true)
                FROM pg_constraint con
                JOIN pg_class c ON c.oid = con.conrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = %s
                  AND c.relname = %s
                ORDER BY con.contype, con.conname
            """, (schema, table))
            cons = cur.fetchall()
            candidate_columns.append((schema, table, cols, cons))

        result["candidate_contracts"] = candidate_columns

        if not sources:
            result["part_resolution"] = {
                "status": "SKIPPED",
                "reason": "No Rebrickable source row found",
            }
            return result

        source_id = sources[0][0]

        # Determine the part namespace actually used in external_identifiers.
        cur.execute("""
            SELECT entity_namespace, count(*)::bigint
            FROM catalog.external_identifiers
            WHERE source_id = %s
              AND source_present
            GROUP BY entity_namespace
            ORDER BY count(*) DESC, entity_namespace
        """, (source_id,))
        namespaces = cur.fetchall()
        result["external_namespaces"] = namespaces

        part_namespace = None
        for ns, cnt in namespaces:
            if "PART" in ns.upper():
                part_namespace = ns
                break

        if part_namespace is None:
            result["part_resolution"] = {
                "status": "SKIPPED",
                "reason": "No PART-like external identifier namespace found",
            }
            return result

        # Avoid huge parameter arrays: load IDs into a temporary table.
        cur.execute("""
            CREATE TEMP TABLE phase6_part_ids (
                external_id text PRIMARY KEY
            ) ON COMMIT DROP
        """)

        rows = [(x,) for x in part_ids]
        with cur.copy(
            "COPY phase6_part_ids (external_id) FROM STDIN"
        ) as copy:
            for row in rows:
                copy.write_row(row)

        cur.execute("""
            SELECT count(*)::bigint
            FROM phase6_part_ids
        """)
        total = cur.fetchone()[0]

        cur.execute("""
            SELECT count(*)::bigint
            FROM phase6_part_ids p
            WHERE EXISTS (
                SELECT 1
                FROM catalog.external_identifiers e
                WHERE e.source_id = %s
                  AND e.entity_namespace = %s
                  AND e.external_id = p.external_id
                  AND e.source_present
            )
        """, (source_id, part_namespace))
        resolved = cur.fetchone()[0]

        cur.execute("""
            SELECT p.external_id
            FROM phase6_part_ids p
            WHERE NOT EXISTS (
                SELECT 1
                FROM catalog.external_identifiers e
                WHERE e.source_id = %s
                  AND e.entity_namespace = %s
                  AND e.external_id = p.external_id
                  AND e.source_present
            )
            ORDER BY p.external_id
            LIMIT 25
        """, (source_id, part_namespace))
        missing_sample = [r[0] for r in cur.fetchall()]

        result["part_resolution"] = {
            "status": "OK",
            "source_id": str(source_id),
            "entity_namespace": part_namespace,
            "distinct_source_part_ids": total,
            "resolved": resolved,
            "unresolved": total - resolved,
            "unresolved_sample": missing_sample,
        }

    return result


def format_report(path: Path, csv_sha: str, gz_sha: str, prof: dict, db: dict):
    lines = []
    add = lines.append

    add("===============================================================================")
    add(" BrickTrackr Rebrickable Phase 6 Preflight")
    add(" Dataset: part_relationships.csv.gz")
    add("===============================================================================")
    add("")
    add(f"File: {path}")
    add(f"Compressed SHA-256:   {gz_sha}")
    add(f"CSV content SHA-256:  {csv_sha}")
    add(f"Header: {json.dumps(prof['header'])}")
    add(f"Rows: {prof['rows']:,}")
    add(f"Distinct referenced part IDs: {prof['distinct_part_ids']:,}")
    add("")
    add("Relationship type counts:")
    for k, v in prof["rel_types"].items():
        add(f"  {k or '<BLANK>'}: {v:,}")
    add("")
    add(f"Unknown relationship types: {prof['unknown_rel_types'] or 'none'}")
    add(f"Duplicate exact triples: {prof['duplicate_triples']:,}")
    add(f"Self links: {prof['self_links']:,}")
    add(f"Blank rel_type: {prof['blank_rel_type']:,}")
    add(f"Blank child_part_num: {prof['blank_child_part_num']:,}")
    add(f"Blank parent_part_num: {prof['blank_parent_part_num']:,}")
    add("")
    add("Samples by relationship type:")
    for k, sample in prof["sample_by_type"].items():
        add(f"  {k}: {sample}")
    add("")
    add("Rebrickable external sources:")
    if db["rebrickable_sources"]:
        for source_id, name in db["rebrickable_sources"]:
            add(f"  source_id={source_id} source_name={name}")
    else:
        add("  none")
    add("")
    add("External identifier namespaces:")
    for ns, cnt in db.get("external_namespaces", []):
        add(f"  {ns}: {cnt:,}")
    if not db.get("external_namespaces"):
        add("  none")
    add("")
    add("Part reference resolution:")
    pr = db["part_resolution"]
    for k, v in pr.items():
        add(f"  {k}: {v}")
    add("")
    add("Candidate canonical relationship tables:")
    if not db["candidate_tables"]:
        add("  none found")
    else:
        for schema, table in db["candidate_tables"]:
            add(f"  {schema}.{table}")
    add("")
    add("Candidate table contracts:")
    if not db["candidate_contracts"]:
        add("  none")
    for schema, table, cols, cons in db["candidate_contracts"]:
        add(f"")
        add(f"  [{schema}.{table}]")
        add("  Columns:")
        for attnum, name, typ, notnull, default in cols:
            add(
                f"    {attnum:>2} {name} {typ}"
                f"{' NOT NULL' if notnull else ''}"
                f"{' DEFAULT ' + default if default else ''}"
            )
        add("  Constraints:")
        if cons:
            for conname, contype, condef in cons:
                add(f"    {conname} [{contype}] {condef}")
        else:
            add("    none")
    add("")
    add("Phase 6 gate:")
    failures = []
    if prof["unknown_rel_types"]:
        failures.append("unknown rel_type values")
    if prof["blank_rel_type"] or prof["blank_child_part_num"] or prof["blank_parent_part_num"]:
        failures.append("blank required source values")
    if pr.get("status") == "OK" and pr.get("unresolved", 0) != 0:
        failures.append("unresolved part references")
    if failures:
        add("  REVIEW REQUIRED: " + "; ".join(failures))
    else:
        add("  PASS: source contract/profile is suitable for staging design")
    add("")

    return "\n".join(lines)


def main():
    a = parse_args()
    root = Path(a.import_root).resolve()
    downloads = root / "rebrickable-downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    data_path = downloads / FILENAME
    report_path = root / a.report

    if not a.dsn:
        raise RuntimeError("BRICKTRACKR_ADMIN_DATABASE_URL / --dsn is required")

    print("==============================================================================")
    print(" Rebrickable Phase 6 preflight - part relationships")
    print("==============================================================================")
    print(f"[INFO] import root: {root}")

    if a.refresh or not data_path.exists():
        print(f"[INFO] downloading: {URL}")
        download(URL, data_path)
        print(f"[PASS] downloaded: {data_path.name}")
    else:
        print(f"[INFO] using existing: {data_path.name}")

    gz_sha = sha256_file(data_path)
    csv_sha = sha256_uncompressed_gzip(data_path)
    prof = profile_csv(data_path)
    print(f"[PASS] header: {prof['header']}")
    print(f"[INFO] rows: {prof['rows']:,}")
    print(f"[INFO] compressed sha256: {gz_sha}")
    print(f"[INFO] csv sha256:        {csv_sha}")

    with psycopg.connect(a.dsn, autocommit=False) as conn:
        # A normal transaction is required because the inspection path uses
        # a session-local TEMP TABLE for bulk reference resolution.
        # No canonical tables are modified, and the transaction is rolled back.
        db = inspect_database(conn, prof["part_ids"])
        conn.rollback()

    report = format_report(data_path, csv_sha, gz_sha, prof, db)
    report_path.write_text(report, encoding="utf-8", newline="\n")

    print(f"[PASS] report: {report_path}")
    pr = db["part_resolution"]
    if pr.get("status") == "OK":
        print(
            f"[INFO] part refs resolved: {pr['resolved']:,}/{pr['distinct_source_part_ids']:,}; "
            f"unresolved={pr['unresolved']:,}"
        )
    print(f"[INFO] candidate relationship tables: {len(db['candidate_tables'])}")
    print("")
    print("[PASS] Phase 6 preflight completed; no canonical DML performed")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
