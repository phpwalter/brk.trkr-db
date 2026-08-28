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
    # 1 — IMPORT / CREATE
    {
        "id": "SET-01",
        "stage": "1 Import / Create",
        "title": "Canonical SET identity exists as a catalog subtype",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.items') IS NOT NULL
    AND to_regclass('catalog.sets') IS NOT NULL
    AND EXISTS (
        SELECT 1
        FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='catalog'
          AND t.typname='item_kind'
          AND e.enumlabel='SET'
    )
)::int;
""",
        "pass": "Canonical sets are first-class catalog items.",
        "fail": "Canonical SET catalog identity is incomplete.",
    },
    {
        "id": "SET-02",
        "stage": "1 Import / Create",
        "title": "Rebrickable/source identity is mapped separately from canonical identity",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.external_identifiers') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='source_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='external_id'
    )
)::int;
""",
        "pass": "Source IDs are provenance mappings rather than canonical primary keys.",
        "fail": "Set source-identity mapping is missing.",
    },
    {
        "id": "SET-03",
        "stage": "1 Import / Create",
        "title": "Public BrickTrackr set identifier exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='catalog'
      AND table_name IN ('items','sets')
      AND column_name IN ('item_num','public_id','public_identifier','set_num')
)::int;
""",
        "pass": "A dedicated public BrickTrackr set identifier is modeled.",
        "fail": "No item_num/public identifier column exists for sets.",
    },

    # 2 — CANONICALIZE / ENRICH
    {
        "id": "SET-04",
        "stage": "2 Canonicalize",
        "title": "Canonical set metadata supports LEGO ID, theme, and release year",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='sets' AND column_name='lego_set_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='sets' AND column_name='theme_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='sets' AND column_name='release_year'
    )
)::int;
""",
        "pass": "Core canonical set metadata is represented.",
        "fail": "Set canonical metadata is incomplete.",
    },
    {
        "id": "SET-05",
        "stage": "2 Canonicalize",
        "title": "Source scalar history and durable admin overrides exist",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.source_values') IS NOT NULL
    AND to_regclass('catalog.source_value_history') IS NOT NULL
    AND to_regclass('catalog.admin_overrides') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname='catalog'
          AND indexname='uq_active_catalog_admin_override'
    )
)::int;
""",
        "pass": "Source truth is retained while admin overrides remain durable and reversible.",
        "fail": "Source/admin authority foundation is incomplete.",
    },
    {
        "id": "SET-06",
        "stage": "2 Canonicalize",
        "title": "Image and instruction resources can be attached without mutating source identity",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.item_images') IS NOT NULL
    AND to_regclass('catalog.instruction_assets') IS NOT NULL
    AND to_regprocedure('admin.set_catalog_item_image(uuid,text,text,boolean,app.sha256_digest)') IS NOT NULL
    AND to_regprocedure('admin.set_instruction_asset(uuid,text,text,smallint,app.sha256_digest,integer)') IS NOT NULL
)::int;
""",
        "pass": "Set media/instruction resources have controlled admin entry points.",
        "fail": "Set resource/media management foundation is incomplete.",
    },

    # 3 — MANIFEST SYNC
    {
        "id": "SET-07",
        "stage": "3 Manifest Sync",
        "title": "SET_MANIFEST uses the normalized versioned definition engine",
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
          AND e.enumlabel='SET_MANIFEST'
    )
)::int;
""",
        "pass": "Set manifests use the shared semantic definition/version engine.",
        "fail": "SET_MANIFEST versioning foundation is incomplete.",
    },
    {
        "id": "SET-08",
        "stage": "3 Manifest Sync",
        "title": "Semantic manifest versions are unique per definition",
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
        "pass": "Semantic version numbers are unique within a set manifest.",
        "fail": "Unique set-manifest semantic versioning is not enforced.",
    },
    {
        "id": "SET-09",
        "stage": "3 Manifest Sync",
        "title": "Finalized manifest versions and graphs are immutable",
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
        "pass": "Finalized set manifests are immutable semantic snapshots.",
        "fail": "Set manifest immutability is incomplete.",
    },
    {
        "id": "SET-10",
        "stage": "3 Manifest Sync",
        "title": "Current/default manifest authority is represented",
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
)::int;
""",
        "pass": "The effective/current source manifest is selected explicitly.",
        "fail": "Current/default set manifest authority is missing.",
    },
    {
        "id": "SET-11",
        "stage": "3 Manifest Sync",
        "title": "Manifest graph can represent submodels/subassemblies",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('definition.manifest_subassemblies') IS NOT NULL
    AND to_regclass('definition.manifest_requirement_placements') IS NOT NULL
    AND to_regprocedure('admin.clone_manifest_graph(uuid,uuid)') IS NOT NULL
)::int;
""",
        "pass": "Set manifests can preserve hierarchical submodel/subassembly structure.",
        "fail": "Set manifest graph/subassembly support is incomplete.",
    },
    {
        "id": "SET-12",
        "stage": "3 Manifest Sync",
        "title": "Working manifest edit revision / ETag token exists",
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
        "pass": "Working set manifest has an edit revision / ETag-compatible token.",
        "fail": "No edit_revision / ETag-compatible working-manifest token exists.",
    },

    # 4 — PUBLISH
    {
        "id": "SET-13",
        "stage": "4 Publish",
        "title": "Canonical sets remain searchable through the runtime API",
        "kind": "foundation",
        "sql": """
