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
    {
        "id": "PART-01",
        "stage": "1 Discover / Source",
        "title": "Canonical PART identity exists as a catalog subtype",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.items') IS NOT NULL
    AND to_regclass('catalog.parts') IS NOT NULL
    AND EXISTS (
        SELECT 1
        FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='catalog'
          AND t.typname='item_kind'
          AND e.enumlabel='PART'
    )
)::int;
""",
        "pass": "Parts are first-class canonical catalog items.",
        "fail": "Canonical PART identity is incomplete.",
    },
    {
        "id": "PART-02",
        "stage": "1 Discover / Source",
        "title": "External/source identifiers are stored separately from canonical identity",
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
        "pass": "LEGO/Rebrickable/other identifiers remain source mappings rather than primary keys.",
        "fail": "External part identity mapping is missing.",
    },
    {
        "id": "PART-03",
        "stage": "1 Discover / Source",
        "title": "Source presence and last-seen provenance are retained",
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
        "pass": "Source disappearance can be tracked without deleting canonical part identity.",
        "fail": "Part source-presence provenance is incomplete.",
    },

    {
        "id": "PART-04",
        "stage": "2 Normalize / Match",
        "title": "Canonical design, variant, and LEGO element identities are separated",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.parts') IS NOT NULL
    AND to_regclass('catalog.part_variants') IS NOT NULL
    AND to_regclass('catalog.lego_elements') IS NOT NULL
)::int;
""",
        "pass": "The part hierarchy separates design, variant, and historical LEGO element identity.",
        "fail": "Part design/variant/element separation is incomplete.",
    },
    {
        "id": "PART-05",
        "stage": "2 Normalize / Match",
        "title": "Color, decoration, mold, printed, and stickered variant data exist",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='part_variants' AND column_name='color_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='part_variants' AND column_name='decoration_code'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='part_variants' AND column_name='mold_code'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='part_variants' AND column_name='is_printed'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='part_variants' AND column_name='is_stickered'
    )
)::int;
""",
        "pass": "Normalized part variants can represent color/mold/decoration state.",
        "fail": "Part variant normalization fields are incomplete.",
    },
    {
        "id": "PART-06",
        "stage": "2 Normalize / Match",
        "title": "Duplicate canonical base variants are constrained",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='catalog'
      AND indexname='uq_part_variants_base_part_color'
)::int;
""",
        "pass": "Canonical base variants are deduplicated per part/color.",
        "fail": "Base part/color variant uniqueness is not enforced.",
    },

    {
        "id": "PART-07",
        "stage": "3 Catalog",
        "title": "Canonical part metadata includes design ID, category, and design name",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='parts' AND column_name='lego_design_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='parts' AND column_name='category_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog' AND table_name='parts' AND column_name='design_name'
    )
)::int;
""",
        "pass": "Core canonical part metadata is modeled.",
        "fail": "Canonical part metadata is incomplete.",
    },
    {
        "id": "PART-08",
        "stage": "3 Catalog",
        "title": "Part supersession can be represented without identity replacement",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='catalog'
      AND table_name='parts'
      AND column_name='superseded_by_catalog_item_id'
)::int;
""",
        "pass": "Superseded designs can remain traceable while pointing to a successor.",
        "fail": "Part supersession relationships are not modeled.",
    },
    {
        "id": "PART-09",
        "stage": "3 Catalog",
        "title": "Source scalar history and durable admin overrides exist",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('catalog.source_values') IS NOT NULL
    AND to_regclass('catalog.source_value_history') IS NOT NULL
    AND to_regclass('catalog.admin_overrides') IS NOT NULL
)::int;
""",
        "pass": "Source state, source history, and independent admin corrections are preserved.",
        "fail": "Catalog source/admin authority history is incomplete.",
    },
    {
        "id": "PART-10",
        "stage": "3 Catalog",
        "title": "Public BrickTrackr part identifier exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='catalog'
      AND table_name IN ('items','parts')
      AND column_name IN ('item_num','public_id','public_identifier','part_num')
)::int;
""",
        "pass": "A dedicated public BrickTrackr part identifier is modeled.",
        "fail": "No item_num/public part identifier exists.",
    },

    {
        "id": "PART-11",
        "stage": "4 Inventory / Collection",
        "title": "Loose inventory can target exact part variants",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='collection'
      AND table_name='entries'
      AND column_name='part_variant_id'
)::int;
""",
        "pass": "Owned loose parts can reference exact normalized variants.",
        "fail": "Collection entries cannot target exact part variants.",
    },
    {
        "id": "PART-12",
        "stage": "4 Inventory / Collection",
        "title": "Owned quantity is separate from canonical catalog data",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='collection'
      AND table_name='entries'
      AND column_name='quantity'
)::int;
""",
        "pass": "User-owned quantities remain collection state, not catalog truth.",
        "fail": "Collection quantity state is missing.",
    },
    {
        "id": "PART-13",
        "stage": "4 Inventory / Collection",
        "title": "Storage locations can hold owned part quantities",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('collection.storage_locations') IS NOT NULL
    AND to_regclass('collection.storage_allocations') IS NOT NULL
    AND EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema='collection'
          AND table_name='storage_allocations'
          AND column_name='quantity'
    )
)::int;
""",
        "pass": "Loose part quantities can be allocated across storage locations.",
        "fail": "Part storage-allocation support is incomplete.",
    },
    {
        "id": "PART-14",
        "stage": "4 Inventory / Collection",
        "title": "Condition state can be tracked for physical instances",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='collection'
      AND table_name='instances'
      AND column_name='item_condition'
)::int;
""",
        "pass": "Physical inventory can carry condition state separately from canonical identity.",
        "fail": "Physical condition tracking is missing.",
    },

    {
        "id": "PART-15",
        "stage": "5 Market / Valuation",
        "title": "Source-attributed market price observations exist",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('marketplace.market_price_observations') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='marketplace'
          AND table_name='market_price_observations'
          AND column_name='part_variant_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='marketplace'
          AND table_name='market_price_observations'
          AND column_name='source_id'
    )
)::int;
""",
        "pass": "Part valuation can use source-attributed variant-level market observations.",
        "fail": "Part market-price observation foundation is incomplete.",
    },
    {
        "id": "PART-16",
        "stage": "5 Market / Valuation",
        "title": "Market observations retain time, currency, condition, and price range",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='marketplace' AND table_name='market_price_observations' AND column_name='observed_at'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='marketplace' AND table_name='market_price_observations' AND column_name='currency'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='marketplace' AND table_name='market_price_observations' AND column_name='condition'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='marketplace' AND table_name='market_price_observations' AND column_name='median_price'
    )
)::int;
""",
        "pass": "Historical market observations retain valuation context.",
        "fail": "Market observation context is incomplete.",
    },
    {
        "id": "PART-17",
        "stage": "5 Market / Valuation",
        "title": "Part market/valuation read API exists",
        "kind": "target",
        "sql": """
SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname IN ('api','reporting')
      AND p.prokind IN ('f','p')
      AND p.proname IN (
          'get_part_market_prices',
          'get_part_valuation',
          'get_market_price_history',
          'get_variant_market_prices'
      )
)::int;
""",
        "pass": "Part market/valuation data has an approved runtime read surface.",
        "fail": "No dedicated part market/valuation read API exists.",
    },

    {
        "id": "PART-18",
        "stage": "6 Change Management",
        "title": "Source changes are preserved as old/new history",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='source_value_history'
          AND column_name='old_value'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='source_value_history'
          AND column_name='new_value'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='source_value_history'
          AND column_name='changed_at'
    )
)::int;
""",
        "pass": "Catalog source corrections remain historically traceable.",
        "fail": "Part source-change history is incomplete.",
    },
    {
        "id": "PART-19",
        "stage": "6 Change Management",
        "title": "Admin corrections are durable and reversible",
        "kind": "foundation",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='admin_overrides'
          AND column_name='reason'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='catalog'
          AND table_name='admin_overrides'
          AND column_name='cleared_at'
    )
    AND EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname='catalog'
          AND indexname='uq_active_catalog_admin_override'
    )
)::int;
""",
        "pass": "Administrator corrections survive imports and can later be cleared.",
        "fail": "Durable/reversible admin override behavior is incomplete.",
    },
    {
        "id": "PART-20",
        "stage": "6 Change Management",
        "title": "Importer reconciliation routines exist",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regprocedure('import.reconcile_rebrickable_catalog(uuid)') IS NOT NULL
    OR to_regprocedure('import.phase6b_reconcile(uuid)') IS NOT NULL
)::int;
""",
        "pass": "Canonical part/source changes can be applied through controlled importer reconciliation.",
        "fail": "No importer reconciliation entry point was detected.",
    },

    {
        "id": "PART-21",
        "stage": "7 Archive / Retain",
        "title": "Catalog lifecycle supports retained inactive/source-missing states",
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
          AND e.enumlabel='RETIRED'
    )
    AND EXISTS (
        SELECT 1
        FROM pg_enum e
        JOIN pg_type t ON t.oid=e.enumtypid
        JOIN pg_namespace n ON n.oid=t.typnamespace
        WHERE n.nspname='catalog'
          AND t.typname='item_status'
          AND e.enumlabel='SOURCE_MISSING'
    )
)::int;
""",
        "pass": "Inactive/source-missing parts can remain retained in the catalog.",
        "fail": "Retained part lifecycle states are incomplete.",
    },
    {
        "id": "PART-22",
        "stage": "7 Archive / Retain",
        "title": "Canonical catalog identity supports archive timestamp retention",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='catalog'
      AND table_name='items'
      AND column_name='archived_at'
)::int;
""",
        "pass": "Canonical part identity can be archived while retained.",
        "fail": "Catalog archive timestamp is missing.",
    },
    {
        "id": "PART-23",
        "stage": "7 Archive / Retain",
        "title": "Explicit hard-delete guard exists for canonical parts",
        "kind": "target",
        "sql": """
