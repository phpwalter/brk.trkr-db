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
    # 1 — CREATE
    {
        "id": "MINI-01",
        "stage": "1 Create",
        "title": "Canonical minifig identity exists as a catalog subtype",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.items') IS NOT NULL
    AND to_regclass('catalog.minifigures') IS NOT NULL
    AND EXISTS (
        SELECT 1
        FROM pg_enum e
        JOIN pg_type t ON t.oid = e.enumtypid
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname='catalog'
          AND t.typname='item_kind'
          AND e.enumlabel='MINIFIGURE'
    )
)::int;
""",
        "pass": "Canonical minifigs are first-class catalog items.",
        "fail": "Canonical MINIFIGURE catalog identity is incomplete.",
    },
    {
        "id": "MINI-02",
        "stage": "1 Create",
        "title": "Canonical source identity is separate from BrickTrackr identity",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.external_identifiers') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='external_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='source_id'
    )
)::int;
""",
        "pass": "Rebrickable/other source IDs are mappings rather than canonical primary keys.",
        "fail": "External source identity mapping is missing.",
    },
    {
        "id": "MINI-03",
        "stage": "1 Create",
        "title": "Public BrickTrackr minifig identifier exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema IN ('catalog','minifig')
      AND table_name IN ('items','minifigures')
      AND column_name IN ('item_num','public_id','public_identifier','minifig_num')
)::int;
""",
        "pass": "A dedicated public BrickTrackr minifig identifier is modeled.",
        "fail": "No item_num/public identifier column exists for minifigs.",
    },
    {
        "id": "MINI-04",
        "stage": "1 Create",
        "title": "Canonical vs custom minifig identity can be distinguished",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='catalog'
          AND e.enumlabel IN ('CUSTOM_MINIFIG','CUSTOM_MINIFIGURE')
    )
    OR EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name IN ('items','minifigures')
          AND column_name IN ('is_custom','minifig_origin','origin_type','source_kind')
    )
)::int;
""",
        "pass": "The schema explicitly distinguishes canonical and custom minifigs.",
        "fail": "No explicit canonical-vs-custom minifig lifecycle discriminator exists.",
    },

    # 2 — BUILD COMPOSITION
    {
        "id": "MINI-05",
        "stage": "2 Build Composition",
        "title": "Minifig composition uses the normalized versioned definition engine",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('definition.inventory_definitions') IS NOT NULL
    AND to_regclass('definition.inventory_versions') IS NOT NULL
    AND to_regclass('definition.requirement_groups') IS NOT NULL
    AND to_regclass('definition.requirement_options') IS NOT NULL
    AND EXISTS (
        SELECT 1
        FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='definition'
          AND t.typname='definition_kind'
          AND e.enumlabel='MINIFIG_COMPOSITION'
    )
)::int;
""",
        "pass": "Minifig composition is modeled as a versioned definition graph.",
        "fail": "The versioned minifig composition foundation is incomplete.",
    },
    {
        "id": "MINI-06",
        "stage": "2 Build Composition",
        "title": "Structural roles, side, and position metadata are supported",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('reference.minifig_roles') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='requirement_options'
          AND column_name='minifig_role_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='requirement_options'
          AND column_name='side'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='requirement_options'
          AND column_name='position_index'
    )
)::int;
""",
        "pass": "Body components/accessories can carry extensible structural metadata.",
        "fail": "Minifig structural component metadata is incomplete.",
    },
    {
        "id": "MINI-07",
        "stage": "2 Build Composition",
        "title": "Working composition edit revision exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='definition'
      AND table_name IN ('inventory_definitions','inventory_versions')
      AND column_name IN ('edit_revision','etag','row_version','lock_version')
)::int;
""",
        "pass": "Working composition has an edit revision / ETag-compatible token.",
        "fail": "No edit_revision / ETag-compatible working-composition token exists.",
    },

    # 3 — VERSION COMPOSITION
    {
        "id": "MINI-08",
        "stage": "3 Version Composition",
        "title": "Semantic composition versions are unique per definition",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid='definition.inventory_versions'::regclass
      AND contype='u'
      AND pg_get_constraintdef(oid) ILIKE '%inventory_definition_id%'
      AND pg_get_constraintdef(oid) ILIKE '%semantic_version%'
)::int;
""",
        "pass": "Semantic version numbers are unique within a composition definition.",
        "fail": "Unique semantic composition numbering is not enforced.",
    },
    {
        "id": "MINI-09",
        "stage": "3 Version Composition",
        "title": "Finalized compositions and graphs are immutable",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regprocedure('definition.prevent_finalized_version_mutation()') IS NOT NULL
    AND to_regprocedure('definition.prevent_finalized_graph_mutation()') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid='definition.inventory_versions'::regclass
          AND tgname='trg_inventory_version_immutable'
          AND NOT tgisinternal
    )
)::int;
""",
        "pass": "Finalized semantic composition snapshots are immutable.",
        "fail": "Finalized composition immutability is incomplete.",
    },
    {
        "id": "MINI-10",
        "stage": "3 Version Composition",
        "title": "Current/default composition authority is modeled",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('definition.definition_authority') IS NOT NULL
    AND to_regprocedure('definition.effective_inventory_version(uuid)') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='definition_authority'
          AND column_name='latest_source_version_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='definition_authority'
          AND column_name='active_admin_version_id'
    )
)::int;
""",
        "pass": "The effective/default semantic composition can be selected through authority pointers.",
        "fail": "Current/default composition authority is not represented.",
    },
    {
        "id": "MINI-11",
        "stage": "3 Version Composition",
        "title": "Complete snapshot can include structural and accessory requirements",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='requirement_groups'
          AND column_name='inventory_version_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='requirement_options'
          AND column_name='part_variant_id'
    )
)::int;
""",
        "pass": "Each semantic version can own a complete component graph.",
        "fail": "Version-scoped component snapshot structure is incomplete.",
    },

    # 4 — PUBLISH / SHARE
    {
        "id": "MINI-12",
        "stage": "4 Publish / Share",
        "title": "Private / unlisted / public minifig visibility can be represented",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name IN ('items','minifigures')
          AND column_name='visibility'
    )
    OR EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname IN ('catalog','minifig')
          AND t.typname LIKE '%visibility%'
    )
)::int;
""",
        "pass": "Minifigs have explicit lifecycle visibility.",
        "fail": "No minifig-specific private/unlisted/public visibility model exists.",
    },
    {
        "id": "MINI-13",
        "stage": "4 Publish / Share",
        "title": "Set inclusion is separate from composition",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema IN ('catalog','definition')
          AND table_name IN ('set_minifigures','set_inclusions','inventory_set_inclusions')
    )
    OR EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='requirement_options'
          AND column_name='catalog_item_id'
    )
)::int;
""",
        "pass": "Set/minifig relationships can be represented independently from anatomy metadata.",
        "fail": "No viable set-inclusion relationship structure was detected.",
    },
    {
        "id": "MINI-14",
        "stage": "4 Publish / Share",
        "title": "Owner-managed custom minifig publish/share API exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='api'
      AND p.prokind IN ('f','p')
      AND p.proname IN (
          'create_custom_minifig',
          'publish_custom_minifig',
          'set_minifig_visibility',
          'share_minifig'
      )
)::int;
""",
        "pass": "Owner-managed custom minifig publish/share entry points exist.",
        "fail": "No owner-facing custom minifig publish/share API exists.",
    },

    # 5 — MAINTAIN
    {
        "id": "MINI-15",
        "stage": "5 Maintain",
        "title": "Admin corrections are durable and explicitly modeled",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='inventory_versions'
          AND column_name='is_admin_correction'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='definition_authority'
          AND column_name='active_admin_version_id'
    )
)::int;
""",
        "pass": "Administrator composition corrections are versioned and selectable without rewriting source truth.",
        "fail": "Admin override/correction semantics are incomplete.",
    },
    {
        "id": "MINI-16",
        "stage": "5 Maintain",
        "title": "ETag / If-Match optimistic concurrency is enforced",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN ('api','definition','catalog')
      AND p.prokind IN ('f','p')
      AND (
          lower(pg_get_functiondef(p.oid)) LIKE '%if_match%'
          OR lower(pg_get_functiondef(p.oid)) LIKE '%etag%'
          OR lower(pg_get_functiondef(p.oid)) LIKE '%edit_revision%'
      )
)::int;
""",
        "pass": "Database routines enforce optimistic concurrency for minifig edits.",
        "fail": "No ETag / If-Match / edit_revision enforcement was detected.",
    },
    {
        "id": "MINI-17",
        "stage": "5 Maintain",
        "title": "Owner mutation API for custom minifig composition exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='api'
      AND p.prokind IN ('f','p')
      AND p.proname IN (
          'create_custom_minifig',
          'update_custom_minifig',
          'update_minifig_composition',
          'create_minifig_version'
      )
)::int;
""",
        "pass": "Custom minifig composition can be maintained through approved runtime routines.",
        "fail": "No owner-facing custom minifig mutation/version API exists.",
    },

    # 6 — RETIRE / RESTORE
    {
        "id": "MINI-18",
        "stage": "6 Retire / Restore",
        "title": "Catalog soft-delete/archive lifecycle exists",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='items'
          AND column_name='archived_at'
    )
    AND EXISTS (
        SELECT 1
        FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='catalog'
          AND t.typname='item_status'
          AND e.enumlabel='ARCHIVED'
    )
)::int;
""",
        "pass": "Catalog items support retained archive state rather than hard deletion.",
        "fail": "Catalog soft-delete/archive state is missing.",
    },
    {
        "id": "MINI-19",
        "stage": "6 Retire / Restore",
        "title": "Approved retire/archive/restore routines exist",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regprocedure('admin.retire_catalog_item(uuid,text)') IS NOT NULL
    AND to_regprocedure('admin.archive_catalog_item(uuid,text)') IS NOT NULL
    AND to_regprocedure('admin.restore_catalog_item(uuid,text,text)') IS NOT NULL
)::int;
""",
        "pass": "Generic lifecycle procedures can retire/archive/restore catalog minifigs.",
        "fail": "Approved catalog lifecycle procedures are incomplete.",
    },
    {
        "id": "MINI-20",
        "stage": "6 Retire / Restore",
        "title": "Custom minifig owner delete/restore policy is enforced",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='api'
          AND p.prokind IN ('f','p')
          AND p.proname IN ('archive_custom_minifig','delete_custom_minifig')
    )
    AND EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='api'
          AND p.prokind IN ('f','p')
          AND p.proname IN ('restore_custom_minifig','restore_minifig')
    )
)::int;
""",
        "pass": "Custom minifig owners have controlled delete/restore entry points.",
        "fail": "Custom-owner retire/restore lifecycle APIs are not implemented.",
    },

    # Collection / security / provenance
    {
        "id": "MINI-21",
        "stage": "Collection",
        "title": "Personal collection references canonical minifig catalog identity",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='collection'
      AND table_name='entries'
      AND column_name='catalog_item_id'
)::int;
""",
        "pass": "Personal ownership remains separate from canonical minifig data.",
        "fail": "Collection entries cannot target canonical catalog items.",
    },
    {
        "id": "MINI-22",
        "stage": "Collection",
        "title": "Collection can pin an exact composition version",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='collection'
      AND column_name IN ('inventory_version_id','composition_version_id','minifig_version_id')
)::int;
""",
        "pass": "Collection state can reference an exact minifig composition version.",
        "fail": "Collection ownership is catalog-level only; exact composition-version pinning is absent.",
    },
    {
        "id": "MINI-23",
        "stage": "Provenance",
        "title": "Source provenance tracks presence and last-seen state",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='source_present'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='last_seen_at'
    )
)::int;
""",
        "pass": "Source evidence can be reconciled without redefining canonical identity.",
        "fail": "Source-presence/last-seen provenance is incomplete.",
    },
    {
        "id": "MINI-24",
        "stage": "Security",
        "title": "Runtime roles cannot directly mutate catalog/definition tables",
        "kind": "foundation",
        "sql": """
SELECT (
    NOT has_table_privilege('lego_api','catalog.minifigures','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_app','catalog.minifigures','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_api','definition.inventory_versions','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_app','definition.inventory_versions','INSERT,UPDATE,DELETE')
)::int;
""",
        "pass": "Runtime minifig lifecycle access remains stored-procedure only.",
        "fail": "A runtime role has direct minifig/definition mutation privileges.",
    },
]

STAGE_ORDER = [
    "1 Create",
    "2 Build Composition",
    "3 Version Composition",
    "4 Publish / Share",
    "5 Maintain",
    "6 Retire / Restore",
    "Collection",
    "Provenance",
    "Security",
]

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Assess BrickTrackr Minifig lifecycle viability.")
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
        "suite": "BrickTrackr Minifig Lifecycle Viability",
        "database": "<supplied connection>",
        "checks": [],
    }

    try:
        psql = require_tool(args.psql)

        print("=" * 79)
        print(" BrickTrackr Minifig Lifecycle Viability")
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
