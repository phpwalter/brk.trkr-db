#!/usr/bin/env python3
"""
===============================================================================
 BrickTrackr Rebrickable Import - Phase 6A
===============================================================================

Purpose
-------
Validate and stage Rebrickable part_relationships.csv.gz as authoritative,
lossless source evidence.

This phase performs NO canonical DML.

Successful terminal state:
    import.source_runs.status = VALIDATING
    import.source_run_datasets.status = VALIDATED

The later Phase 6B reconcile step must make explicit semantic decisions for
Rebrickable relationship types before modifying catalog.item_relationships.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import io
import os
import sys
from pathlib import Path
from uuid import UUID

import psycopg
from psycopg.types.json import Jsonb

SOURCE_CODE = "REBRICKABLE"
DATASET_NAME = "part_relationships"
ENTITY_NAMESPACE = "PART_RELATIONSHIP"
EXPECTED_HEADERS = ("rel_type", "child_part_num", "parent_part_num")
KNOWN_REL_TYPES = frozenset({"A", "B", "M", "P", "R", "T"})
IMPORTER_VERSION = "1.0.0"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Stage Rebrickable part relationships without canonical DML"
    )
    p.add_argument(
        "--dsn",
        default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"),
        help="PostgreSQL DSN; defaults to BRICKTRACKR_IMPORT_DATABASE_URL",
    )
    p.add_argument(
        "--archive",
        type=Path,
        default=Path(__file__).resolve().parent
        / "rebrickable-downloads"
        / "part_relationships.csv.gz",
    )
    return p.parse_args()


def require_text(value: str | None, field: str, row_number: int) -> str:
    value = (value or "").strip()
    if not value:
        raise ValueError(f"row {row_number}: required field {field!r} is blank")
    return value


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def validate_archive(path: Path) -> tuple[int, str, dict[str, int], int]:
    if not path.exists():
        raise RuntimeError(f"archive not found: {path}")

    checksum = sha256_file(path)
    seen: set[tuple[str, str, str]] = set()
    counts: dict[str, int] = {}
    row_count = 0
    self_links = 0

    with gzip.open(path, "rb") as gz:
        with io.TextIOWrapper(gz, encoding="utf-8-sig", newline="") as text:
            reader = csv.DictReader(text)

            headers = tuple(reader.fieldnames or ())
            if headers != EXPECTED_HEADERS:
                raise RuntimeError(
                    f"header mismatch: expected {EXPECTED_HEADERS!r}; got {headers!r}"
                )

            for row_number, row in enumerate(reader, start=1):
                rel_type = require_text(row.get("rel_type"), "rel_type", row_number)
                child = require_text(
                    row.get("child_part_num"), "child_part_num", row_number
                )
                parent = require_text(
                    row.get("parent_part_num"), "parent_part_num", row_number
                )

                if rel_type not in KNOWN_REL_TYPES:
                    raise ValueError(
                        f"row {row_number}: unknown rel_type {rel_type!r}"
                    )

                key = (rel_type, child, parent)
                if key in seen:
                    raise ValueError(
                        f"row {row_number}: duplicate relationship triple {key!r}"
                    )
                seen.add(key)

                counts[rel_type] = counts.get(rel_type, 0) + 1
                if child == parent:
                    self_links += 1

                row_count += 1

    return row_count, checksum, counts, self_links


def iter_records(path: Path):
    with gzip.open(path, "rb") as gz:
        with io.TextIOWrapper(gz, encoding="utf-8-sig", newline="") as text:
            reader = csv.DictReader(text)
            headers = tuple(reader.fieldnames or ())
            if headers != EXPECTED_HEADERS:
                raise RuntimeError("archive header changed after validation")

            for row_number, row in enumerate(reader, start=1):
                rel_type = require_text(row.get("rel_type"), "rel_type", row_number)
                child = require_text(
                    row.get("child_part_num"), "child_part_num", row_number
                )
                parent = require_text(
                    row.get("parent_part_num"), "parent_part_num", row_number
                )

                yield row_number, {
                    "rel_type": rel_type,
                    "child_part_num": child,
                    "parent_part_num": parent,
                    "is_self_link": child == parent,
                }


def preflight_database(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT current_user::text")
        login = cur.fetchone()[0]

        cur.execute(
            """
            SELECT
                to_regclass('import.source_runs') IS NOT NULL,
                to_regclass('import.source_run_datasets') IS NOT NULL,
                to_regclass('import.source_stage_records') IS NOT NULL,
                pg_has_role(%s::text, 'lego_importer'::text, 'MEMBER'::text),
                EXISTS (
                    SELECT 1
                    FROM reference.external_sources
                    WHERE source_code = %s
                )
            """,
            (login, SOURCE_CODE),
        )
        has_runs, has_datasets, has_stage, is_importer, has_source = cur.fetchone()

        failures = []
        if not has_runs:
            failures.append("import.source_runs missing")
        if not has_datasets:
            failures.append("import.source_run_datasets missing")
        if not has_stage:
            failures.append("import.source_stage_records missing")
        if not is_importer:
            failures.append(f"{login!r} is not a member of lego_importer")
        if not has_source:
            failures.append("REBRICKABLE source missing")

        if failures:
            raise RuntimeError("; ".join(failures))

        cur.execute("SET ROLE lego_importer")

    conn.commit()


def create_source_run(
    conn: psycopg.Connection,
    row_count: int,
    checksum: str,
    type_counts: dict[str, int],
    self_links: int,
) -> UUID:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO import.source_runs (
                source_id,
                status,
                summary
            )
            SELECT
                source_id,
                'STARTED'::import.source_run_status,
                %s::jsonb
            FROM reference.external_sources
            WHERE source_code = %s
            RETURNING source_run_id
            """,
            (
                Jsonb(
                    {
                        "importer": "import_rebrickable_phase6a_relationships.py",
                        "phase": "6A",
                        "dataset": DATASET_NAME,
                        "source_row_count": row_count,
                        "relationship_type_counts": type_counts,
                        "self_link_count": self_links,
                        "canonical_dml": False,
                    }
                ),
                SOURCE_CODE,
            ),
        )
        row = cur.fetchone()
        if row is None:
            raise RuntimeError("failed to create Rebrickable source run")
        source_run_id = row[0]

        cur.execute(
            """
            INSERT INTO import.source_run_datasets (
                source_run_id,
                dataset_name,
                status,
                is_authoritative_scope,
                started_at,
                source_row_count,
                checksum_sha256
            )
            VALUES (
                %s,
                %s,
                'DOWNLOADED'::import.dataset_status,
                true,
                now(),
                %s,
                decode(%s, 'hex')
            )
            """,
            (source_run_id, DATASET_NAME, row_count, checksum),
        )

        cur.execute(
            """
            UPDATE import.source_runs
            SET status = 'STAGING'::import.source_run_status
            WHERE source_run_id = %s
            """,
            (source_run_id,),
        )

    conn.commit()
    return source_run_id


