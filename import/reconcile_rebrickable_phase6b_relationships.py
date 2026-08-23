#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
import time
from uuid import UUID

import psycopg

DEFAULT_SOURCE_RUN_ID = "01a02e65-b610-7d42-8e5e-87828deda6be"


def args():
    p = argparse.ArgumentParser()
    p.add_argument("--dsn", default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"))
    p.add_argument("--source-run-id", default=DEFAULT_SOURCE_RUN_ID)
    return p.parse_args()


def main():
    a = args()
    if not a.dsn:
        raise RuntimeError("BRICKTRACKR_IMPORT_DATABASE_URL / --dsn is required")

    source_run_id = UUID(a.source_run_id)

    print("==============================================================================")
    print(" BrickTrackr Rebrickable Phase 6B - semantic relationship reconcile")
    print("==============================================================================")
    print(f"[INFO] Source run: {source_run_id}")
    print("[INFO] Exact canonical mapping: A -> ALTERNATE")
    print("[INFO] B/M/P/R/T: preserved as source provenance; not collapsed to RELATED")

    started = time.perf_counter()

    with psycopg.connect(a.dsn) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT current_user::text")
            login = cur.fetchone()[0]

            cur.execute(
                "SELECT pg_has_role(%s::text, 'lego_importer'::text, 'MEMBER'::text)",
                (login,),
            )
            if not cur.fetchone()[0]:
                raise RuntimeError(f"{login!r} is not a member of lego_importer")

            cur.execute("SET ROLE lego_importer")

            cur.execute(
                """
                SELECT
                    staged_rows,
                    provenance_rows,
                    mapped_rows,
                    unmapped_rows,
                    quarantined_rows,
                    canonical_alternate_rows,
                    source_missing_rows
                FROM import.phase6b_reconcile(%s)
                """,
                (source_run_id,),
            )
            row = cur.fetchone()

        conn.commit()

    elapsed = time.perf_counter() - started

    (
        staged,
        provenance,
        mapped,
        unmapped,
        quarantined,
        canonical,
        source_missing,
    ) = row

    print(f"[INFO] Staged rows:               {staged:,}")
    print(f"[INFO] Provenance upserts:        {provenance:,}")
    print(f"[INFO] Canonically mapped:        {mapped:,}")
    print(f"[INFO] Source-valid unmapped:     {unmapped:,}")
    print(f"[INFO] Quarantined:               {quarantined:,}")
    print(f"[INFO] Canonical ALTERNATE links: {canonical:,}")
    print(f"[INFO] SOURCE_MISSING rows:       {source_missing:,}")
    print(f"[INFO] Elapsed seconds:           {elapsed:.2f}")

    print("")
    print("==============================================================================")
    print(" [PASS] Rebrickable Phase 6B semantic reconciliation completed")
    print("==============================================================================")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
