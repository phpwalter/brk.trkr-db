#!/usr/bin/env python3
"""
===============================================================================
 BrickTrackr Rebrickable Import - Phase 1
 File: import_rebrickable_phase1.py
===============================================================================

Purpose
-------
Create a provenance-backed Rebrickable source run and safely stage the first
authoritative reference datasets:

    - themes
    - colors
    - part_categories

This phase DOES NOT modify canonical BrickTrackr reference/catalog tables and
DOES NOT finalize the authoritative source run.

Successful terminal state for this phase:

    import.source_runs.status = VALIDATING
    each Phase-1 dataset status = VALIDATED

A later reconciliation phase must:
    1. reconcile staged records into canonical BrickTrackr entities/mappings;
    2. mark reconciled authoritative datasets COMPLETED;
    3. finalize the source run only after every required dataset is complete.

Security
--------
- No embedded/default database password.
- Requires BRICKTRACKR_IMPORT_DATABASE_URL or --dsn.
- Requires the connecting login to be a member of lego_importer.
- Executes database work as SET ROLE lego_importer.
- Writes only to import.source_runs, import.source_run_datasets, and
  import.source_stage_records in Phase 1.
- Never writes directly to canonical reference/catalog tables.

Network safety
--------------
- Downloads each .csv.gz completely before staging.
- Retries complete downloads after transport/gzip failures.
- fsyncs the archive.
- verifies gzip CRC/trailer by reading to EOF.
- computes SHA-256 on the downloaded archive.
- validates required CSV columns while tolerating additive source columns.
- validates and normalizes every record before any row from that dataset is
  staged.

Snapshot safety
---------------
ALL Phase-1 archives must download and validate before staging begins.
Therefore a network failure cannot leave a partially staged Phase-1 snapshot.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import io
import os
import re
import sys
import tempfile
import time

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterator
from uuid import UUID

import psycopg
import requests

from psycopg import Connection
from psycopg.types.json import Jsonb
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


# =============================================================================
# Configuration
# =============================================================================

REBRICKABLE_BASE_URL = "https://cdn.rebrickable.com/media/downloads"

HTTP_CONNECT_TIMEOUT_SECONDS = 20
HTTP_READ_TIMEOUT_SECONDS = 180
DOWNLOAD_MAX_ATTEMPTS = 5
DOWNLOAD_RETRY_BASE_DELAY_SECONDS = 2.0
DOWNLOAD_CHUNK_SIZE = 1024 * 1024

SOURCE_CODE = "REBRICKABLE"
IMPORTER_VERSION = "2.0.3"


@dataclass(frozen=True, slots=True)
class DatasetContract:
    name: str
    entity_namespace: str
    required_headers: tuple[str, ...]
    normalize: Callable[[dict[str, str], int], dict[str, Any]]
    identity_field: str


@dataclass(frozen=True, slots=True)
class DownloadedDataset:
    contract: DatasetContract
    archive_path: Path
    checksum_sha256_hex: str
    source_row_count: int


# =============================================================================
# Normalization
# =============================================================================

_RGB_HEX_RE = re.compile(r"^[0-9A-Fa-f]{6}$")


def require_text(value: str | None, field: str, row_number: int) -> str:
    normalized = (value or "").strip()
    if not normalized:
        raise ValueError(
            f"row {row_number}: required field {field!r} is empty"
        )
    return normalized


def require_int(value: str | None, field: str, row_number: int) -> int:
    text = require_text(value, field, row_number)
    try:
        return int(text)
    except ValueError as exc:
        raise ValueError(
            f"row {row_number}: field {field!r} must be an integer; got {text!r}"
        ) from exc


def optional_int(value: str | None, field: str, row_number: int) -> int | None:
    text = (value or "").strip()
    if not text:
        return None
    try:
        return int(text)
    except ValueError as exc:
        raise ValueError(
            f"row {row_number}: field {field!r} must be an integer or empty; "
            f"got {text!r}"
        ) from exc


def parse_bool(value: str | None, field: str, row_number: int) -> bool:
    text = require_text(value, field, row_number).lower()
    if text in {"true", "t", "1", "yes"}:
        return True
    if text in {"false", "f", "0", "no"}:
        return False
    raise ValueError(
        f"row {row_number}: field {field!r} must be boolean; got {value!r}"
    )


def normalize_theme(row: dict[str, str], row_number: int) -> dict[str, Any]:
    theme_id = require_int(row.get("id"), "id", row_number)
    parent_id = optional_int(row.get("parent_id"), "parent_id", row_number)

    if parent_id == theme_id:
        raise ValueError(
            f"row {row_number}: theme {theme_id} cannot be its own parent"
        )

    return {
        "id": theme_id,
        "name": require_text(row.get("name"), "name", row_number),
        "parent_id": parent_id,
    }


def normalize_color(row: dict[str, str], row_number: int) -> dict[str, Any]:
    rgb = require_text(row.get("rgb"), "rgb", row_number).upper()
    if not _RGB_HEX_RE.fullmatch(rgb):
        raise ValueError(
            f"row {row_number}: rgb must be exactly six hexadecimal digits; "
            f"got {rgb!r}"
        )

    return {
        "id": require_int(row.get("id"), "id", row_number),
        "name": require_text(row.get("name"), "name", row_number),
        "rgb": rgb,
        "is_trans": parse_bool(row.get("is_trans"), "is_trans", row_number),
    }


def normalize_part_category(
    row: dict[str, str],
    row_number: int,
) -> dict[str, Any]:
    return {
        "id": require_int(row.get("id"), "id", row_number),
        "name": require_text(row.get("name"), "name", row_number),
    }


PHASE1_DATASETS: tuple[DatasetContract, ...] = (
    DatasetContract(
        name="themes",
        entity_namespace="THEME",
        required_headers=("id", "name", "parent_id"),
        normalize=normalize_theme,
        identity_field="id",
    ),
    DatasetContract(
        name="colors",
        entity_namespace="COLOR",
        required_headers=("id", "name", "rgb", "is_trans"),
        normalize=normalize_color,
        identity_field="id",
    ),
    DatasetContract(
        name="part_categories",
        entity_namespace="PART_CATEGORY",
        required_headers=("id", "name"),
        normalize=normalize_part_category,
        identity_field="id",
    ),
)


# =============================================================================
# HTTP / download
# =============================================================================

def create_http_session() -> requests.Session:
    retry_policy = Retry(
        total=4,
        connect=4,
        read=4,
        status=4,
        backoff_factor=1.0,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset({"GET", "HEAD"}),
        raise_on_status=False,
        respect_retry_after_header=True,
    )

    adapter = HTTPAdapter(
        max_retries=retry_policy,
        pool_connections=4,
        pool_maxsize=4,
    )

    session = requests.Session()
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    session.headers.update(
        {
            "User-Agent": "BrickTrackr-Rebrickable-Importer/2.0",
            "Accept": "application/gzip,application/octet-stream,*/*",
        }
    )
    return session


def verify_gzip_archive(path: Path) -> None:
    with gzip.open(path, "rb") as stream:
        while stream.read(DOWNLOAD_CHUNK_SIZE):
            pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(DOWNLOAD_CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def validate_and_count_csv(
    archive_path: Path,
    contract: DatasetContract,
) -> int:
    """
    Validate the entire CSV before staging.

    Required source columns are strict. Additive Rebrickable columns are tolerated
    and ignored unless/until BrickTrackr explicitly adopts them. Missing or
    renamed required columns abort the import.
    """
    seen_ids: set[Any] = set()
    row_count = 0

    with gzip.open(archive_path, "rb") as gz:
        with io.TextIOWrapper(gz, encoding="utf-8-sig", newline="") as text:
            reader = csv.DictReader(text)

            if reader.fieldnames is None:
                raise RuntimeError(
                    f"{contract.name}: CSV header is missing"
                )

            actual_headers = tuple(reader.fieldnames)
            missing_headers = tuple(
                header
                for header in contract.required_headers
                if header not in actual_headers
            )

            if missing_headers:
                raise RuntimeError(
                    f"{contract.name}: CSV header contract mismatch. "
                    f"Missing required columns {missing_headers!r}; "
                    f"received {actual_headers!r}"
                )

            extra_headers = tuple(
                header
                for header in actual_headers
                if header not in contract.required_headers
            )

            if extra_headers:
                print(
                    f"[i] {contract.name}: ignoring additional source columns "
                    f"{extra_headers!r}"
                )

            for logical_row_number, row in enumerate(reader, start=1):
                normalized = contract.normalize(row, logical_row_number)
                identity = normalized[contract.identity_field]

                if identity in seen_ids:
                    raise RuntimeError(
                        f"{contract.name}: duplicate source identity "
                        f"{identity!r} at data row {logical_row_number}"
                    )

                seen_ids.add(identity)
                row_count += 1

    if row_count == 0:
        raise RuntimeError(f"{contract.name}: dataset contains zero data rows")

    return row_count


def download_dataset(
    contract: DatasetContract,
    work_dir: Path,
) -> DownloadedDataset:
    url = f"{REBRICKABLE_BASE_URL}/{contract.name}.csv.gz"
    last_exception: Exception | None = None

    for attempt in range(1, DOWNLOAD_MAX_ATTEMPTS + 1):
        archive_path = work_dir / f"{contract.name}.csv.gz"
        session = create_http_session()

        try:
            if archive_path.exists():
                archive_path.unlink()

            print(
                f"[*] Downloading {contract.name}.csv.gz "
                f"(attempt {attempt}/{DOWNLOAD_MAX_ATTEMPTS})..."
            )

            with archive_path.open("wb") as target:
                with session.get(
                    url,
                    stream=True,
                    timeout=(
                        HTTP_CONNECT_TIMEOUT_SECONDS,
                        HTTP_READ_TIMEOUT_SECONDS,
                    ),
                ) as response:
                    response.raise_for_status()

                    for chunk in response.iter_content(
                        chunk_size=DOWNLOAD_CHUNK_SIZE
                    ):
                        if chunk:
                            target.write(chunk)

                target.flush()
                os.fsync(target.fileno())

            if archive_path.stat().st_size <= 0:
                raise RuntimeError(
                    f"{contract.name}: downloaded archive is empty"
                )

            verify_gzip_archive(archive_path)
            checksum = sha256_file(archive_path)
            row_count = validate_and_count_csv(archive_path, contract)

            print(
                f"[+] {contract.name}: verified "
                f"{row_count:,} rows, sha256={checksum}"
            )

            return DownloadedDataset(
                contract=contract,
                archive_path=archive_path,
                checksum_sha256_hex=checksum,
                source_row_count=row_count,
            )

        except (
            requests.exceptions.RequestException,
            ConnectionResetError,
            ConnectionAbortedError,
            BrokenPipeError,
            EOFError,
            gzip.BadGzipFile,
            OSError,
            RuntimeError,
            ValueError,
        ) as exc:
            last_exception = exc

            try:
                if archive_path.exists():
                    archive_path.unlink()
            except OSError:
                pass

            # Contract/data errors are deterministic and should not be retried.
            if isinstance(exc, (ValueError, RuntimeError)) and not isinstance(
                exc, requests.exceptions.RequestException
            ):
                raise

            if attempt >= DOWNLOAD_MAX_ATTEMPTS:
                break

            delay = DOWNLOAD_RETRY_BASE_DELAY_SECONDS * (2 ** (attempt - 1))
            print(
                f"[!] Download failure for {contract.name}: {exc}",
                file=sys.stderr,
            )
            print(f"[*] Retrying in {delay:.1f}s...")
            time.sleep(delay)

        finally:
            session.close()

    raise RuntimeError(
        f"{contract.name}: unable to download after "
        f"{DOWNLOAD_MAX_ATTEMPTS} attempts; last error={last_exception}"
    )


# =============================================================================
# Database contract
# =============================================================================

def preflight_database(conn: Connection) -> None:
    """
    Verify the BrickTrackr import contract before any source-run writes.

    The current login is resolved in its own SELECT and then passed back as a
    normal text parameter to pg_has_role(). This deliberately avoids
    schema-qualifying PostgreSQL special expressions such as current_user.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT current_user::text;")
        row = cur.fetchone()
        if row is None:
            raise RuntimeError("could not resolve current PostgreSQL user")

        current_login = row[0]

        cur.execute(
            """
            SELECT
                to_regclass('import.source_runs') IS NOT NULL,
                to_regclass('import.source_run_datasets') IS NOT NULL,
                to_regclass('import.source_stage_records') IS NOT NULL,
                EXISTS (
                    SELECT 1
                    FROM pg_catalog.pg_roles
                    WHERE rolname = 'lego_importer'
                ),
                pg_catalog.pg_has_role(
                    %s::text,
                    'lego_importer'::text,
                    'MEMBER'::text
                ),
                EXISTS (
                    SELECT 1
                    FROM reference.external_sources
                    WHERE source_code = %s
                );
            """,
            (current_login, SOURCE_CODE),
        )

        result = cur.fetchone()
        if result is None:
            raise RuntimeError("database preflight returned no result")

        (
            has_runs,
            has_datasets,
            has_stage,
            has_importer_role,
            is_importer_member,
            has_source,
        ) = result

        failures: list[str] = []

        if not has_runs:
            failures.append("import.source_runs is missing")
        if not has_datasets:
            failures.append("import.source_run_datasets is missing")
        if not has_stage:
            failures.append("import.source_stage_records is missing")
        if not has_importer_role:
            failures.append("lego_importer role is missing")
        if has_importer_role and not is_importer_member:
            failures.append(
                f"connecting login {current_login!r} is not a member of lego_importer"
            )
        if not has_source:
            failures.append(
                "reference.external_sources does not contain REBRICKABLE"
            )

        if failures:
            raise RuntimeError(
                "database import preflight failed: " + "; ".join(failures)
            )

        cur.execute("SET ROLE lego_importer")

    conn.commit()


