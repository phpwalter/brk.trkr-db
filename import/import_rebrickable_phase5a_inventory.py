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

import psycopg
from psycopg.types.json import Jsonb

VERSION = "5.0.1"

DATASETS = {
    "inventories": {
        "namespace": "INVENTORY",
        "header": ["id", "version", "set_num"],
    },
    "inventory_parts": {
        "namespace": "INVENTORY_PART",
        "header": [
            "inventory_id",
            "part_num",
            "color_id",
            "quantity",
            "is_spare",
            "img_url",
        ],
    },
    "inventory_sets": {
        "namespace": "INVENTORY_SET",
        "header": ["inventory_id", "set_num", "quantity"],
    },
    "inventory_minifigs": {
        "namespace": "INVENTORY_MINIFIGURE",
        "header": ["inventory_id", "fig_num", "quantity"],
    },
}


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--dsn", default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"))
    p.add_argument(
        "--downloads-dir",
        default="./rebrickable-downloads",
    )
    p.add_argument(
        "--batch-size",
        type=int,
        default=50000,
        help="COPY rows committed per transaction (default: 50000)",
    )
    return p.parse_args()


def file_sha256(path: Path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest(), h.digest()


def require_int(value: str, field: str, dataset: str, rowno: int, minimum=1):
    try:
        n = int(value)
    except ValueError as exc:
        raise RuntimeError(
            f"{dataset} row {rowno}: {field} is not an integer: {value!r}"
        ) from exc
    if n < minimum:
        raise RuntimeError(
            f"{dataset} row {rowno}: {field} must be >= {minimum}: {n}"
        )
    return n


def parse_bool(value: str, field: str, dataset: str, rowno: int):
    v = value.strip().lower()
    if v in {"t", "true", "1", "y", "yes"}:
        return True
    if v in {"f", "false", "0", "n", "no"}:
        return False
    raise RuntimeError(
        f"{dataset} row {rowno}: {field} is not boolean: {value!r}"
    )


def scan_sources(downloads: Path):
    info = {}
    inventory_ids = set()

    # First scan inventory headers so children can be checked against them.
    dataset = "inventories"
    path = downloads / f"{dataset}.csv.gz"
    sha_hex, sha_bytes = file_sha256(path)

    rows = 0
    duplicate_inventory_ids = 0

    with gzip.open(path, "rt", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != DATASETS[dataset]["header"]:
            raise RuntimeError(
                f"{dataset}: unexpected header {reader.fieldnames!r}; "
                f"expected {DATASETS[dataset]['header']!r}"
            )

        for rowno, row in enumerate(reader, start=1):
            inv_id = require_int(row["id"].strip(), "id", dataset, rowno)
            require_int(row["version"].strip(), "version", dataset, rowno)

            set_num = row["set_num"].strip()
            if not set_num:
                raise RuntimeError(f"{dataset} row {rowno}: set_num is empty")

            if inv_id in inventory_ids:
                duplicate_inventory_ids += 1
            inventory_ids.add(inv_id)
            rows += 1

    if duplicate_inventory_ids:
        raise RuntimeError(
            f"{dataset}: duplicate inventory id rows found: "
            f"{duplicate_inventory_ids}"
        )

    info[dataset] = {
        "path": path,
        "sha_hex": sha_hex,
        "sha_bytes": sha_bytes,
        "rows": rows,
        "missing_parent_refs": 0,
        "missing_parent_inventory_ids": [],
    }

    # Validate child datasets.
    for dataset in ("inventory_parts", "inventory_sets", "inventory_minifigs"):
        path = downloads / f"{dataset}.csv.gz"
        sha_hex, sha_bytes = file_sha256(path)

        rows = 0
        missing_parent_refs = 0
        missing_parent_inventory_ids = []

        with gzip.open(path, "rt", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            if reader.fieldnames != DATASETS[dataset]["header"]:
                raise RuntimeError(
                    f"{dataset}: unexpected header {reader.fieldnames!r}; "
                    f"expected {DATASETS[dataset]['header']!r}"
                )

            for rowno, row in enumerate(reader, start=1):
                inv_id = require_int(
                    row["inventory_id"].strip(),
                    "inventory_id",
                    dataset,
                    rowno,
                )
                if inv_id not in inventory_ids:
                    missing_parent_refs += 1
                    if len(missing_parent_inventory_ids) < 20:
                        missing_parent_inventory_ids.append(inv_id)

                if dataset == "inventory_parts":
                    if not row["part_num"].strip():
                        raise RuntimeError(
                            f"{dataset} row {rowno}: part_num is empty"
                        )
                    # Rebrickable color_id is source-side numeric identity.
                    int(row["color_id"].strip())
                    require_int(
                        row["quantity"].strip(),
                        "quantity",
                        dataset,
                        rowno,
                    )
                    parse_bool(
                        row["is_spare"],
                        "is_spare",
                        dataset,
                        rowno,
                    )

                elif dataset == "inventory_sets":
                    if not row["set_num"].strip():
                        raise RuntimeError(
                            f"{dataset} row {rowno}: set_num is empty"
                        )
                    require_int(
                        row["quantity"].strip(),
                        "quantity",
                        dataset,
                        rowno,
                    )

                elif dataset == "inventory_minifigs":
                    if not row["fig_num"].strip():
                        raise RuntimeError(
                            f"{dataset} row {rowno}: fig_num is empty"
                        )
                    require_int(
                        row["quantity"].strip(),
                        "quantity",
                        dataset,
                        rowno,
                    )

                rows += 1

        info[dataset] = {
            "path": path,
            "sha_hex": sha_hex,
            "sha_bytes": sha_bytes,
            "rows": rows,
            "missing_parent_refs": missing_parent_refs,
            "missing_parent_inventory_ids": missing_parent_inventory_ids,
        }

    return info


def normalized_rows(dataset: str, path: Path):
    with gzip.open(path, "rt", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)

        for source_row_number, row in enumerate(reader, start=1):
            if dataset == "inventories":
                payload = {
                    "inventory_id": int(row["id"].strip()),
                    "version": int(row["version"].strip()),
                    "set_num": row["set_num"].strip(),
                }

            elif dataset == "inventory_parts":
                payload = {
                    "inventory_id": int(row["inventory_id"].strip()),
                    "part_num": row["part_num"].strip(),
                    "color_id": int(row["color_id"].strip()),
                    "quantity": int(row["quantity"].strip()),
                    "is_spare": parse_bool(
                        row["is_spare"],
                        "is_spare",
                        dataset,
                        source_row_number,
                    ),
                    "img_url": row["img_url"].strip() or None,
                }

            elif dataset == "inventory_sets":
                payload = {
                    "inventory_id": int(row["inventory_id"].strip()),
                    "set_num": row["set_num"].strip(),
                    "quantity": int(row["quantity"].strip()),
                }

            elif dataset == "inventory_minifigs":
                payload = {
                    "inventory_id": int(row["inventory_id"].strip()),
                    "fig_num": row["fig_num"].strip(),
                    "quantity": int(row["quantity"].strip()),
                }

            else:
                raise AssertionError(dataset)

            yield source_row_number, payload


def batched(rows, size):
    batch = []
    for row in rows:
        batch.append(row)
        if len(batch) >= size:
            yield batch
            batch = []
    if batch:
        yield batch


def main():
    a = parse_args()

    if not a.dsn:
        print("[FAIL] BRICKTRACKR_IMPORT_DATABASE_URL / --dsn is required",
              file=sys.stderr)
        return 2

    if not (1000 <= a.batch_size <= 200000):
        print("[FAIL] --batch-size must be between 1000 and 200000",
              file=sys.stderr)
        return 2

    downloads = Path(a.downloads_dir).resolve()

    for dataset in DATASETS:
        path = downloads / f"{dataset}.csv.gz"
        if not path.is_file():
            print(f"[FAIL] Missing source file: {path}", file=sys.stderr)
            return 2

    started = time.monotonic()

    print("==============================================================================")
    print(f" BrickTrackr Rebrickable Phase 5A - Inventory Staging v{VERSION}")
    print("==============================================================================")
    print(f"[INFO] Downloads:  {downloads}")
    print(f"[INFO] COPY batch: {a.batch_size:,}")
    print("")

    try:
        print("[VALIDATE] Source contracts and cross-file inventory references")
        info = scan_sources(downloads)

        total_rows = 0
        for dataset in DATASETS:
            meta = info[dataset]
            total_rows += meta["rows"]
            print(
                f"[PASS] {dataset:<20} "
                f"rows={meta['rows']:>10,} "
                f"sha256={meta['sha_hex']}"
            )
            if meta.get("missing_parent_refs", 0):
                print(
                    f"[WARN] {dataset}: "
                    f"{meta['missing_parent_refs']:,} row(s) reference inventory_id "
                    f"absent from inventories.csv.gz; staged as source evidence. "
                    f"sample={meta['missing_parent_inventory_ids']}"
                )

        print(f"[PASS] Total source rows: {total_rows:,}")
        print("")

        with psycopg.connect(
            a.dsn,
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

            # Create one source run containing the entire composition snapshot.
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
                                'rebrickable-phase5a-inventory-v5.0.1',
                                'datasets',
                                jsonb_build_array(
                                    'inventories',
                                    'inventory_parts',
                                    'inventory_sets',
                                    'inventory_minifigs'
                                )
                            )
                        )
                        RETURNING source_run_id
                        """,
                        (source_id,),
                    )
                    source_run_id = cur.fetchone()[0]

                    for dataset in DATASETS:
                        meta = info[dataset]
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
                                %s,
                                'DOWNLOADED',
                                true,
                                %s,
                                %s,
                                clock_timestamp()
                            )
                            """,
                            (
                                source_run_id,
                                dataset,
                                meta["rows"],
                                meta["sha_bytes"],
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
            print("")

            for dataset, cfg in DATASETS.items():
                meta = info[dataset]
                inserted = 0
                batch_no = 0

                print(
                    f"[DATASET] {dataset} -> {cfg['namespace']} "
                    f"({meta['rows']:,} rows)"
                )

                for batch in batched(
                    normalized_rows(dataset, meta["path"]),
                    a.batch_size,
                ):
                    batch_no += 1

                    with conn.transaction():
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
                                for source_row_number, payload in batch:
                                    copy.write_row(
                                        (
                                            source_run_id,
                                            dataset,
                                            cfg["namespace"],
                                            source_row_number,
                                            Jsonb(payload),
                                        )
                                    )

                    inserted += len(batch)
                    pct = (
                        100.0 * inserted / meta["rows"]
                        if meta["rows"]
                        else 100.0
                    )

                    print(
                        f"[STAGE] {dataset:<20} "
                        f"batch={batch_no:>3} "
                        f"{inserted:>10,}/{meta['rows']:,} "
                        f"({pct:5.1f}%)",
                        flush=True,
                    )

                # Durable dataset validation after staging.
                with conn.transaction():
                    with conn.cursor() as cur:
                        cur.execute(
                            """
                            SELECT count(*)
                            FROM import.source_stage_records
                            WHERE source_run_id = %s
                              AND dataset_name = %s
                              AND entity_namespace = %s
                            """,
                            (
                                source_run_id,
                                dataset,
                                cfg["namespace"],
                            ),
                        )
                        staged = cur.fetchone()[0]

                        if staged != meta["rows"]:
                            raise RuntimeError(
                                f"{dataset}: staged row count {staged:,} "
                                f"does not match source row count "
                                f"{meta['rows']:,}"
                            )

                        cur.execute(
                            """
                            UPDATE import.source_run_datasets
                            SET
                                status = 'VALIDATED',
                                staged_row_count = %s
                            WHERE source_run_id = %s
                              AND dataset_name = %s
                            """,
                            (staged, source_run_id, dataset),
                        )

                print(f"[PASS] {dataset}: {inserted:,} rows staged/validated")
                print("")

            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE import.source_runs
                        SET
                            status = 'VALIDATING',
                            summary = COALESCE(summary, '{}'::jsonb)
                                || jsonb_build_object(
                                    'phase5a_inventory',
                                    jsonb_build_object(
                                        'inventory_rows', %s::bigint,
                                        'inventory_part_rows', %s::bigint,
                                        'inventory_set_rows', %s::bigint,
                                        'inventory_minifig_rows', %s::bigint,
                                        'total_rows', %s::bigint,
                                        'orphan_child_rows',
                                        jsonb_build_object(
                                            'inventory_parts', %s::bigint,
                                            'inventory_sets', %s::bigint,
                                            'inventory_minifigs', %s::bigint
                                        ),
                                        'orphan_inventory_id_samples',
                                        jsonb_build_object(
                                            'inventory_parts', %s::jsonb,
                                            'inventory_sets', %s::jsonb,
                                            'inventory_minifigs', %s::jsonb
                                        )
                                    )
                                )
                        WHERE source_run_id = %s
                        """,
                        (
                            info["inventories"]["rows"],
                            info["inventory_parts"]["rows"],
                            info["inventory_sets"]["rows"],
                            info["inventory_minifigs"]["rows"],
                            total_rows,
                            info["inventory_parts"]["missing_parent_refs"],
                            info["inventory_sets"]["missing_parent_refs"],
                            info["inventory_minifigs"]["missing_parent_refs"],
                            Jsonb(info["inventory_parts"]["missing_parent_inventory_ids"]),
                            Jsonb(info["inventory_sets"]["missing_parent_inventory_ids"]),
                            Jsonb(info["inventory_minifigs"]["missing_parent_inventory_ids"]),
                            source_run_id,
                        ),
                    )

            elapsed = time.monotonic() - started

            print("==============================================================================")
            print(" [PASS] Rebrickable Phase 5A inventory staging completed")
            print(f" [INFO] Source run: {source_run_id}")
            print(f" [INFO] Total rows: {total_rows:,}")
            print(f" [INFO] Elapsed seconds: {elapsed:.2f}")
            print(" [INFO] Status: VALIDATING")
            print("==============================================================================")
            print("")
            print(
                "[NEXT] Phase 5B may reconcile this source run. "
                "No canonical definition/catalog DML was performed."
            )
            return 0

    except Exception as exc:
        elapsed = time.monotonic() - started
        print(
            f"[FAIL] Phase 5A after {elapsed:.2f}s: "
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
