#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]

CHECKS = [
    # 1 — CREATE WISHLIST
    {
        "id": "WISH-01",
        "stage": "1 Create Wishlist",
        "title": "Wishlist is a first-class owner-scoped object",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('wanted.wishlists') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlists'
          AND column_name='owner_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlists'
          AND column_name='wishlist_name'
    )
)::int;
""",
        "pass": "Wishlists are distinct owner-scoped domain objects.",
        "fail": "Owner-scoped wishlist identity is incomplete.",
    },
    {
        "id": "WISH-02",
        "stage": "1 Create Wishlist",
        "title": "Private, family, and public visibility states exist",
        "kind": "foundation",
        "sql": """
SELECT (
    (SELECT count(*)
       FROM pg_enum e
       JOIN pg_type t ON t.oid=e.enumtypid
       JOIN pg_namespace n ON n.oid=t.typnamespace
      WHERE n.nspname='wanted'
        AND t.typname='visibility'
        AND e.enumlabel IN ('PRIVATE','FAMILY','PUBLIC')) = 3
)::int;
""",
        "pass": "Wishlist sharing can be private, family-scoped, or public.",
        "fail": "Required wishlist visibility states are incomplete.",
    },
    {
        "id": "WISH-03",
        "stage": "1 Create Wishlist",
        "title": "Only one active default wishlist is allowed per owner",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname='wanted'
      AND tablename='wishlists'
      AND indexname='uq_default_wishlist_per_owner'
)::int;
""",
        "pass": "Active default wishlist uniqueness is enforced per owner.",
        "fail": "Default-wishlist uniqueness is not enforced.",
    },
    {
        "id": "WISH-04",
        "stage": "1 Create Wishlist",
        "title": "Owner-facing create/update wishlist API exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='api'
      AND p.prokind IN ('f','p')
      AND p.proname IN (
          'create_wishlist',
          'update_wishlist',
          'set_wishlist_visibility',
          'set_default_wishlist'
      )
)::int;
""",
        "pass": "Wishlist creation/maintenance is exposed through approved runtime routines.",
        "fail": "No owner-facing wishlist create/update API exists.",
    },

    # 2 — ADD / MANAGE ENTRIES
    {
        "id": "WISH-05",
        "stage": "2 Manage Entries",
        "title": "Wishlist entries target exactly one catalog item or part variant",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid='wanted.wishlist_entries'::regclass
      AND conname='ck_wishlist_entries_target'
)::int;
""",
        "pass": "Wishlist intent targets one canonical catalog item or one precise part variant.",
        "fail": "Wishlist target exclusivity is not enforced.",
    },
    {
        "id": "WISH-06",
        "stage": "2 Manage Entries",
        "title": "Entries support desired quantity and priority",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlist_entries'
          AND column_name='desired_quantity'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlist_entries'
          AND column_name='priority'
    )
    AND EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid='wanted.wishlist_entries'::regclass
          AND conname='ck_wishlist_entries_priority'
    )
)::int;
""",
        "pass": "Quantity and bounded priority are modeled for acquisition intent.",
        "fail": "Wishlist quantity/priority support is incomplete.",
    },
    {
        "id": "WISH-07",
        "stage": "2 Manage Entries",
        "title": "Entries may pin a preferred semantic inventory version",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='wanted'
      AND table_name='wishlist_entries'
      AND column_name='preferred_inventory_version_id'
)::int;
""",
        "pass": "Wishlist intent can optionally target an exact semantic inventory version.",
        "fail": "Preferred semantic-version targeting is missing.",
    },
    {
        "id": "WISH-08",
        "stage": "2 Manage Entries",
        "title": "Target unit price and currency are paired",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid='wanted.wishlist_entries'::regclass
      AND conname='ck_wishlist_entries_money'
)::int;
""",
        "pass": "Wishlist price targeting preserves currency integrity.",
        "fail": "Wishlist price/currency pairing is not enforced.",
    },
    {
        "id": "WISH-09",
        "stage": "2 Manage Entries",
        "title": "Owner-facing entry mutation API exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='api'
      AND p.prokind IN ('f','p')
      AND p.proname IN (
          'add_wishlist_entry',
          'update_wishlist_entry',
          'remove_wishlist_entry',
          'archive_wishlist_entry'
      )
)::int;
""",
        "pass": "Wishlist entries can be maintained through approved runtime routines.",
        "fail": "No owner-facing wishlist-entry mutation API exists.",
    },

    # 3 — SHARE / VIEW
    {
        "id": "WISH-10",
        "stage": "3 Share / View",
        "title": "Wishlist RLS respects public, family, and owner visibility",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname='wanted'
          AND tablename='wishlists'
          AND policyname='pol_wishlists_select'
    )
    AND EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname='wanted'
          AND tablename='wishlist_entries'
          AND policyname='pol_wishlist_entries_select'
    )
)::int;
""",
        "pass": "Wishlist and entry reads are protected by visibility-aware RLS.",
        "fail": "Wishlist read visibility policies are incomplete.",
    },
    {
        "id": "WISH-11",
        "stage": "3 Share / View",
        "title": "Wishlist modification is owner-management scoped",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname='wanted'
          AND tablename='wishlists'
          AND policyname='pol_wishlists_modify'
    )
    AND EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname='wanted'
          AND tablename='wishlist_entries'
          AND policyname='pol_wishlist_entries_modify'
    )
)::int;
""",
        "pass": "Wishlist mutations are owner-management scoped at the RLS layer.",
        "fail": "Wishlist owner-management policies are incomplete.",
    },
    {
        "id": "WISH-12",
        "stage": "3 Share / View",
        "title": "Read API for shared/public wishlists exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='api'
      AND p.prokind IN ('f','p')
      AND p.proname IN (
          'get_wishlist',
          'get_wishlist_entries',
          'list_wishlists',
          'get_public_wishlist'
      )
)::int;
""",
        "pass": "Shared/public wishlists have an approved read API.",
        "fail": "No wishlist-specific runtime read API exists.",
    },

    # 4 — GIFT RESERVATIONS
    {
        "id": "WISH-13",
        "stage": "4 Gift Reservations",
        "title": "Reservations preserve reserver, quantity, and lifecycle timestamps",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('wanted.wishlist_reservations') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlist_reservations'
          AND column_name='reserved_by_user_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlist_reservations'
          AND column_name='quantity'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlist_reservations'
          AND column_name='released_at'
    )
)::int;
""",
        "pass": "Gift reservations are retained as lifecycle records rather than ephemeral flags.",
        "fail": "Wishlist reservation lifecycle data is incomplete.",
    },
    {
        "id": "WISH-14",
        "stage": "4 Gift Reservations",
        "title": "Gift reservations can be hidden from the wishlist owner",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlist_reservations'
          AND column_name='hidden_from_owner'
    )
    AND EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname='wanted'
          AND tablename='wishlist_reservations'
          AND policyname='pol_wishlist_reservations_owner_visible_select'
    )
)::int;
""",
        "pass": "Surprise-gift reservation secrecy is explicitly modeled and RLS-protected.",
        "fail": "Hidden gift-reservation behavior is incomplete.",
    },
    {
        "id": "WISH-15",
        "stage": "4 Gift Reservations",
        "title": "Only the reserver may modify their reservation",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='wanted'
      AND tablename='wishlist_reservations'
      AND policyname='pol_wishlist_reservations_reserver_modify'
)::int;
""",
        "pass": "Reservation mutation authority belongs to the reserver.",
        "fail": "Reservation mutation RLS is missing.",
    },
    {
        "id": "WISH-16",
        "stage": "4 Gift Reservations",
        "title": "Reservation chronology is enforced",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid='wanted.wishlist_reservations'::regclass
      AND conname='ck_wishlist_reservations_dates'
)::int;
""",
        "pass": "Expiry/release timestamps cannot precede reservation creation.",
        "fail": "Reservation chronology is not constrained.",
    },
    {
        "id": "WISH-17",
        "stage": "4 Gift Reservations",
        "title": "Reservation/release API exists",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='api'
          AND p.prokind IN ('f','p')
          AND p.proname IN ('reserve_wishlist_entry','create_wishlist_reservation')
    )
    AND EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='api'
          AND p.prokind IN ('f','p')
          AND p.proname IN ('release_wishlist_reservation','cancel_wishlist_reservation')
    )
)::int;
""",
        "pass": "Gift reservation lifecycle has controlled runtime entry points.",
        "fail": "Wishlist reservation/release runtime APIs are not implemented.",
    },

    # 5 — SATISFY / ACQUIRE
    {
        "id": "WISH-18",
        "stage": "5 Satisfy",
        "title": "Partial and complete satisfaction states are modeled",
        "kind": "foundation",
        "sql": """
SELECT (
    (SELECT count(*)
       FROM pg_enum e
       JOIN pg_type t ON t.oid=e.enumtypid
       JOIN pg_namespace n ON n.oid=t.typnamespace
      WHERE n.nspname='wanted'
        AND t.typname='entry_status'
        AND e.enumlabel IN ('ACTIVE','PARTIALLY_SATISFIED','SATISFIED')) = 3
)::int;
""",
        "pass": "Wishlist entries can progress from active through partial to satisfied.",
        "fail": "Wishlist satisfaction states are incomplete.",
    },
    {
        "id": "WISH-19",
        "stage": "5 Satisfy",
        "title": "Satisfied entries preserve completion time",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid='wanted.wishlist_entries'::regclass
      AND conname='ck_wishlist_entries_satisfied'
)::int;
""",
        "pass": "Satisfied wishlist history is timestamped and retained.",
        "fail": "Satisfied-entry timestamp integrity is missing.",
    },
    {
        "id": "WISH-20",
        "stage": "5 Satisfy",
        "title": "Acquisition can automatically/explicitly satisfy wishlist intent through API",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN ('api','app')
      AND p.prokind IN ('f','p')
      AND p.proname IN (
          'satisfy_wishlist_entry',
          'mark_wishlist_entry_satisfied',
          'apply_acquisition_to_wishlist'
      )
)::int;
""",
        "pass": "Wishlist satisfaction is exposed as a controlled runtime operation.",
        "fail": "No wishlist satisfaction/acquisition integration API exists.",
    },

    # 6 — ARCHIVE / RESTORE
    {
        "id": "WISH-21",
        "stage": "6 Archive / Restore",
        "title": "Wishlists support soft archive without deleting history",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='wanted'
      AND table_name='wishlists'
      AND column_name='archived_at'
)::int;
""",
        "pass": "Wishlist containers support retained soft archive.",
        "fail": "Wishlist soft-archive state is missing.",
    },
    {
        "id": "WISH-22",
        "stage": "6 Archive / Restore",
        "title": "Wishlist entries support archived state",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_enum e
    JOIN pg_type t ON t.oid=e.enumtypid
    JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='wanted'
      AND t.typname='entry_status'
      AND e.enumlabel='ARCHIVED'
)::int;
""",
        "pass": "Wishlist-entry history can be archived instead of hard-deleted.",
        "fail": "Wishlist-entry archive state is missing.",
    },
    {
        "id": "WISH-23",
        "stage": "6 Archive / Restore",
        "title": "Wishlist archive/restore runtime API exists",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='api'
          AND p.prokind IN ('f','p')
          AND p.proname IN ('archive_wishlist','delete_wishlist')
    )
    AND EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='api'
          AND p.prokind IN ('f','p')
          AND p.proname='restore_wishlist'
    )
)::int;
""",
        "pass": "Wishlist soft-delete/restore has controlled runtime entry points.",
        "fail": "Wishlist archive/restore runtime APIs are not implemented.",
    },
    {
        "id": "WISH-24",
        "stage": "6 Archive / Restore",
        "title": "Explicit hard-delete protection exists for wishlist history",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid='wanted.wishlists'::regclass
          AND NOT tgisinternal
          AND pg_get_triggerdef(oid) ILIKE '%DELETE%'
    )
    OR EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid='wanted.wishlist_entries'::regclass
          AND NOT tgisinternal
          AND pg_get_triggerdef(oid) ILIKE '%DELETE%'
    )
)::int;
""",
        "pass": "Wishlist history has explicit database-level hard-delete protection.",
        "fail": "No explicit hard-delete guard exists for wishlist/history rows.",
    },

    # CROSS-CUTTING
    {
        "id": "WISH-25",
        "stage": "Security",
        "title": "Runtime roles cannot directly mutate wishlist tables",
        "kind": "foundation",
        "sql": """
SELECT (
    NOT has_table_privilege('brktrkr_api','wanted.wishlists','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('brktrkr_api','wanted.wishlists','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('brktrkr_api','wanted.wishlist_entries','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('brktrkr_api','wanted.wishlist_entries','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('brktrkr_api','wanted.wishlist_reservations','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('brktrkr_api','wanted.wishlist_reservations','INSERT,UPDATE,DELETE')
)::int;
""",
        "pass": "Runtime wishlist access remains stored-procedure/API only.",
        "fail": "A runtime role has direct wishlist table mutation privileges.",
    },
    {
        "id": "WISH-26",
        "stage": "Concurrency",
        "title": "Wishlist edit revision / ETag optimistic concurrency exists",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name IN ('wishlists','wishlist_entries')
          AND column_name IN ('edit_revision','etag','row_version','lock_version')
    )
    OR EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname IN ('api','wanted')
          AND p.prokind IN ('f','p')
          AND (
              lower(pg_get_functiondef(p.oid)) LIKE '%if_match%'
              OR lower(pg_get_functiondef(p.oid)) LIKE '%etag%'
              OR lower(pg_get_functiondef(p.oid)) LIKE '%edit_revision%'
          )
    )
)::int;
""",
        "pass": "Wishlist mutations have an ETag/edit-revision concurrency mechanism.",
        "fail": "No wishlist ETag / If-Match / edit_revision mechanism was detected.",
    },
    {
        "id": "WISH-27",
        "stage": "Scope Separation",
        "title": "Wishlist intent remains separate from Build Goal shortages",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('wanted.wishlist_entries') IS NOT NULL
    AND to_regclass('wanted.build_goals') IS NOT NULL
    AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema='wanted'
          AND table_name='wishlist_entries'
          AND column_name='build_goal_id'
    )
)::int;
""",
        "pass": "Manual acquisition intent and derived build-goal state remain separate concepts.",
        "fail": "Wishlist intent is improperly coupled to build-goal state.",
    },
]