def create_source_run(conn: Connection) -> UUID:
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
            RETURNING source_run_id;
            """,
            (
                Jsonb(
                    {
                        "importer": "import_rebrickable_phase1.py",
                        "phase": 1,
                        "datasets": [d.name for d in PHASE1_DATASETS],
                    }
                ),
                SOURCE_CODE,
            ),
        )
        row = cur.fetchone()
        if row is None:
            raise RuntimeError("failed to create Rebrickable source run")

        source_run_id = row[0]

        for contract in PHASE1_DATASETS:
            cur.execute(
                """
                INSERT INTO import.source_run_datasets (
                    source_run_id,
                    dataset_name,
                    status,
                    is_authoritative_scope,
                    started_at
                )
                VALUES (
                    %s,
                    %s,
                    'PENDING'::import.dataset_status,
                    true,
                    now()
                );
                """,
                (source_run_id, contract.name),
            )

    conn.commit()
    return source_run_id


def record_dataset_download(
    conn: Connection,
    source_run_id: UUID,
    dataset: DownloadedDataset,
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE import.source_run_datasets
            SET
                status = 'DOWNLOADED'::import.dataset_status,
                source_row_count = %s,
                checksum_sha256 = decode(%s, 'hex')
            WHERE source_run_id = %s
              AND dataset_name = %s;
            """,
            (
                dataset.source_row_count,
                dataset.checksum_sha256_hex,
                source_run_id,
                dataset.contract.name,
            ),
        )

        if cur.rowcount != 1:
            raise RuntimeError(
                f"failed to record downloaded dataset "
                f"{dataset.contract.name!r}"
            )

    conn.commit()


