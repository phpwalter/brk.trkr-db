#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = ROOT / "5000_function" / "5900_tests"
PREFLIGHT = ROOT / "0000_bootstrap" / "0000_dependency_preflight.sql"

EXPECTED_ROUTINES = (
    "import.reject_rebrickable_moc_staging()",
    "import.complete_source_run(uuid,jsonb)",
    "import.reconcile_rebrickable_reference(uuid)",
    "import.phase3b_initialize(uuid,boolean)",
    "import.phase3b_run_checkpoint(uuid,text,text,integer)",
    "import.phase3b_progress(uuid)",
    "import.phase4b_initialize(uuid,boolean)",
    "import.phase4b_run_checkpoint(uuid,text,text,integer)",
    "import.phase4b_progress(uuid)",
    "import.phase5b_initialize(uuid,boolean)",
    "import.phase5b_run_checkpoint(uuid,text,text,integer)",
    "import.phase5b_progress(uuid)",
    "import.phase6b_reconcile(uuid)",
    "import.fail_source_run(uuid,text)",
    "admin.assert_system_admin()",
    "catalog.transition_item_status(uuid,catalog.item_status,text,text)",
    "admin.retire_catalog_item(uuid,text)",
    "admin.archive_catalog_item(uuid,text)",
    "admin.restore_catalog_item(uuid,text,text)",
    "definition.validate_manifest_subassembly_acyclic(uuid,uuid)",
    "admin.clone_manifest_graph(uuid,uuid)",
    "admin.post_financial_transaction(text,app.currency_code,text,jsonb,uuid)",
    "api.get_moc_by_id(uuid)",
    "api.get_moc_revisions(uuid)",
    "api.get_moc_assets(uuid,uuid)",
    "api.get_moc_licenses(uuid,uuid)",
    "api.get_moc_subassemblies(uuid,uuid)",
    "api.search_catalog(text,integer)",
    "api.mark_notification_read(uuid)",
    "admin.set_catalog_item_image(uuid,text,text,boolean,app.sha256_digest)",
    "admin.remove_catalog_item_image(uuid)",
    "admin.set_instruction_asset(uuid,text,text,smallint,app.sha256_digest,integer)",
    "admin.remove_instruction_asset(uuid)",
    "api.transfer_collection_quantity(uuid,uuid,app.quantity,text)",
    "identity.current_user_id()",
    "identity.current_user_id_optional()",
    "identity.ensure_owner_for_user(uuid)",
    "identity.ensure_owner_for_family(uuid)",
    "identity.has_family_capability(uuid,uuid,text,text)",
    "identity.can_manage_user(uuid,uuid,text)",
    "identity.can_view_owner(uuid,uuid,text)",
    "identity.can_manage_owner(uuid,uuid,text)",
    "identity.can_view_family_shared_owner(uuid,uuid,text)",
    "identity.can_transfer_between(uuid,uuid,uuid)",
    "catalog.assert_item_kind(uuid,catalog.item_kind)",
    "definition.effective_inventory_version(uuid)",
    "collection.explicit_part_balance(uuid,uuid)",
    "wanted.build_goal_requirements(uuid)",
    "wanted.build_goal_summary(uuid)",
    "app.current_request_id()",
    "app.current_trace_id()",
    "app.current_actor_class()",
    "app.set_authenticated_user(uuid)",
    "app.set_request_context(uuid,text,text)",
    "app.set_import_context(uuid)",
)

def run_psql_scalar(psql: str, database: str, sql: str) -> subprocess.CompletedProcess:
    cmd = [
        psql, "-X", "--no-password", "-A", "-t", "-q",
        "-v", "ON_ERROR_STOP=1", "--dbname", database, "--command", sql,
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
    return subprocess.run(cmd, **kwargs)

def database_schema_preflight(psql: str, database: str) -> list[str]:
    values = ", ".join(
        "('" + sig.replace("'", "''") + "')" for sig in EXPECTED_ROUTINES
    )
    sql = f"""
WITH expected(signature) AS (
    VALUES {values}
)
SELECT signature
FROM expected
WHERE to_regprocedure(signature) IS NULL
ORDER BY signature;
"""
    cp = run_psql_scalar(psql, database, sql)
    if cp.returncode != 0:
        output = (cp.stdout or "").strip()
        raise RuntimeError(
            "database schema preflight query failed"
            + (f": {output}" if output else "")
        )
    return [line.strip() for line in (cp.stdout or "").splitlines() if line.strip()]

def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"required executable not found on PATH: {name}")
    return path

