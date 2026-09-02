#!/usr/bin/env python3
"""
BrickTrackr Rebrickable Import - Phase 3 Staging

Downloads, verifies, validates and stages:
    parts.csv.gz
    sets.csv.gz
    minifigs.csv.gz

No canonical catalog tables are modified by this process.  Reconciliation is
performed separately by import.reconcile_rebrickable_catalog(uuid).
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import io
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

import psycopg

# Windows PowerShell commonly launches Python with a legacy console code page.
# Rebrickable catalog text is UTF-8 and may contain characters outside cp1252.
# Force UTF-8 for console I/O while keeping output resilient if a host still
# cannot render a glyph.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace")

IMPORTER_VERSION = "3.0.3"
SOURCE_CODE = "REBRICKABLE"

CHUNK_SIZE = 1024 * 1024


@dataclass(frozen=True, slots=True)
class DatasetContract:
    name: str
    entity_namespace: str
    required_headers: tuple[str, ...]


DATASETS = (
    DatasetContract(
        "parts",
        "PART",
        ("part_num", "name", "part_cat_id"),
    ),
    DatasetContract(
        "sets",
        "SET",
        ("set_num", "name", "year", "theme_id", "num_parts", "img_url"),
    ),
    DatasetContract(
        "minifigs",
        "MINIFIGURE",
        ("fig_num", "name", "num_parts", "img_url"),
    ),
)



def emit_encoding_diagnostics() -> None:
    """Emit startup encoding state without depending on TextIOWrapper encoding."""
    import locale

    details = (
        "[ENCODING] "
        f"utf8_mode={sys.flags.utf8_mode}; "
        f"stdout={getattr(sys.stdout, 'encoding', None)}; "
        f"stderr={getattr(sys.stderr, 'encoding', None)}; "
        f"preferred={locale.getpreferredencoding(False)}; "
        f"PGCLIENTENCODING={os.getenv('PGCLIENTENCODING')}\n"
    )
    os.write(1, details.encode("ascii", "backslashreplace"))


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--dsn",
        default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"),
    )
    p.add_argument(
        "--work-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "rebrickable-downloads",
    )
    return p.parse_args()


def sha256_file(path: Path) -> bytes:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.digest()


def validate_archive(
    contract: DatasetContract,
    path: Path,
) -> tuple[int, tuple[str, ...]]:
    seen_ids: set[str] = set()
    id_column = {
        "parts": "part_num",
        "sets": "set_num",
        "minifigs": "fig_num",
    }[contract.name]

    count = 0
    with gzip.open(path, "rb") as gz:
        with io.TextIOWrapper(
            gz,
            encoding="utf-8-sig",
            newline="",
        ) as text:
            reader = csv.DictReader(text)
            if reader.fieldnames is None:
                raise RuntimeError(
                    f"{contract.name}: CSV has no header"
                )

            headers = tuple(reader.fieldnames)
            missing = tuple(
                h for h in contract.required_headers
                if h not in headers
            )
            if missing:
                raise RuntimeError(
                    f"{contract.name}: missing required CSV headers {missing}; "
                    f"received {headers}"
                )

            extras = tuple(
                h for h in headers
                if h not in contract.required_headers
            )
            if extras:
                print(
                    f"[i] {contract.name}: preserving additional source "
                    f"columns {extras}"
                )

            for row_number, row in enumerate(reader, start=2):
                external_id = (row.get(id_column) or "").strip()
                name = (row.get("name") or "").strip()

                if not external_id:
                    raise RuntimeError(
                        f"{contract.name}: blank {id_column} "
                        f"at CSV row {row_number}"
                    )
                if not name:
                    raise RuntimeError(
                        f"{contract.name}: blank name "
                        f"at CSV row {row_number}"
                    )
                if external_id in seen_ids:
                    raise RuntimeError(
                        f"{contract.name}: duplicate source ID "
                        f"{external_id!r}"
                    )

                seen_ids.add(external_id)
                count += 1

    if count == 0:
        raise RuntimeError(f"{contract.name}: dataset contains no rows")

    return count, headers


def preflight(conn: psycopg.Connection) -> tuple[str, int]:
    # Rebrickable contains arbitrary Unicode catalog text.  Do not inherit a
    # Windows-specific libpq/client encoding such as WIN1252 from the host.
    conn.execute("SET client_encoding TO 'UTF8'")
    conn.commit()

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                current_user::text,
                current_setting('client_encoding')
            """
        )
        login, client_encoding = cur.fetchone()

        if client_encoding.upper().replace("-", "") != "UTF8":
            raise RuntimeError(
                f"PostgreSQL client_encoding must be UTF8; negotiated "
                f"{client_encoding!r}"
            )

        print(f"[+] PostgreSQL client_encoding: {client_encoding}")

        cur.execute(
            """
            SELECT
                pg_has_role(%s::text, 'brktrkr_import'::text, 'MEMBER'::text),
                to_regclass('import.source_runs') IS NOT NULL,
                to_regclass('import.source_run_datasets') IS NOT NULL,
                to_regclass('import.source_stage_records') IS NOT NULL,
                (
                    SELECT source_id
                    FROM reference.external_sources
                    WHERE source_code = %s
                    LIMIT 1
                )
            """,
            (login, SOURCE_CODE),
        )
        is_importer, has_runs, has_datasets, has_stage, source_id = cur.fetchone()

        failures: list[str] = []
        if not is_importer:
            failures.append(
                f"login {login!r} is not a member of brktrkr_import"
            )
        if not has_runs:
            failures.append("import.source_runs is missing")
        if not has_datasets:
            failures.append("import.source_run_datasets is missing")
        if not has_stage:
            failures.append("import.source_stage_records is missing")
        if source_id is None:
            failures.append("REBRICKABLE external source is missing")

        if failures:
            raise RuntimeError("; ".join(failures))

        cur.execute("SET ROLE brktrkr_import")

    conn.commit()
    return login, int(source_id)


