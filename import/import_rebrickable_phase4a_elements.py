#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from uuid import UUID

import psycopg
from psycopg.types.json import Jsonb

VERSION = "4.0.2"
DATASET = "elements"
NAMESPACE = "ELEMENT"
EXPECTED_HEADER = ["element_id", "part_num", "color_id", "design_id"]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--dsn",
        default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"),
    )
    p.add_argument(
        "--file",
        default="./rebrickable-downloads/elements.csv.gz",
    )
    p.add_argument(
        "--batch-size",
        type=int,
        default=5000,
    )
    return p.parse_args()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def validate_and_count(path: Path):
    rows = 0
    duplicate_ids = 0
    seen = set()

    with gzip.open(path, "rt", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)

        if reader.fieldnames != EXPECTED_HEADER:
            raise RuntimeError(
                f"unexpected elements header: {reader.fieldnames!r}; "
                f"expected {EXPECTED_HEADER!r}"
            )

        for source_row, row in enumerate(reader, start=2):
            element_id = (row.get("element_id") or "").strip()
            part_num = (row.get("part_num") or "").strip()
            color_id = (row.get("color_id") or "").strip()
            design_id = (row.get("design_id") or "").strip()

            if not element_id:
                raise RuntimeError(
                    f"elements row {source_row}: element_id is empty"
                )

            if not part_num:
                raise RuntimeError(
                    f"elements row {source_row}: part_num is empty"
                )

            if not color_id:
                raise RuntimeError(
                    f"elements row {source_row}: color_id is empty"
                )

            try:
                int(color_id)
            except ValueError as exc:
                raise RuntimeError(
                    f"elements row {source_row}: color_id is not an integer: "
                    f"{color_id!r}"
                ) from exc

            # design_id is source evidence. Rebrickable may leave it blank and
            # numeric-looking values may exceed BrickTrackr int4 convenience
            # columns, so staging deliberately keeps it as text.
            if element_id in seen:
                duplicate_ids += 1
            else:
                seen.add(element_id)

            rows += 1

    return rows, duplicate_ids


