#!/usr/bin/env python3
"""
Download one complete fresh Rebrickable snapshot for BrickTrackr.

The caller supplies a run-specific output directory. All 12 archives are
downloaded fresh from Rebrickable, gzip/CSV validated, checksummed, and a
snapshot_manifest.json is written only after the complete snapshot succeeds.

This script performs no database work.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


BASE_URL = "https://cdn.rebrickable.com/media/downloads"

DATASETS = (
    "themes",
    "colors",
    "part_categories",
    "parts",
    "sets",
    "minifigs",
    "elements",
    "inventories",
    "inventory_parts",
    "inventory_sets",
    "inventory_minifigs",
    "part_relationships",
)

CHUNK_SIZE = 1024 * 1024
CONNECT_TIMEOUT = 30
READ_TIMEOUT = 180
MAX_ATTEMPTS = 5


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Download a complete fresh Rebrickable snapshot."
    )
    p.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Run-specific destination directory for the 12 *.csv.gz files.",
    )
    return p.parse_args()


def create_session() -> requests.Session:
    retry = Retry(
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
    s = requests.Session()
    s.headers.update(
        {
            "User-Agent": "BrickTrackr-Rebrickable-Importer/1.0",
            "Accept": "application/gzip,application/octet-stream,*/*",
            "Accept-Encoding": "identity",
        }
    )
    s.mount("https://", HTTPAdapter(max_retries=retry))
    return s


def validate_archive(path: Path) -> tuple[int, str, list[str]]:
    if not path.is_file() or path.stat().st_size <= 0:
        raise RuntimeError(f"{path.name}: archive is empty")

    digest = hashlib.sha256()
    with path.open("rb") as raw:
        for chunk in iter(lambda: raw.read(CHUNK_SIZE), b""):
            digest.update(chunk)

    row_count = 0
    with gzip.open(path, "rt", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration as exc:
            raise RuntimeError(f"{path.name}: CSV is empty") from exc

        if not header or not any(str(c).strip() for c in header):
            raise RuntimeError(f"{path.name}: CSV header is empty")

        for _ in reader:
            row_count += 1

    if row_count <= 0:
        raise RuntimeError(f"{path.name}: contains zero data rows")

    return row_count, digest.hexdigest(), header


def download_one(
    session: requests.Session,
    dataset: str,
    output_dir: Path,
) -> dict[str, object]:
    filename = f"{dataset}.csv.gz"
    url = f"{BASE_URL}/{filename}"
    final_path = output_dir / filename
    part_path = output_dir / f"{filename}.part"
    last_error: Exception | None = None

    # A run-specific directory should never contain a completed archive already.
    if final_path.exists():
        raise RuntimeError(
            f"{filename}: destination already exists; refusing stale/reused snapshot"
        )

    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            part_path.unlink(missing_ok=True)

            print(
                f"[*] Downloading {filename} "
                f"(attempt {attempt}/{MAX_ATTEMPTS})...",
                flush=True,
            )

            with session.get(
                url,
                stream=True,
                timeout=(CONNECT_TIMEOUT, READ_TIMEOUT),
            ) as response:
                response.raise_for_status()
                with part_path.open("wb") as out:
                    for chunk in response.iter_content(chunk_size=CHUNK_SIZE):
                        if chunk:
                            out.write(chunk)
                    out.flush()
                    os.fsync(out.fileno())

            row_count, sha256, headers = validate_archive(part_path)
            os.replace(part_path, final_path)

            size = final_path.stat().st_size
            print(
                f"[+] {filename}: {row_count:,} rows, {size:,} bytes, "
                f"sha256={sha256}",
                flush=True,
            )

            return {
                "dataset": dataset,
                "filename": filename,
                "url": url,
                "bytes": size,
                "rows": row_count,
                "sha256": sha256,
                "headers": headers,
            }

        except Exception as exc:
            last_error = exc
            part_path.unlink(missing_ok=True)

            if attempt >= MAX_ATTEMPTS:
                break

            delay = min(30, 2 ** (attempt - 1))
            print(
                f"[!] {filename}: {exc}; retrying in {delay}s",
                file=sys.stderr,
                flush=True,
            )
            time.sleep(delay)

    raise RuntimeError(
        f"{filename}: failed after {MAX_ATTEMPTS} attempts: {last_error}"
    )


def main() -> int:
    args = parse_args()
    output_dir = args.output_dir.resolve()

    if output_dir.exists() and any(output_dir.iterdir()):
        raise RuntimeError(
            f"Output directory is not empty; refusing snapshot reuse: {output_dir}"
        )

    output_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 79)
    print(" BrickTrackr fresh Rebrickable snapshot")
    print("=" * 79)
    print(f"Destination: {output_dir}")
    print(f"Datasets:    {len(DATASETS)}")
    print()

    started_at = datetime.now(timezone.utc)
    evidence: list[dict[str, object]] = []

    with create_session() as session:
        for dataset in DATASETS:
            evidence.append(download_one(session, dataset, output_dir))

    missing = [
        dataset
        for dataset in DATASETS
        if not (output_dir / f"{dataset}.csv.gz").is_file()
    ]
    if missing:
        raise RuntimeError(
            "Snapshot verification failed; missing: " + ", ".join(missing)
        )

    manifest = {
        "source": "REBRICKABLE",
        "base_url": BASE_URL,
        "started_at_utc": started_at.isoformat(),
        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
        "dataset_count": len(DATASETS),
        "datasets": evidence,
    }

    manifest_tmp = output_dir / "snapshot_manifest.json.part"
    manifest_path = output_dir / "snapshot_manifest.json"
    manifest_tmp.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(manifest_tmp, manifest_path)

    print()
    print(f"[PASS] Complete fresh snapshot ready: {len(DATASETS)} archives")
    print(f"[PASS] Manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n[FAIL] Download cancelled.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
