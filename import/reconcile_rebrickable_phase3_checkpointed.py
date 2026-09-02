#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
import time
from uuid import UUID

import psycopg

VERSION = "3.2.2"
DEFAULT_RUN = UUID("01a0283d-4c30-744e-b3f7-4e96561db0af")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--dsn",
        default=os.getenv("BRICKTRACKR_IMPORT_DATABASE_URL"),
    )
    p.add_argument(
        "--source-run-id",
        type=UUID,
        default=DEFAULT_RUN,
    )
    p.add_argument(
        "--batch-size",
        type=int,
        default=5000,
    )
    p.add_argument(
        "--restart",
        action="store_true",
        help="Reset Phase 3B checkpoint state and rerun from the first checkpoint.",
    )
    return p.parse_args()


def pct(processed: int, expected: int | None) -> str:
    if not expected:
        return "100.0%" if processed else "0.0%"
    return f"{(processed / expected) * 100:5.1f}%"


def progress_rows(conn: psycopg.Connection, run_id: UUID):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                step_order,
                substep_order,
                step_name,
                substep_name,
                status,
                rows_processed,
                rows_expected,
                percent_complete,
                batch_count,
                last_source_row_number,
                updated_at,
                last_error
            FROM import.phase3b_progress(%s)
            """,
            (run_id,),
        )
        return cur.fetchall()


def print_progress(conn: psycopg.Connection, run_id: UUID) -> None:
    rows = progress_rows(conn, run_id)
    current_step = None

    print("")
    print("-------------------------------------------------------------------------------")
    print(" Durable Phase 3B checkpoint status")
    print("-------------------------------------------------------------------------------")

    for row in rows:
        (
            step_order,
            substep_order,
            step_name,
            substep_name,
            status,
            rows_processed,
            rows_expected,
            percent_complete,
            batch_count,
            last_source_row_number,
            updated_at,
            last_error,
        ) = row

        if step_name != current_step:
            current_step = step_name
            print(f"\n[{step_order}/6] {step_name}")

        expected_text = "?" if rows_expected is None else f"{rows_expected:,}"
        processed_text = f"{rows_processed:,}"
        pct_text = (
            "  n/a"
            if percent_complete is None
            else f"{float(percent_complete):5.1f}%"
        )

        print(
            f"      [{step_order}.{substep_order}] "
            f"{substep_name:<24} "
            f"{status:<9} "
            f"{processed_text:>9} / {expected_text:<9} "
            f"{pct_text}  batches={batch_count}"
        )

        if last_error:
            print(f"            ERROR: {last_error}")

    print("")


def first_incomplete(conn: psycopg.Connection, run_id: UUID):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT
                step_name,
                substep_name,
                step_order,
                substep_order,
                rows_processed,
                rows_expected,
                batch_count
            FROM import.phase3b_progress(%s)
            WHERE status <> 'COMPLETED'
            ORDER BY step_order, substep_order
            LIMIT 1
            """,
            (run_id,),
        )
        return cur.fetchone()


def main() -> int:
    args = parse_args()

    if not args.dsn:
        print("[FAIL] database DSN is required", file=sys.stderr)
        return 2

    if args.batch_size < 1 or args.batch_size > 50000:
        print("[FAIL] --batch-size must be between 1 and 50000", file=sys.stderr)
        return 2

    mode = "RESTART" if args.restart else "RESUME"

    print("==============================================================================")
    print(f" BrickTrackr Rebrickable Phase 3B - Checkpointed Reconcile v{VERSION}")
    print("==============================================================================")
    print(f"[INFO] Mode:       {mode}")
    print(f"[INFO] Source run: {args.source_run_id}")
    print(f"[INFO] Batch size: {args.batch_size:,}")
    print("")

    overall_started = time.monotonic()

    try:
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
                        pg_has_role(
                            %s::text,
                            'brktrkr_import'::text,
                            'MEMBER'::text
                        ),
                        has_function_privilege(
                            %s::text,
                            'import.phase3b_initialize(uuid,boolean)',
                            'EXECUTE'
                        ),
                        has_function_privilege(
                            %s::text,
                            'import.phase3b_run_checkpoint(uuid,text,text,integer)',
                            'EXECUTE'
                        )
                    """,
                    (login, login, login),
                )
                member, can_init, can_run = cur.fetchone()

                if not member:
                    raise RuntimeError(
                        f"login {login!r} is not a member of brktrkr_import"
                    )
                if not can_init or not can_run:
                    raise RuntimeError(
                        "checkpointed Phase 3B database functions are not installed/granted"
                    )

                cur.execute("SET ROLE brktrkr_import")
            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT import.phase3b_initialize(%s, %s)",
                        (args.source_run_id, args.restart),
                    )
                    init = cur.fetchone()[0]

            print(
                "[+] Checkpoint ledger ready: "
                f"parts={init['parts']:,}, "
                f"sets={init['sets']:,}, "
                f"minifigures={init['minifigures']:,}"
            )

            print_progress(conn, args.source_run_id)

            while True:
                current = first_incomplete(conn, args.source_run_id)
                if current is None:
                    break

                (
                    step_name,
                    substep_name,
                    step_order,
                    substep_order,
                    rows_processed,
                    rows_expected,
                    batch_count,
                ) = current

                expected = rows_expected or 0
                before_pct = pct(rows_processed, expected)

                print(
                    f"[RUN] [{step_order}.{substep_order}] "
                    f"{step_name} / {substep_name} "
                    f"{rows_processed:,}/{expected:,} ({before_pct}) "
                    f"batch={batch_count + 1}",
                    flush=True,
                )

                batch_started = time.monotonic()

                with conn.transaction():
                    with conn.cursor() as cur:
                        cur.execute(
                            """
                            SELECT import.phase3b_run_checkpoint(
                                %s, %s, %s, %s
                            )
                            """,
                            (
                                args.source_run_id,
                                step_name,
                                substep_name,
                                args.batch_size,
                            ),
                        )
                        result = cur.fetchone()[0]

                elapsed = time.monotonic() - batch_started

                processed = int(result.get("rows_processed") or 0)
                expected = int(result.get("rows_expected") or 0)
                status = result.get("status")
                batches = int(result.get("batch_count") or 0)
                percent = result.get("percent_complete")

                pct_text = (
                    "n/a"
                    if percent is None
                    else f"{float(percent):.1f}%"
                )

                print(
                    f"[OK ] [{step_order}.{substep_order}] "
                    f"{substep_name}: "
                    f"{processed:,}/{expected:,} ({pct_text}) "
                    f"batches={batches} "
                    f"elapsed={elapsed:.2f}s",
                    flush=True,
                )

                # Reprint full checkpoint dashboard at each substep boundary.
                if status == "COMPLETED":
                    print_progress(conn, args.source_run_id)

            elapsed = time.monotonic() - overall_started
            print_progress(conn, args.source_run_id)

            print("==============================================================================")
            print(" [PASS] Rebrickable Phase 3B checkpointed reconciliation completed")
            print(f" [INFO] Elapsed seconds: {elapsed:.2f}")
            print("==============================================================================")
            return 0

    except KeyboardInterrupt:
        print("")
        print("[STOP] Operator interrupted Phase 3B.")
        print("[INFO] Completed batches are already committed.")
        print("[INFO] Rerun without -Restart to resume.")
        return 130
    except Exception as exc:
        elapsed = time.monotonic() - overall_started
        print(
            f"[FAIL] Phase 3B after {elapsed:.2f}s: "
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        print(
            "[INFO] Completed checkpoints/batches remain committed. "
            "Rerun in resume mode after correcting the error.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