def iter_rows(path: Path):
    with gzip.open(path, "rt", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for source_row, row in enumerate(reader, start=1):
            yield (
                source_row,
                {
                    "element_id": (row.get("element_id") or "").strip(),
                    "part_num": (row.get("part_num") or "").strip(),
                    "color_id": (row.get("color_id") or "").strip(),
                    "design_id": (
                        (row.get("design_id") or "").strip() or None
                    ),
                },
            )


def chunks(iterable, size):
    batch = []
    for item in iterable:
        batch.append(item)
        if len(batch) >= size:
            yield batch
            batch = []
    if batch:
        yield batch


def main() -> int:
    args = parse_args()

    if not args.dsn:
        print("[FAIL] BRICKTRACKR_IMPORT_DATABASE_URL / --dsn is required",
              file=sys.stderr)
        return 2

    if args.batch_size < 1 or args.batch_size > 50000:
        print("[FAIL] --batch-size must be between 1 and 50000",
              file=sys.stderr)
        return 2

    path = Path(args.file).resolve()

    if not path.is_file():
        print(f"[FAIL] elements file not found: {path}", file=sys.stderr)
        return 2

    print("==============================================================================")
    print(f" BrickTrackr Rebrickable Phase 4A - Elements Staging v{VERSION}")
    print("==============================================================================")
    print(f"[INFO] File:       {path}")
    print(f"[INFO] Batch size: {args.batch_size:,}")

    started = time.monotonic()

    try:
        checksum = sha256_file(path)
        checksum_bytes = bytes.fromhex(checksum)
        row_count, duplicate_ids = validate_and_count(path)

        print(f"[PASS] Header:      {EXPECTED_HEADER}")
        print(f"[PASS] SHA-256:     {checksum}")
        print(f"[PASS] Rows:        {row_count:,}")
        print(f"[INFO] Duplicate element_id rows observed: {duplicate_ids:,}")
        print(
            "[INFO] Duplicate element IDs are retained as source evidence; "
            "Phase 4B decides canonical history semantics."
        )

        with psycopg.connect(
            args.dsn,
            options="-c client_encoding=UTF8",
            autocommit=True,
        ) as conn:

            with conn.cursor() as cur:
                cur.execute("SELECT current_user::text")
                login = cur.fetchone()[0]

                cur.execute(
                    """
                    SELECT
                        pg_has_role(%s::text, 'brktrkr_import', 'MEMBER'),
                        has_schema_privilege(%s::text, 'import', 'USAGE')
                    """,
                    (login, login),
                )
                member, import_usage = cur.fetchone()

                if not member:
                    raise RuntimeError(
                        f"database login {login!r} is not a member of brktrkr_import"
                    )
                if not import_usage:
                    raise RuntimeError(
                        f"database login {login!r} lacks USAGE on import"
                    )

                cur.execute("SET ROLE brktrkr_import")

                cur.execute(
                    """
                    SELECT source_id
                    FROM reference.external_sources
                    WHERE source_code = 'REBRICKABLE'
                    """
                )
                row = cur.fetchone()
                if row is None:
                    raise RuntimeError(
                        "reference.external_sources has no REBRICKABLE source"
                    )
                source_id = row[0]

            # Create the source run and dataset in one durable transaction.
            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        INSERT INTO import.source_runs (
                            source_id,
                            status,
                            summary
                        )
                        VALUES (
                            %s,
                            'STARTED',
                            jsonb_build_object(
                                'importer',
                                'rebrickable-phase4a-elements-v4.0.0'
                            )
                        )
                        RETURNING source_run_id
                        """,
                        (source_id,),
                    )
                    source_run_id = cur.fetchone()[0]

                    cur.execute(
                        """
                        INSERT INTO import.source_run_datasets (
                            source_run_id,
                            dataset_name,
                            status,
                            is_authoritative_scope,
                            source_row_count,
                            checksum_sha256,
                            started_at
                        )
                        VALUES (
                            %s,
                            'elements',
                            'DOWNLOADED',
                            true,
                            %s,
                            %s,
                            clock_timestamp()
                        )
                        """,
                        (
                            source_run_id,
                            row_count,
                            checksum_bytes,
                        ),
                    )

                    cur.execute(
                        """
                        UPDATE import.source_runs
                        SET status = 'STAGING'
                        WHERE source_run_id = %s
                        """,
                        (source_run_id,),
                    )

            print(f"[RUN ] Source run: {source_run_id}")

            inserted = 0
            batch_no = 0

            for batch in chunks(iter_rows(path), args.batch_size):
                batch_no += 1

                with conn.transaction():
                    with conn.cursor() as cur:
                        cur.executemany(
                            """
                            INSERT INTO import.source_stage_records (
                                source_run_id,
                                dataset_name,
                                entity_namespace,
                                source_row_number,
                                normalized_payload
                            )
                            VALUES (
                                %s,
                                'elements',
                                'ELEMENT',
                                %s,
                                %s
                            )
                            """,
                            [
                                (
                                    source_run_id,
                                    source_row,
                                    Jsonb(payload),
                                )
                                for source_row, payload in batch
                            ],
                        )

                inserted += len(batch)
                pct = 100.0 * inserted / row_count if row_count else 100.0
                print(
                    f"[STAGE] batch={batch_no:>3} "
                    f"{inserted:>9,}/{row_count:,} "
                    f"({pct:5.1f}%)",
                    flush=True,
                )

            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        SELECT count(*)
                        FROM import.source_stage_records
                        WHERE source_run_id = %s
                          AND dataset_name = 'elements'
                          AND entity_namespace = 'ELEMENT'
                        """,
                        (source_run_id,),
                    )
                    staged_count = cur.fetchone()[0]

                    if staged_count != row_count:
                        raise RuntimeError(
                            f"staged row count {staged_count} "
                            f"does not match source row count {row_count}"
                        )

                    cur.execute(
                        """
                        UPDATE import.source_run_datasets
                        SET
                            status = 'VALIDATED',
                            staged_row_count = %s
                        WHERE source_run_id = %s
                          AND dataset_name = 'elements'
                        """,
                        (staged_count, source_run_id),
                    )

                    cur.execute(
                        """
                        UPDATE import.source_runs
                        SET
                            status = 'VALIDATING',
                            summary = COALESCE(summary, '{}'::jsonb)
                                || jsonb_build_object(
                                    'phase4a_elements',
                                    jsonb_build_object(
                                        'rows', %s::bigint,
                                        'duplicate_element_ids', %s::integer,
                                        'checksum_sha256', %s::text
                                    )
                                )
                        WHERE source_run_id = %s
                        """,
                        (
                            row_count,
                            duplicate_ids,
                            checksum,
                            source_run_id,
                        ),
                    )

            elapsed = time.monotonic() - started

            print("")
            print("==============================================================================")
            print(" [PASS] Rebrickable Phase 4A elements staging completed")
            print(f" [INFO] Source run: {source_run_id}")
            print(f" [INFO] Rows:       {row_count:,}")
            print(f" [INFO] Elapsed:    {elapsed:.2f}s")
            print(" [INFO] Status:     VALIDATING")
            print("==============================================================================")
            print("")
            print(
                "[NEXT] Phase 4B may reconcile this source run. "
                "No canonical catalog DML was performed."
            )
            return 0

    except Exception as exc:
        elapsed = time.monotonic() - started
        print(
            f"[FAIL] Phase 4A after {elapsed:.2f}s: "
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