SELECT (
    EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid='catalog.items'::regclass
          AND NOT tgisinternal
          AND pg_get_triggerdef(oid) ILIKE '%DELETE%'
    )
    OR EXISTS (
        SELECT 1
        FROM pg_trigger
        WHERE tgrelid='catalog.parts'::regclass
          AND NOT tgisinternal
          AND pg_get_triggerdef(oid) ILIKE '%DELETE%'
    )
)::int;
""",
        "pass": "Canonical part history has explicit database-level hard-delete protection.",
        "fail": "No explicit hard-delete guard exists for canonical part history.",
    },

    {
        "id": "PART-24",
        "stage": "Security",
        "title": "Runtime roles cannot directly mutate canonical part/variant tables",
        "kind": "foundation",
        "sql": """
SELECT (
    NOT has_table_privilege('lego_api','catalog.parts','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_app','catalog.parts','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_api','catalog.part_variants','INSERT,UPDATE,DELETE')
    AND NOT has_table_privilege('lego_app','catalog.part_variants','INSERT,UPDATE,DELETE')
)::int;
""",
        "pass": "Runtime users remain execute-only for canonical part data.",
        "fail": "A runtime role has direct part/variant mutation privileges.",
    },
    {
        "id": "PART-25",
        "stage": "Relationships",
        "title": "Parts can participate in versioned manifests through exact variants/items",
        "kind": "foundation",
        "sql": """
