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
    # Stage 1 — Create
    {
        "id": "MOC-01",
        "stage": "1 Create",
        "title": "Canonical MOC identity is separated from authored lifecycle",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.items') IS NOT NULL
    AND to_regclass('catalog.mocs') IS NOT NULL
    AND to_regclass('moc.mocs') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'moc.mocs'::regclass
          AND contype = 'u'
          AND pg_get_constraintdef(oid) ILIKE '%catalog_item_id%'
    )
)::int;
""",
        "pass": "Stable catalog identity + one authored MOC lifecycle row are supported.",
        "fail": "Canonical/authored MOC identity separation is incomplete.",
    },
    {
        "id": "MOC-02",
        "stage": "1 Create",
        "title": "Generated public MOC identifier exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema IN ('catalog','moc')
      AND table_name IN ('items','mocs')
      AND column_name IN ('item_num','public_id','moc_number','public_identifier')
)::int;
""",
        "pass": "A dedicated public MOC identifier is present.",
        "fail": "No dedicated generated public MOC identifier is present.",
    },

    # Stage 2 — Add Content
    {
        "id": "MOC-03",
        "stage": "2 Add Content",
        "title": "Assets are revision-scoped and retained as metadata",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('moc.assets') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='moc' AND table_name='assets'
          AND column_name='moc_revision_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='moc' AND table_name='assets'
          AND column_name='storage_key'
    )
)::int;
""",
        "pass": "Images/instructions/files can be attached to an exact MOC revision.",
        "fail": "Revision-scoped asset metadata is incomplete.",
    },

    # Stage 3 — Edit Working
    {
        "id": "MOC-04",
        "stage": "3 Edit Working",
        "title": "Draft and published revision states exist",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='moc' AND t.typname='revision_status' AND e.enumlabel='DRAFT'
    )
    AND EXISTS (
        SELECT 1 FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='moc' AND t.typname='revision_status' AND e.enumlabel='PUBLISHED'
    )
)::int;
""",
        "pass": "Working drafts and published revisions are modeled distinctly.",
        "fail": "MOC working/published revision states are missing.",
    },
    {
        "id": "MOC-05",
        "stage": "3 Edit Working",
        "title": "Optimistic concurrency token exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema IN ('moc','definition')
      AND table_name IN ('mocs','revisions','inventory_versions')
      AND column_name IN ('edit_revision','etag','row_version','lock_version')
)::int;
""",
        "pass": "An edit revision / ETag-compatible concurrency token exists.",
        "fail": "No edit_revision / ETag-compatible concurrency token exists.",
    },

    # Stage 4 — Create New Version
    {
        "id": "MOC-06",
        "stage": "4 Create New Version",
        "title": "Semantic manifest versions are modeled",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('definition.inventory_definitions') IS NOT NULL
    AND to_regclass('definition.inventory_versions') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='definition'
          AND t.typname='definition_kind'
          AND e.enumlabel='MOC_MANIFEST'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='inventory_versions'
          AND column_name='semantic_version'
    )
)::int;
""",
        "pass": "MOCs can use the normalized semantic manifest version model.",
        "fail": "Semantic MOC manifest versioning foundation is missing.",
    },
    {
        "id": "MOC-07",
        "stage": "4 Create New Version",
        "title": "Finalized manifest graphs are immutable",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regprocedure('definition.prevent_finalized_version_mutation()') IS NOT NULL
    AND to_regprocedure('definition.prevent_finalized_graph_mutation()') IS NOT NULL
)::int;
""",
        "pass": "Finalized semantic versions and their requirement graphs are protected from mutation.",
        "fail": "Finalized manifest immutability is not fully enforced.",
    },
    {
        "id": "MOC-08",
        "stage": "4 Create New Version",
        "title": "Exactly one current/default manifest can be represented",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema IN ('moc','definition')
      AND table_name IN ('mocs','revisions','inventory_definitions','inventory_versions')
      AND column_name IN (
          'is_current','is_default','current_revision_id','default_revision_id',
          'current_version_id','default_version_id'
      )
)::int;
""",
        "pass": "A current/default manifest pointer or flag is modeled.",
        "fail": "No current/default manifest pointer or flag is modeled.",
    },

    # Stage 5 — Publish / Share
    {
        "id": "MOC-09",
        "stage": "5 Publish / Share",
        "title": "Private, unlisted, and public visibility states exist",
        "kind": "foundation",
        "sql": """
SELECT (
    (SELECT count(*) FROM pg_enum e
      JOIN pg_type t ON t.oid=e.enumtypid
      JOIN pg_namespace n ON n.oid=t.typnamespace
      WHERE n.nspname='moc' AND t.typname='visibility'
        AND e.enumlabel IN ('PRIVATE','UNLISTED','PUBLIC')) = 3
)::int;
""",
        "pass": "Required visibility progression can be represented.",
        "fail": "Required MOC visibility states are missing.",
    },
    {
        "id": "MOC-10",
        "stage": "5 Publish / Share",
        "title": "Published revisions are immutable",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='moc.revisions'::regclass
      AND NOT tgisinternal
      AND tgname='trg_moc_published_revision_immutable'
)::int;
""",
        "pass": "Published MOC revisions are protected by a mutation trigger.",
        "fail": "Published revision immutability trigger is missing.",
    },

    # Stage 6 — Use in Collection
    {
        "id": "MOC-11",
        "stage": "6 Use in Collection",
        "title": "Collections can reference the canonical MOC catalog item",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='collection' AND table_name='entries'
      AND column_name='catalog_item_id'
)::int;
""",
        "pass": "Collections can own/use a MOC through its stable catalog identity.",
        "fail": "Collection entries cannot reference canonical catalog items.",
    },
    {
        "id": "MOC-12",
        "stage": "6 Use in Collection",
        "title": "Collections can pin an exact MOC version",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='collection'
      AND column_name IN ('moc_revision_id','inventory_version_id','manifest_version_id')
)::int;
""",
        "pass": "Collection state can pin an exact MOC/manifest version.",
        "fail": "Collection ownership is catalog-level only; exact MOC version pinning is absent.",
    },

    # Stage 7 — Soft Delete
    {
        "id": "MOC-13",
        "stage": "7 Soft Delete",
        "title": "MOC lifecycle has a soft-delete/archive timestamp",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='moc' AND table_name='mocs'
      AND column_name='archived_at'
)::int;
""",
        "pass": "Authored MOCs can be retained while marked archived.",
        "fail": "MOC soft-delete/archive state is missing.",
    },
    {
        "id": "MOC-14",
        "stage": "7 Soft Delete",
        "title": "Approved MOC soft-delete entry point exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN ('api','admin')
      AND p.proname IN ('archive_moc','soft_delete_moc','delete_moc')
)::int;
""",
        "pass": "A stored-procedure/API entry point controls MOC soft deletion.",
        "fail": "No approved MOC-specific soft-delete entry point exists.",
    },

    # Stage 8 — Restore
    {
        "id": "MOC-15",
        "stage": "8 Restore",
        "title": "Approved MOC restore entry point exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN ('api','admin')
      AND p.proname IN ('restore_moc','unarchive_moc')
)::int;
""",
        "pass": "A stored-procedure/API entry point restores an archived MOC.",
        "fail": "No approved MOC-specific restore entry point exists.",
    },

    # Cross-cutting principles / API contract
    {
        "id": "MOC-16",
        "stage": "Principles",
        "title": "Runtime roles cannot directly mutate MOC tables",
        "kind": "foundation",
        "sql": """
SELECT (
    NOT has_table_privilege('lego_api','moc.mocs','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_app','moc.mocs','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_api','moc.revisions','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_app','moc.revisions','INSERT,UPDATE,DELETE')
)::int;
""",
        "pass": "Runtime roles remain execute-only for MOC lifecycle data.",
        "fail": "A runtime role has direct MOC mutation privileges.",
    },
    {
        "id": "MOC-17",
        "stage": "Principles",
        "title": "Read API exposes exact-ID MOC resources",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regprocedure('api.get_moc_by_id(uuid)') IS NOT NULL
    AND to_regprocedure('api.get_moc_revisions(uuid)') IS NOT NULL
    AND to_regprocedure('api.get_moc_assets(uuid,uuid)') IS NOT NULL
    AND to_regprocedure('api.get_moc_licenses(uuid,uuid)') IS NOT NULL
    AND to_regprocedure('api.get_moc_subassemblies(uuid,uuid)') IS NOT NULL
)::int;
""",
        "pass": "Existing MOC read resources cover identity, revisions, assets, licenses, and subassemblies.",
        "fail": "The MOC read API surface is incomplete.",
    },
    {
        "id": "MOC-18",
        "stage": "API Contract",
        "title": "Owner-managed MOC mutation API exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='api'
      AND p.proname IN (
          'create_moc','update_moc','create_moc_revision','publish_moc_revision',
          'set_moc_visibility','archive_moc','restore_moc'
      )
)::int;
""",
        "pass": "At least one owner-managed MOC mutation entry point exists.",
        "fail": "The database currently exposes MOC reads but no owner-managed lifecycle mutation API.",
    },
    {
        "id": "MOC-19",
        "stage": "API Contract",
        "title": "ETag / If-Match enforcement exists in database routines",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('api','moc')
      AND p.prokind IN ('f','p')
      AND (
          lower(pg_get_functiondef(p.oid)) LIKE '%if_match%'
          OR lower(pg_get_functiondef(p.oid)) LIKE '%etag%'
          OR lower(pg_get_functiondef(p.oid)) LIKE '%edit_revision%'
      )
)::int;
""",
        "pass": "Optimistic concurrency enforcement exists in the MOC API/routines.",
        "fail": "No ETag / If-Match / edit_revision enforcement exists.",
    },
    {
        "id": "MOC-20",
        "stage": "Data Retention",
        "title": "Published/history rows are protected from hard delete",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid='moc.revisions'::regclass
          AND tgname='trg_moc_published_revision_immutable'
          AND NOT tgisinternal
    )
    AND EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid='moc.mocs'::regclass
          AND NOT tgisinternal
          AND pg_get_triggerdef(oid) ILIKE '%DELETE%'
    )
)::int;
""",
        "pass": "Both published revisions and authored MOC identity are protected against hard deletion.",
        "fail": "Published revisions are protected, but authored MOC identity has no explicit hard-delete guard.",
    },
]

STAGE_ORDER = [
    "1 Create", "2 Add Content", "3 Edit Working", "4 Create New Version",
    "5 Publish / Share", "6 Use in Collection", "7 Soft Delete", "8 Restore",
    "Principles", "API Contract", "Data Retention",
]

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Assess BrickTrackr MOC lifecycle viability.")
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
        "suite": "BrickTrackr MOC Lifecycle Viability",
        "database": "<supplied connection>",
        "checks": [],
    }

    try:
        psql = require_tool(args.psql)

        print("=" * 79)
        print(" BrickTrackr MOC Lifecycle Viability")
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

                row = {
                    "id": check["id"],
                    "stage": check["stage"],
                    "title": check["title"],
                    "kind": check["kind"],
                    "status": status,
                    "detail": detail,
                }
                report["checks"].append(row)
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