def create_run(
    conn: psycopg.Connection,
    source_id: int,
) -> UUID:
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
                %s::jsonb
            )
            RETURNING source_run_id
            """,
            (
                source_id,
                json.dumps(
                    {
                        "importer": "rebrickable_phase3",
                        "importer_version": IMPORTER_VERSION,
                    }
                ),
            ),
        )
        source_run_id = cur.fetchone()[0]

        for contract in DATASETS:
            cur.execute(
                """
                INSERT INTO import.source_run_datasets (
                    source_run_id,
                    dataset_name,
                    status,
                    is_authoritative_scope,
                    started_at
                )
                VALUES (%s, %s, 'PENDING', true, now())
                """,
                (source_run_id, contract.name),
            )

    conn.commit()
    return source_run_id


def record_download(
    conn: psycopg.Connection,
    source_run_id: UUID,
    contract: DatasetContract,
    row_count: int,
    checksum: bytes,
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE import.source_run_datasets
            SET
                status = 'DOWNLOADED',
                source_row_count = %s,
                checksum_sha256 = %s
            WHERE source_run_id = %s
              AND dataset_name = %s
            """,
            (
                row_count,
                checksum,
                source_run_id,
                contract.name,
            ),
        )
    conn.commit()


def stage_dataset(
    conn: psycopg.Connection,
    source_run_id: UUID,
    contract: DatasetContract,
    path: Path,
) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            DELETE FROM import.source_stage_records
            WHERE source_run_id = %s
              AND dataset_name = %s
            """,
            (source_run_id, contract.name),
        )

        staged = 0
        with gzip.open(path, "rb") as gz:
            with io.TextIOWrapper(
                gz,
                encoding="utf-8-sig",
                newline="",
            ) as text:
                reader = csv.DictReader(text)
                if reader.fieldnames is None:
                    raise RuntimeError(
                        f"{contract.name}: CSV has no header during staging"
                    )

                missing = [
                    h for h in contract.required_headers
                    if h not in reader.fieldnames
                ]
                if missing:
                    raise RuntimeError(
                        f"{contract.name}: required headers changed "
                        f"between validation and staging: {missing}"
                    )

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
                    for source_row_number, row in enumerate(reader, start=1):
                        normalized = {
                            key: (value.strip() if value is not None else None)
                            for key, value in row.items()
                            if key is not None
                        }
                        copy.write_row(
                            (
                                source_run_id,
                                contract.name,
                                contract.entity_namespace,
                                source_row_number,
                                json.dumps(
                                    normalized,
                                    ensure_ascii=False,
                                    separators=(",", ":"),
                                ),
                            )
                        )
                        staged += 1

        cur.execute(
            """
            UPDATE import.source_run_datasets
            SET
                status = 'VALIDATED',
                staged_row_count = %s
            WHERE source_run_id = %s
              AND dataset_name = %s
            """,
            (staged, source_run_id, contract.name),
        )

    conn.commit()
    return staged


def fail_run(
    conn: psycopg.Connection,
    source_run_id: UUID | None,
    message: str,
) -> None:
    if source_run_id is None:
        return
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE import.source_runs
                SET
                    status = 'FAILED',
                    failed_at = now(),
                    failure_message = left(%s, 4000)
                WHERE source_run_id = %s
                  AND status <> 'COMPLETED'
                """,
                (message, source_run_id),
            )
        conn.commit()
    except Exception:
        conn.rollback()