def redact_dsn(dsn: str) -> str:
    return "<supplied connection>" if dsn else "<not supplied>"

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Run BrickTrackr stored-procedure tests.")
    p.add_argument("--database", required=True, help="Installed BrickTrackr PostgreSQL DSN")
    p.add_argument("--psql", default=os.environ.get("PSQL", "psql"))
    p.add_argument("--report", help="Optional JSON result path")
    p.add_argument("--match", help="Optional regex matched against test filename")
    return p.parse_args()

def discover(match: str | None) -> list[Path]:
    tests = sorted(TEST_ROOT.glob("*.sql"))
    if match:
        rx = re.compile(match, re.I)
        tests = [p for p in tests if rx.search(p.name)]
    if not tests:
        raise RuntimeError("no stored-procedure tests matched")
    return tests

def include_path(path: Path) -> str:
    return path.resolve().as_posix().replace("'", "''")

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
        "suite": "BrickTrackr Stored Procedure Tests",
        "database": redact_dsn(args.database),
        "tests": [],
        "status": "FAIL",
    }
    try:
        psql = require_tool(args.psql)
        tests = discover(args.match)

        print("=" * 79, flush=True)
        print(" BrickTrackr Stored Procedure Tests", flush=True)
        print("=" * 79, flush=True)
        print(f"Database: {redact_dsn(args.database)}", flush=True)
        print(f"Tests:    {len(tests)}", flush=True)

        print("\n=== DATABASE SCHEMA PREFLIGHT ===", flush=True)
        missing = database_schema_preflight(psql, args.database)
        if missing:
            print("[DATABASE SCHEMA OUT OF DATE]", flush=True)
            print(
                f"Missing {len(missing)} required stored procedure(s)/function(s):",
                flush=True,
            )
            for signature in missing:
                print(f" - {signature}", flush=True)
            print(
                "\nInstall the current master schema (Greenfield) or apply an "
                "approved forward migration before running stored procedure tests.",
                flush=True,
            )
            report["status"] = "SCHEMA_OUT_OF_DATE"
            report["missing_routines"] = missing
            return 3

        print(f"[PASS] Database schema preflight: {len(EXPECTED_ROUTINES)} required routines found", flush=True)

        wrapper = [
            r"\set ON_ERROR_STOP on",
            rf"\ir '{include_path(PREFLIGHT)}'",
            """
INSERT INTO pg_temp.bt_completed_files(file_path)
SELECT file_path
FROM pg_temp.bt_expected_files
WHERE file_path NOT LIKE '5000_function/5900_tests/%'
ON CONFLICT (file_path) DO NOTHING;
""".strip(),
        ]

        for test in tests:
            rel = test.relative_to(ROOT).as_posix()
            wrapper += [
                rf"\echo '[TEST START] {test.name}'",
                rf"\ir '{include_path(test)}'",
                rf"\echo '[TEST PASS] {test.name}'",
            ]
            report["tests"].append({"file": rel, "status": "PENDING"})

        wrapper.append(r"\echo '[PASS] Stored procedure tests'")

        with tempfile.NamedTemporaryFile(mode="w", suffix=".psql", encoding="utf-8", delete=False) as f:
            f.write("\n\n".join(wrapper) + "\n")
            wrapper_path = f.name

        try:
            cmd = [
                psql, "-X", "--no-password", "-v", "ON_ERROR_STOP=1",
                "--dbname", args.database, "--file", wrapper_path,
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

            proc = subprocess.run(cmd, **kwargs)
            output = proc.stdout or ""
            print(output, end="", flush=True)

            passed = set(re.findall(r"\[TEST PASS\]\s+([^\r\n]+)", output))
            for row in report["tests"]:
                row["status"] = "PASS" if Path(row["file"]).name in passed else "FAIL"

            ok = proc.returncode == 0 and all(x["status"] == "PASS" for x in report["tests"])
            report["exit_code"] = proc.returncode
            report["status"] = "PASS" if ok else "FAIL"

            print("=" * 79, flush=True)
            print(" [PASS] BrickTrackr stored procedure tests" if ok
                  else " [FAIL] BrickTrackr stored procedure tests", flush=True)
            print("=" * 79, flush=True)
            return 0 if ok else (proc.returncode or 1)
        finally:
            try:
                os.unlink(wrapper_path)
            except OSError:
                pass
    except Exception as exc:
        report["error"] = str(exc)
        print(f"[ERROR] {exc}", file=sys.stderr, flush=True)
        return 2
    finally:
        report["duration_seconds"] = round(time.time() - started, 3)
        write_report(args.report, report)

if __name__ == "__main__":
    raise SystemExit(main())