def stage(
    conn: psycopg.Connection,
    source_run_id: UUID,
    archive: Path,
    expected_count: int,
) -> None:
    staged = 0

    with conn.cursor() as cur:
        with cur.copy(
            """
            COPY import.source_stage_records (
                source_run_id,
                dataset_name,
                entity_namespace,
                source_row_number,
                normalized_payload
            )
            FROM STDIN
            """
        ) as copy:
            for row_number, payload in iter_records(archive):
                copy.write_row(
                    (
                        source_run_id,
                        DATASET_NAME,
                        ENTITY_NAMESPACE,
                        row_number,
                        Jsonb(payload),
                    )
                )
                staged += 1

        if staged != expected_count:
            raise RuntimeError(
                f"staged row count {staged:,} != validated row count {expected_count:,}"
            )

        cur.execute(
            """
            UPDATE import.source_run_datasets
            SET
                status = 'VALIDATED'::import.dataset_status,
                staged_row_count = %s,
                completed_at = now()
            WHERE source_run_id = %s
              AND dataset_name = %s
              AND source_row_count = %s
            """,
            (staged, source_run_id, DATASET_NAME, expected_count),
        )
        if cur.rowcount != 1:
            raise RuntimeError("failed to mark Phase 6A dataset VALIDATED")

        cur.execute(
            """
            UPDATE import.source_runs
            SET status = 'VALIDATING'::import.source_run_status
            WHERE source_run_id = %s
            """,
            (source_run_id,),
        )

    conn.commit()


def mark_failed(
    conn: psycopg.Connection,
    source_run_id: UUID | None,
    message: str,
) -> None:
    if source_run_id is None:
        return
    try:
        conn.rollback()
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE import.source_runs
                SET
                    status = 'FAILED'::import.source_run_status,
                    failed_at = now(),
                    failure_message = %s
                WHERE source_run_id = %s
                """,
                (message[:8000], source_run_id),
            )
            cur.execute(
                """
                UPDATE import.source_run_datasets
                SET status = 'FAILED'::import.dataset_status
                WHERE source_run_id = %s
                  AND dataset_name = %s
                """,
                (source_run_id, DATASET_NAME),
            )
        conn.commit()
    except Exception:
        try:
            conn.rollback()
        except Exception:
            pass


def main() -> int:
    args = parse_args()

    if not args.dsn:
        print(
            "[FAIL] BRICKTRACKR_IMPORT_DATABASE_URL or --dsn is required",
            file=sys.stderr,
        )
        return 2

    archive = args.archive.resolve()

    print("==============================================================================")
    print(f" BrickTrackr Rebrickable Import - Phase 6A v{IMPORTER_VERSION}")
    print("==============================================================================")
    print(f"[INFO] archive: {archive}")

    row_count, checksum, type_counts, self_links = validate_archive(archive)

    print(f"[PASS] source rows: {row_count:,}")
    print(f"[INFO] sha256: {checksum}")
    print(
        "[INFO] relationship counts: "
        + ", ".join(f"{k}={type_counts[k]:,}" for k in sorted(type_counts))
    )
    print(f"[INFO] self links preserved as source evidence: {self_links:,}")

    source_run_id: UUID | None = None

    with psycopg.connect(args.dsn) as conn:
        try:
            preflight_database(conn)
            print("[PASS] importer database contract verified")

            source_run_id = create_source_run(
                conn,
                row_count,
                checksum,
                type_counts,
                self_links,
            )
            print(f"[INFO] source run: {source_run_id}")

            stage(conn, source_run_id, archive, row_count)

        except Exception as exc:
            mark_failed(conn, source_run_id, str(exc))
            raise

    print("")
    print("==============================================================================")
    print(" [PASS] Rebrickable Phase 6A staged successfully")
    print("==============================================================================")
    print(f"[INFO] Source run: {source_run_id}")
    print(f"[INFO] Rows staged: {row_count:,}")
    print("[INFO] Run status: VALIDATING")
    print("[INFO] Canonical DML: NO")
    print("[INFO] Next: Phase 6B relationship semantic reconciliation")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