STAGE_ORDER = [
    "1 Create Wishlist",
    "2 Manage Entries",
    "3 Share / View",
    "4 Gift Reservations",
    "5 Satisfy",
    "6 Archive / Restore",
    "Security",
    "Concurrency",
    "Scope Separation",
]

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Assess BrickTrackr Wishlist lifecycle viability."
    )
    p.add_argument("--database", required=True, help="BrickTrackr PostgreSQL DSN")
    p.add_argument("--psql", default=os.environ.get("PSQL", "psql"))
    p.add_argument("--report", help="Optional JSON report path")
    return p.parse_args()

def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"required executable not found on PATH: {name}")
    return path

def run_scalar(psql: str, dsn: str, sql: str) -> bool:
    cmd = [
        psql, "-X", "--no-password", "-A", "-t", "-q",
        "-v", "ON_ERROR_STOP=1", "--dbname", dsn, "--command", sql,
    ]
    kwargs = {
        "cwd": str(ROOT),
        "text": True,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.STDOUT,
        "check": False,
        "env": os.environ.copy(),
    }
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

    cp = subprocess.run(cmd, **kwargs)
    if cp.returncode != 0:
        raise RuntimeError((cp.stdout or "").strip() or f"psql exited {cp.returncode}")

    lines = [x.strip() for x in (cp.stdout or "").splitlines() if x.strip()]
    if not lines:
        raise RuntimeError("viability check returned no result")

    return lines[-1] in ("1", "t", "true", "TRUE")