def set_run_status(
    conn: Connection,
    source_run_id: UUID,
    status: str,
) -> None:
    allowed = {"STARTED", "STAGING", "VALIDATING", "FINALIZING"}
    if status not in allowed:
        raise ValueError(f"unsupported nonterminal run status {status!r}")

    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE import.source_runs
            SET status = %s::import.source_run_status
            WHERE source_run_id = %s;
            """,
            (status, source_run_id),
        )

        if cur.rowcount != 1:
            raise RuntimeError(
                f"source run {source_run_id} could not transition to {status}"
            )

    conn.commit()


def mark_run_failed(
    conn: Connection,
    source_run_id: UUID,
    message: str,
    dataset_name: str | None = None,
) -> None:
    """
    Best-effort failure recording.

    Never masks the original import exception.
    """
    try:
        conn.rollback()

        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE import.source_runs
                SET
                    status = 'FAILED'::import.source_run_status,
                    failed_at = now(),
                    completed_at = NULL,
                    failure_message = %s
                WHERE source_run_id = %s;
                """,
                (message[:8000], source_run_id),
            )

            if dataset_name is not None:
                cur.execute(
                    """
                    UPDATE import.source_run_datasets
                    SET
                        status = 'FAILED'::import.dataset_status,
                        completed_at = now()
                    WHERE source_run_id = %s
                      AND dataset_name = %s;
                    """,
                    (source_run_id, dataset_name),
                )

        conn.commit()

    except Exception as failure_record_error:
        print(
            f"[!] Unable to record failed source run: {failure_record_error}",
            file=sys.stderr,
        )
        try:
            conn.rollback()
        except Exception:
            pass


