#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
import time
from uuid import UUID

import psycopg

VERSION = "4.1.0"


def args():
    p = argparse.ArgumentParser()
    p.add_argument("--dsn", default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"))
    p.add_argument("--source-run-id", type=UUID)
    p.add_argument("--batch-size", type=int, default=5000)
    p.add_argument("--restart", action="store_true")
    return p.parse_args()


def resolve_run(conn):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT r.source_run_id
            FROM import.source_runs r
            JOIN import.source_run_datasets d
              ON d.source_run_id = r.source_run_id
            JOIN reference.external_sources s
              ON s.source_id = r.source_id
            WHERE s.source_code = 'REBRICKABLE'
              AND d.dataset_name = 'elements'
              AND d.status = 'VALIDATED'
              AND r.status IN ('VALIDATING','FINALIZING')
            ORDER BY r.started_at DESC
            LIMIT 1
        """)
        row = cur.fetchone()
        if row is None:
            raise RuntimeError("no validated Phase 4A elements source run found")
        return row[0]


def rows(conn, run_id):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT step_order, substep_order, step_name, substep_name,
                   status, rows_processed, rows_expected, percent_complete,
                   batch_count, last_source_row_number
            FROM import.phase4b_progress(%s)
        """, (run_id,))
        return cur.fetchall()


def show(conn, run_id):
    print("")
    print("-------------------------------------------------------------------------------")
    print(" Durable Phase 4B checkpoint status")
    print("-------------------------------------------------------------------------------")
    current = None
    for r in rows(conn, run_id):
        so, sso, step, sub, status, done, total, pct, batches, last = r
        if step != current:
            current = step
            print(f"\n[{so - 100}/5] {step}")
        pct_s = "n/a" if pct is None else f"{float(pct):5.1f}%"
        print(
            f"      [{so-100}.{sso}] {sub:<24} {status:<9} "
            f"{done:>9,} / {total:<9,} {pct_s} batches={batches}"
        )
    print("")


def first_incomplete(conn, run_id):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT step_name, substep_name, step_order, substep_order,
                   rows_processed, rows_expected, batch_count
            FROM import.phase4b_progress(%s)
            WHERE status <> 'COMPLETED'
            ORDER BY step_order, substep_order
            LIMIT 1
        """, (run_id,))
        return cur.fetchone()


def main():
    a = args()
    if not a.dsn:
        print("[FAIL] DSN required", file=sys.stderr)
        return 2

    started = time.monotonic()

    try:
        with psycopg.connect(
            a.dsn,
            options="-c client_encoding=UTF8",
            autocommit=True,
        ) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT current_user::text")
                login = cur.fetchone()[0]
                cur.execute(
                    "SELECT pg_has_role(%s,'brktrkr_import','MEMBER')",
                    (login,),
                )
                if not cur.fetchone()[0]:
                    raise RuntimeError(f"{login!r} is not a brktrkr_import member")
                cur.execute("SET ROLE brktrkr_import")

            run_id = a.source_run_id or resolve_run(conn)

            print("==============================================================================")
            print(f" BrickTrackr Rebrickable Phase 4B - Checkpointed Reconcile v{VERSION}")
            print("==============================================================================")
            print(f"[INFO] Mode:       {'RESTART' if a.restart else 'RESUME'}")
            print(f"[INFO] Source run: {run_id}")
            print(f"[INFO] Batch size: {a.batch_size:,}")

            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT import.phase4b_initialize(%s,%s)",
                        (run_id, a.restart),
                    )
                    init = cur.fetchone()[0]

            print(f"[+] Checkpoint ledger ready: rows={init['rows']:,}")
            show(conn, run_id)

            while True:
                cur_step = first_incomplete(conn, run_id)
                if cur_step is None:
                    break

                step, sub, so, sso, done, total, batches = cur_step
                pct = 100.0 * done / total if total else 100.0
                print(
                    f"[RUN] [{so-100}.{sso}] {step} / {sub} "
                    f"{done:,}/{total:,} ({pct:5.1f}%) batch={batches+1}",
                    flush=True,
                )

                t0 = time.monotonic()
                with conn.transaction():
                    with conn.cursor() as cur:
                        cur.execute(
                            "SELECT import.phase4b_run_checkpoint(%s,%s,%s,%s)",
                            (run_id, step, sub, a.batch_size),
                        )
                        result = cur.fetchone()[0]

                elapsed = time.monotonic() - t0
                print(
                    f"[OK ] [{so-100}.{sso}] {sub}: "
                    f"{int(result.get('rows_processed') or 0):,}/"
                    f"{int(result.get('rows_expected') or 0):,} "
                    f"({float(result.get('percent_complete') or 100):.1f}%) "
                    f"batches={int(result.get('batch_count') or 0)} "
                    f"elapsed={elapsed:.2f}s",
                    flush=True,
                )

                if result.get("status") == "COMPLETED":
                    show(conn, run_id)

            total_elapsed = time.monotonic() - started
            print("==============================================================================")
            print(" [PASS] Rebrickable Phase 4B checkpointed reconciliation completed")
            print(f" [INFO] Source run: {run_id}")
            print(f" [INFO] Elapsed seconds: {total_elapsed:.2f}")
            print("==============================================================================")
            return 0

    except KeyboardInterrupt:
        print("[STOP] Interrupted; completed batches remain committed.")
        print("[INFO] Rerun without --restart to resume.")
        return 130
    except Exception as exc:
        print(
            f"[FAIL] Phase 4B: {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        print("[INFO] Completed batches remain committed; resume after correction.",
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