def run() -> int:
    emit_encoding_diagnostics()
    args = parse_args()
    if not args.dsn:
        print(
            "[FAIL] BRICKTRACKR_IMPORT_DATABASE_URL or --dsn is required.",
            file=sys.stderr,
        )
        return 2

    print("==============================================================================")
    print(f" BrickTrackr Rebrickable Import - Phase 3 Staging v{IMPORTER_VERSION}")
    print("==============================================================================")

    source_run_id: UUID | None = None
    downloaded: dict[str, Path] = {}

    try:
        args.work_dir.mkdir(parents=True, exist_ok=True)

        # Validate the prepared Phase-3 snapshot before database staging.
        # Network I/O belongs to the top-level initial/nightly wrapper.
        evidence: dict[str, tuple[int, bytes]] = {}
        for contract in DATASETS:
            path = args.work_dir / f"{contract.name}.csv.gz"
            if not path.is_file():
                raise RuntimeError(
                    f"{contract.name}: required snapshot archive not found: {path}"
                )
            if path.stat().st_size <= 0:
                raise RuntimeError(
                    f"{contract.name}: snapshot archive is empty: {path}"
                )

            downloaded[contract.name] = path
            row_count, _headers = validate_archive(contract, path)
            checksum = sha256_file(path)
            evidence[contract.name] = (row_count, checksum)
            print(
                f"[+] {contract.name}: snapshot verified {row_count:,} rows, "
                f"sha256={checksum.hex()}"
            )

        with psycopg.connect(args.dsn, options='-c client_encoding=UTF8') as conn:
            login, source_id = preflight(conn)
            print(f"[+] Database contract verified for login {login!r}.")

            source_run_id = create_run(conn, source_id)
            print(f"[*] Created source run: {source_run_id}")

            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE import.source_runs
                    SET status = 'STAGING'
                    WHERE source_run_id = %s
                    """,
                    (source_run_id,),
                )
            conn.commit()

            for contract in DATASETS:
                row_count, checksum = evidence[contract.name]
                record_download(
                    conn,
                    source_run_id,
                    contract,
                    row_count,
                    checksum,
                )
                staged = stage_dataset(
                    conn,
                    source_run_id,
                    contract,
                    downloaded[contract.name],
                )
                if staged != row_count:
                    raise RuntimeError(
                        f"{contract.name}: source/staged count mismatch "
                        f"{row_count} != {staged}"
                    )
                print(f"[+] {contract.name}: staged {staged:,} rows.")

            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE import.source_runs
                    SET status = 'VALIDATING'
                    WHERE source_run_id = %s
                    """,
                    (source_run_id,),
                )
            conn.commit()

        print("==============================================================================")
        print(" [PASS] Rebrickable Phase 3 staging completed successfully")
        print(f" Source run: {source_run_id}")
        print(" Next: run Phase 3 reconciliation")
        print("==============================================================================")
        return 0

    except KeyboardInterrupt:
        print("[FAIL] Phase 3 interrupted by operator.", file=sys.stderr)
        return 130
    except Exception as exc:
        if args.dsn and source_run_id is not None:
            try:
                with psycopg.connect(args.dsn, options='-c client_encoding=UTF8') as conn:
                    with conn.cursor() as cur:
                        cur.execute("SET ROLE brktrkr_import")
                    conn.commit()
                    fail_run(conn, source_run_id, str(exc))
            except Exception:
                pass

        print(
            f"[FAIL] Rebrickable Phase 3 staging: "
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1

if __name__ == "__main__":
    raise SystemExit(run())