# =============================================================================
# Staging
# =============================================================================

def iter_normalized_records(
    dataset: DownloadedDataset,
) -> Iterator[tuple[int, dict[str, Any]]]:
    contract = dataset.contract

    with gzip.open(dataset.archive_path, "rb") as gz:
        with io.TextIOWrapper(gz, encoding="utf-8-sig", newline="") as text:
            reader = csv.DictReader(text)

            # Already validated before staging, but recheck to prevent the
            # archive from being swapped/mutated between validation and COPY.
            actual_headers = tuple(reader.fieldnames or ())
            missing_headers = tuple(
                header
                for header in contract.required_headers
                if header not in actual_headers
            )

            if missing_headers:
                raise RuntimeError(
                    f"{contract.name}: required header(s) disappeared after "
                    f"validation: {missing_headers!r}"
                )

            for logical_row_number, row in enumerate(reader, start=1):
                yield (
                    logical_row_number,
                    contract.normalize(row, logical_row_number),
                )


def stage_dataset(
    conn: Connection,
    source_run_id: UUID,
    dataset: DownloadedDataset,
) -> None:
    contract = dataset.contract
    staged_count = 0

    print(f"[*] Staging {contract.name}...")

    with conn.cursor() as cur:
        # Defensive retry behavior: Phase 1 may be rerun for the same source
        # run by an operator without duplicating staging rows.
        cur.execute(
            """
            DELETE FROM import.source_stage_records
            WHERE source_run_id = %s
              AND dataset_name = %s;
            """,
            (source_run_id, contract.name),
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
            for row_number, payload in iter_normalized_records(dataset):
                copy.write_row(
                    (
                        source_run_id,
                        contract.name,
                        contract.entity_namespace,
                        row_number,
                        Jsonb(payload),
                    )
                )
                staged_count += 1

        if staged_count != dataset.source_row_count:
            raise RuntimeError(
                f"{contract.name}: staged row count {staged_count:,} does not "
                f"match validated source row count "
                f"{dataset.source_row_count:,}"
            )

        cur.execute(
            """
            UPDATE import.source_run_datasets
            SET
                status = 'VALIDATED'::import.dataset_status,
                staged_row_count = %s
            WHERE source_run_id = %s
              AND dataset_name = %s
              AND source_row_count = %s;
            """,
            (
                staged_count,
                source_run_id,
                contract.name,
                dataset.source_row_count,
            ),
        )

        if cur.rowcount != 1:
            raise RuntimeError(
                f"{contract.name}: failed to record validated staging state"
            )

    conn.commit()

    print(f"[+] {contract.name}: staged and validated {staged_count:,} rows")


# =============================================================================
# Main orchestration
# =============================================================================

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "BrickTrackr Rebrickable importer Phase 1: "
            "download, validate and stage reference datasets"
        )
    )
    parser.add_argument(
        "--dsn",
        default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"),
        help=(
            "PostgreSQL DSN. Prefer BRICKTRACKR_IMPORT_DATABASE_URL. "
            "No default credentials are supplied."
        ),
    )
    parser.add_argument(
        "--work-dir",
        type=Path,
        default=None,
        help=(
            "Directory for downloaded archives. Default: secure temporary "
            "directory."
        ),
    )
    parser.add_argument(
        "--keep-downloads",
        action="store_true",
        help="Keep downloaded .csv.gz files after the run.",
    )
    return parser.parse_args()