def write_report(path: str | None, report: dict) -> None:
    if not path:
        return
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

def main() -> int:
    args = parse_args()
    started = time.time()
    report = {
        "suite": "BrickTrackr Wishlist Lifecycle Viability",
        "database": "<supplied connection>",
        "checks": [],
    }

    try:
        psql = require_tool(args.psql)

        print("=" * 79)
        print(" BrickTrackr Wishlist Lifecycle Viability")
        print("=" * 79)

        hard_fail = False
        target_gap = False

        for stage in STAGE_ORDER:
            stage_checks = [c for c in CHECKS if c["stage"] == stage]
            if not stage_checks:
                continue

            print(f"\n[{stage}]")

            for check in stage_checks:
                ok = run_scalar(psql, args.database, check["sql"])

                if ok:
                    status = "PASS"
                    detail = check["pass"]
                elif check["kind"] == "foundation":
                    status = "FAIL"
                    detail = check["fail"]
                    hard_fail = True
                else:
                    status = "GAP"
                    detail = check["fail"]
                    target_gap = True

                report["checks"].append({
                    "id": check["id"],
                    "stage": check["stage"],
                    "title": check["title"],
                    "kind": check["kind"],
                    "status": status,
                    "detail": detail,
                })

                print(f"[{status}] {check['id']} {check['title']}")
                print(f"       {detail}")

        counts = {
            status: sum(1 for x in report["checks"] if x["status"] == status)
            for status in ("PASS", "GAP", "FAIL")
        }
        report["counts"] = counts

        if hard_fail:
            verdict = "BLOCKED"
            exit_code = 2
        elif target_gap:
            verdict = "PARTIAL"
            exit_code = 1
        else:
            verdict = "READY"
            exit_code = 0

        report["verdict"] = verdict
        report["exit_code"] = exit_code

        print("\n" + "=" * 79)
        print(f" Verdict: {verdict}")
        print(f" PASS={counts['PASS']}  GAP={counts['GAP']}  FAIL={counts['FAIL']}")
        print("=" * 79)

        return exit_code

    except Exception as exc:
        report["verdict"] = "ERROR"
        report["error"] = str(exc)
        report["exit_code"] = 3
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 3
    finally:
        report["duration_seconds"] = round(time.time() - started, 3)
        write_report(args.report, report)

if __name__ == "__main__":
    raise SystemExit(main())