SELECT to_regprocedure('api.search_catalog(text,integer)') IS NOT NULL::int;
""",
        "pass": "Published canonical sets can participate in controlled catalog search.",
        "fail": "Catalog search API is missing.",
    },
    {
        "id": "SET-14",
        "stage": "4 Publish",
        "title": "Set visibility is system-managed/public rather than owner-controlled",
        "kind": "foundation",
        "sql": """
SELECT (
    NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='sets'
          AND column_name='visibility'
    )
)::int;
""",
        "pass": "Canonical set visibility is not modeled as a user-controlled field.",
        "fail": "Set subtype unexpectedly exposes direct visibility state.",
    },
    {
        "id": "SET-15",
        "stage": "4 Publish",
        "title": "Set relationships can include other catalog items",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='definition'
      AND table_name='requirement_options'
      AND column_name='catalog_item_id'
)::int;
""",
        "pass": "Set manifests can reference minifigs/other catalog items through normalized requirements.",
        "fail": "Set-to-catalog-item inclusion capability is missing.",
    },

    # 5 — MAINTAIN
    {
        "id": "SET-16",
        "stage": "5 Maintain",
        "title": "Source provenance tracks last seen and source presence",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='last_seen_at'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='source_present'
    )
)::int;
""",
        "pass": "Ongoing imports can track source disappearance without deleting canonical identity.",
        "fail": "Set source-presence reconciliation data is incomplete.",
    },
    {
        "id": "SET-17",
        "stage": "5 Maintain",
        "title": "Admin overrides survive source refreshes",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname='catalog'
      AND indexname='uq_active_catalog_admin_override'
)::int;
""",
        "pass": "Only one active override per field/item is durable until explicitly cleared.",
        "fail": "Durable active override enforcement is missing.",
    },
    {
        "id": "SET-18",
        "stage": "5 Maintain",
        "title": "ETag / If-Match optimistic concurrency is enforced",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN ('api','admin','definition','catalog')
      AND p.prokind IN ('f','p')
      AND (
          lower(pg_get_functiondef(p.oid)) LIKE '%if_match%'
          OR lower(pg_get_functiondef(p.oid)) LIKE '%etag%'
          OR lower(pg_get_functiondef(p.oid)) LIKE '%edit_revision%'
      )
)::int;
""",
        "pass": "Database routines enforce optimistic concurrency for set/manifest edits.",
        "fail": "No ETag / If-Match / edit_revision enforcement was detected.",
    },

    # 6 — RETIRE / ARCHIVE
    {
        "id": "SET-19",
        "stage": "6 Retire / Archive",
        "title": "Source disappearance does not require deleting the canonical set",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='catalog'
          AND t.typname='item_status'
          AND e.enumlabel='SOURCE_MISSING'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='external_identifiers'
          AND column_name='source_present'
    )
)::int;
""",
        "pass": "Rebrickable disappearance can be reconciled without hard deletion.",
        "fail": "SOURCE_MISSING/source-present lifecycle support is incomplete.",
    },
    {
        "id": "SET-20",
        "stage": "6 Retire / Archive",
        "title": "Canonical sets are not exposed to user soft-delete lifecycle",
        "kind": "foundation",
        "sql": """
SELECT (
    NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='api'
          AND p.prokind IN ('f','p')
          AND p.proname IN ('archive_set','delete_set','restore_set')
    )
)::int;
""",
        "pass": "Normal users have no set delete/restore API.",
        "fail": "Canonical set delete/restore unexpectedly appears in the runtime API.",
    },

    # COLLECTION
    {
        "id": "SET-21",
        "stage": "Collection",
        "title": "User-owned set state is separate from canonical catalog data",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('collection.entries') IS NOT NULL
    AND to_regclass('collection.instances') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='collection'
          AND table_name='entries'
          AND column_name='catalog_item_id'
    )
)::int;
""",
        "pass": "Personal ownership does not mutate canonical set data.",
        "fail": "Set collection-state separation is incomplete.",
    },
    {
        "id": "SET-22",
        "stage": "Collection",
        "title": "Set instances can pin an exact manifest version",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='collection'
      AND table_name='instances'
      AND column_name='inventory_version_id'
)::int;
""",
        "pass": "A physical set instance can reference its exact expected manifest version.",
        "fail": "Set instance exact-version pinning is missing.",
    },
    {
        "id": "SET-23",
        "stage": "Collection",
        "title": "Condition, completeness, and assembly state are instance-specific",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='collection' AND table_name='instances'
          AND column_name='item_condition'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='collection' AND table_name='instances'
          AND column_name='completeness_state'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='collection' AND table_name='instances'
          AND column_name='assembly_state'
    )
)::int;
""",
        "pass": "Physical-set condition/build/completeness state stays outside canonical catalog data.",
        "fail": "Set instance state model is incomplete.",
    },

    # AUTHORITY / SECURITY
    {
        "id": "SET-24",
        "stage": "Authority / Security",
        "title": "Runtime roles cannot directly mutate canonical set/manifest tables",
        "kind": "foundation",
        "sql": """