def run(args: argparse.Namespace) -> int:
    if not args.dsn:
        print(
            "[FAIL] BRICKTRACKR_IMPORT_DATABASE_URL or --dsn is required.",
            file=sys.stderr,
        )
        return 2

    temp_dir: tempfile.TemporaryDirectory[str] | None = None

    if args.work_dir is None:
        temp_dir = tempfile.TemporaryDirectory(prefix="bricktrackr_rebrickable_")
        work_dir = Path(temp_dir.name)
    else:
        work_dir = args.work_dir.resolve()
        work_dir.mkdir(parents=True, exist_ok=True)

    source_run_id: UUID | None = None
    active_dataset: str | None = None

    try:
        print("===============================================================================")
        print(f" BrickTrackr Rebrickable Import - Phase 1 v{IMPORTER_VERSION}")
        print("===============================================================================")
        print(f"Work directory: {work_dir}")

        with psycopg.connect(args.dsn) as conn:
            preflight_database(conn)
            print("[+] Database import contract verified.")

            source_run_id = create_source_run(conn)
            print(f"[+] Created source run: {source_run_id}")

            # -----------------------------------------------------------------
            # Download + validate ALL Phase-1 datasets before staging any.
            # -----------------------------------------------------------------
            downloaded: list[DownloadedDataset] = []

            for contract in PHASE1_DATASETS:
                active_dataset = contract.name
                dataset = download_dataset(contract, work_dir)
                record_dataset_download(conn, source_run_id, dataset)
                downloaded.append(dataset)

            print("[+] All Phase-1 archives downloaded and validated.")

            # -----------------------------------------------------------------
            # Stage only after the complete Phase-1 snapshot is available.
            # -----------------------------------------------------------------
            set_run_status(conn, source_run_id, "STAGING")

            for dataset in downloaded:
                active_dataset = dataset.contract.name
                stage_dataset(conn, source_run_id, dataset)

            # Phase 1 intentionally stops here. Canonical reconciliation is a
            # separate reviewed phase.
            set_run_status(conn, source_run_id, "VALIDATING")
            active_dataset = None

            print("===============================================================================")
            print(" [PASS] Rebrickable Phase 1 staged successfully")
            print("===============================================================================")
            print(f"Source run: {source_run_id}")
            print("Run status: VALIDATING")
            print("Canonical tables modified: NO")
            print("Next step: Phase 2 reference reconciliation")
            return 0

    except KeyboardInterrupt:
        if source_run_id is not None:
            try:
                with psycopg.connect(args.dsn) as failure_conn:
                    preflight_database(failure_conn)
                    mark_run_failed(
                        failure_conn,
                        source_run_id,
                        "Phase 1 interrupted by operator",
                        active_dataset,
                    )
            except Exception:
                pass
        print("[FAIL] Import interrupted.", file=sys.stderr)
        return 130

    except Exception as exc:
        if source_run_id is not None:
            try:
                with psycopg.connect(args.dsn) as failure_conn:
                    preflight_database(failure_conn)
                    mark_run_failed(
                        failure_conn,
                        source_run_id,
                        f"Phase 1 failed: {type(exc).__name__}: {exc}",
                        active_dataset,
                    )
            except Exception as record_exc:
                print(
                    f"[!] Could not record failed run: {record_exc}",
                    file=sys.stderr,
                )

        print(
            f"[FAIL] Rebrickable Phase 1: {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1

    finally:
        if temp_dir is not None:
            if args.keep_downloads:
                # TemporaryDirectory cannot be retained safely after cleanup;
                # copy to a user-specified --work-dir when retention is needed.
                print(
                    "[!] --keep-downloads with an automatic temporary directory "
                    "cannot retain files. Use --work-dir to retain downloads.",
                    file=sys.stderr,
                )
            temp_dir.cleanup()
        elif not args.keep_downloads:
            for contract in PHASE1_DATASETS:
                path = work_dir / f"{contract.name}.csv.gz"
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass


def main() -> None:
    raise SystemExit(run(parse_args()))


if __name__ == "__main__":
    main()
