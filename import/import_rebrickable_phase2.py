#!/usr/bin/env python3
"""
BrickTrackr Rebrickable Import - Phase 2
----------------------------------------
Reconcile a validated Phase-1 Rebrickable source run into canonical reference
data by calling the reviewed database SECURITY DEFINER function.

This client performs no direct canonical DML.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from uuid import UUID

import psycopg

IMPORTER_VERSION = "2.1.0"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Reconcile validated Rebrickable Phase-1 reference staging"
    )
    p.add_argument(
        "--dsn",
        default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"),
        help="PostgreSQL DSN; defaults to BRICKTRACKR_IMPORT_DATABASE_URL",
    )
    p.add_argument(
        "--source-run-id",
        type=UUID,
        default=None,
        help="Specific validated Rebrickable source run. Default: latest eligible run.",
    )
    return p.parse_args()


def preflight(conn: psycopg.Connection) -> str:
    with conn.cursor() as cur:
        cur.execute("SELECT current_user::text")
        login = cur.fetchone()[0]

        cur.execute(
            """
            SELECT
                pg_has_role(%s::text, 'lego_importer'::text, 'MEMBER'::text),
                to_regprocedure(
                    'import.reconcile_rebrickable_reference(uuid)'
                ) IS NOT NULL
            """,
            (login,),
        )
        is_importer, has_function = cur.fetchone()

        if not is_importer:
            raise RuntimeError(
                f"PostgreSQL login {login!r} is not a member of lego_importer"
            )
        if not has_function:
            raise RuntimeError(
                "import.reconcile_rebrickable_reference(uuid) is not installed"
            )

        cur.execute("SET ROLE lego_importer")

    conn.commit()
    return login


def find_latest_eligible_run(conn: psycopg.Connection) -> UUID:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT r.source_run_id
            FROM import.source_runs AS r
            JOIN reference.external_sources AS s
              ON s.source_id = r.source_id
            WHERE s.source_code = 'REBRICKABLE'
              AND r.status IN ('VALIDATING', 'FINALIZING')
              AND NOT EXISTS (
                  SELECT 1
                  FROM (
                      VALUES ('themes'), ('colors'), ('part_categories')
                  ) AS required(dataset_name)
                  LEFT JOIN import.source_run_datasets AS d
                    ON d.source_run_id = r.source_run_id
                   AND d.dataset_name = required.dataset_name
                  WHERE d.source_run_dataset_id IS NULL
                     OR d.status NOT IN ('VALIDATED', 'COMPLETED')
              )
            ORDER BY r.started_at DESC
            LIMIT 1
            """
        )
        row = cur.fetchone()

    if row is None:
        raise RuntimeError(
            "No eligible Rebrickable Phase-1 source run is waiting for reconciliation"
        )
    return row[0]


def run() -> int:
    args = parse_args()

    if not args.dsn:
        print(
            "[FAIL] BRICKTRACKR_IMPORT_DATABASE_URL or --dsn is required.",
            file=sys.stderr,
        )
        return 2

    print("==============================================================================")
    print(f" BrickTrackr Rebrickable Import - Phase 2 v{IMPORTER_VERSION}")
    print("==============================================================================")

    try:
        with psycopg.connect(args.dsn) as conn:
            login = preflight(conn)
            print(f"[+] Database contract verified for login {login!r}.")

            source_run_id = args.source_run_id or find_latest_eligible_run(conn)
            print(f"[*] Reconciling source run: {source_run_id}")

            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        SELECT import.reconcile_rebrickable_reference(%s)
                        """,
                        (source_run_id,),
                    )
                    result = cur.fetchone()
                    if result is None:
                        raise RuntimeError("reconciliation returned no result")
                    summary = result[0]

            print("[+] Reference reconciliation committed atomically.")
            print(json.dumps(summary, indent=2, default=str))
            print("==============================================================================")
            print(" [PASS] Rebrickable Phase 2 completed successfully")
            print("==============================================================================")
            return 0

    except KeyboardInterrupt:
        print("[FAIL] Phase 2 interrupted by operator.", file=sys.stderr)
        return 130
    except Exception as exc:
        print(
            f"[FAIL] Rebrickable Phase 2: {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(run())