SELECT (
    NOT has_table_privilege('lego_api','catalog.sets','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_app','catalog.sets','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_api','definition.inventory_versions','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_app','definition.inventory_versions','INSERT,UPDATE,DELETE')
)::int;
""",
        "pass": "Runtime users remain execute-only for canonical set and manifest data.",
        "fail": "A runtime role has direct canonical set/manifest mutation privileges.",
    },
    {
        "id": "SET-25",
        "stage": "Authority / Security",
        "title": "Importer/admin mutation entry points exist without exposing table writes",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regprocedure('import.reconcile_rebrickable_catalog(uuid)') IS NOT NULL
    OR to_regprocedure('import.phase6b_reconcile(uuid)') IS NOT NULL
)::int;
""",
        "pass": "Importer-controlled reconciliation routines exist for canonical catalog maintenance.",
        "fail": "No importer reconciliation entry point was detected.",
    },
]

STAGE_ORDER = [
    "1 Import / Create",
    "2 Canonicalize",
    "3 Manifest Sync",
    "4 Publish",
    "5 Maintain",
    "6 Retire / Archive",
    "Collection",
    "Authority / Security",
]

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Assess BrickTrackr Set lifecycle viability.")
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
        "suite": "BrickTrackr Set Lifecycle Viability",
        "database": "<supplied connection>",
        "checks": [],
    }

    try:
        psql = require_tool(args.psql)

        print("=" * 79)
        print(" BrickTrackr Set Lifecycle Viability")
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