SELECT (
    to_regclass('definition.requirement_options') IS NOT NULL
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='requirement_options'
          AND column_name='catalog_item_id'
    )
    AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema='definition'
          AND table_name='requirement_options'
          AND column_name='part_variant_id'
    )
)::int;
""",
        "pass": "Parts can appear in sets, MOCs, minifigs, and other manifest-driven relationships.",
        "fail": "Manifest relationship support for parts is incomplete.",
    },
    {
        "id": "PART-26",
        "stage": "Relationships",
        "title": "Wishlist entries can target exact part variants",
        "kind": "foundation",
        "sql": """
SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='wanted'
      AND table_name='wishlist_entries'
      AND column_name='part_variant_id'
)::int;
""",
        "pass": "Wanted-list intent can target exact part variants without changing canonical catalog data.",
        "fail": "Wishlist-to-part-variant relationship support is missing.",
    },
]

STAGE_ORDER = [
    "1 Discover / Source",
    "2 Normalize / Match",
    "3 Catalog",
    "4 Inventory / Collection",
    "5 Market / Valuation",
    "6 Change Management",
    "7 Archive / Retain",
    "Security",
    "Relationships",
]

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Assess BrickTrackr Part lifecycle viability.")
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
        "suite": "BrickTrackr Part Lifecycle Viability",
        "database": "<supplied connection>",
        "checks": [],
    }

    try:
        psql = require_tool(args.psql)

        print("=" * 79)
        print(" BrickTrackr Part Lifecycle Viability")
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
