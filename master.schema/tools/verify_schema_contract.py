#!/usr/bin/env python3
"""Single BrickTrackr schema-contract CI entrypoint.

Runs all source-level verifiers, optionally bootstraps a disposable clean
PostgreSQL database, optionally executes production-equivalent query-plan
checks, and optionally executes the real PgBouncer transaction-pooling
request-context contract.
"""
from __future__ import annotations

from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"

STATIC_CHECKS = (
    "verify_dependencies.py",
    "verify_api_surface.py",
    "verify_migrations.py",
    "verify_financial_readiness.py",
    "verify_operational_integrity.py",
    "verify_role_separation.py",
    "verify_transaction_context.py",
)

APP_SCHEMAS = (
    "app", "identity", "reference", "catalog", "inventory", "collection",
    "wanted", "moc", "import", "audit", "api", "admin", "finance",
    "operations", "reporting", "marketplace",
)

def redact_dsn(dsn: str | None) -> str:
    if not dsn:
        return "<not supplied>"
    return "<supplied connection>"

def run(cmd: list[str], *, cwd: Path = ROOT, env: dict | None = None,
        capture: bool = False) -> subprocess.CompletedProcess:
    display = []
    for item in cmd:
        if item.startswith("postgres://") or item.startswith("postgresql://"):
            display.append("<DSN>")
        else:
            display.append(item)
    print("+", " ".join(display), flush=True)
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env,
        text=True,
        capture_output=capture,
        check=False,
    )

def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"required executable not found on PATH: {name}")
    return path

def run_static() -> None:
    print("\n=== STATIC SCHEMA CONTRACT ===", flush=True)
    missing = [name for name in STATIC_CHECKS if not (TOOLS / name).is_file()]
    if missing:
        raise RuntimeError(f"required verifier(s) missing: {', '.join(missing)}")

    for name in STATIC_CHECKS:
        print(f"\n[STATIC] {name}", flush=True)
        cp = run([sys.executable, str(TOOLS / name)])
        if cp.returncode != 0:
            raise RuntimeError(f"static verifier failed: {name}")

def scalar_psql(psql: str, dsn: str, sql: str) -> str:
    cp = run(
        [psql, "-X", "-A", "-t", "-q", "-v", "ON_ERROR_STOP=1",
         "--dbname", dsn, "--command", sql],
        capture=True,
    )
    if cp.returncode != 0:
        if cp.stdout:
            print(cp.stdout, end="")
        if cp.stderr:
            print(cp.stderr, end="", file=sys.stderr)
        raise RuntimeError("psql preflight query failed")
    return cp.stdout.strip()

def assert_disposable_clean_database(psql: str, dsn: str) -> None:
    schema_list = ",".join("'" + s.replace("'", "''") + "'" for s in APP_SCHEMAS)
    sql = f"""
SELECT count(*)
FROM pg_catalog.pg_namespace
WHERE nspname IN ({schema_list});
"""
    count = int(scalar_psql(psql, dsn, sql) or "0")
    if count != 0:
        raise RuntimeError(
            "CI bootstrap target is not clean/disposable: "
            f"{count} BrickTrackr application schema(s) already exist. "
            "Refusing to install over an existing database."
        )

def bootstrap_database(psql: str, dsn: str) -> None:
    print("\n=== CLEAN DATABASE BOOTSTRAP CONTRACT ===", flush=True)
    assert_disposable_clean_database(psql, dsn)

    cp = run([
        psql, "-X", "-v", "ON_ERROR_STOP=1",
        "--dbname", dsn,
        "--file", str(ROOT / "bootstrap.sql"),
    ])
    if cp.returncode != 0:
        raise RuntimeError("fresh-database bootstrap/schema validators failed")

    baseline = scalar_psql(
        psql, dsn,
        "SELECT baseline_id FROM app.schema_migration_baseline WHERE singleton;"
    )
    if baseline != "master-schema-v10.0":
        raise RuntimeError(
            f"unexpected installed migration baseline: {baseline!r}"
        )
    print(f"[PASS] clean bootstrap + installed catalog contract; baseline={baseline}")

def run_query_plans(psql: str, dsn: str) -> None:
    print("\n=== QUERY-PLAN CONTRACT ===", flush=True)
    cp = run([
        psql, "-X", "-v", "ON_ERROR_STOP=1",
        "--dbname", dsn,
        "--file", str(TOOLS / "verify_query_plans.psql"),
    ])
    if cp.returncode != 0:
        raise RuntimeError("query-plan contract failed")

def run_pgbouncer(psql: str, dsn: str, user_id: str) -> None:
    print("\n=== PGBOUNCER TRANSACTION-CONTEXT CONTRACT ===", flush=True)
    cp = run([
        psql, "-X", "-v", "ON_ERROR_STOP=1",
        "-v", f"user_id={user_id}",
        "--dbname", dsn,
        "--file", str(TOOLS / "verify_pgbouncer_transaction_context.psql"),
    ])
    if cp.returncode != 0:
        raise RuntimeError("PgBouncer transaction-context contract failed")

def write_report(path: Path, result: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Run the complete BrickTrackr schema-contract CI gate."
    )
    p.add_argument(
        "--database",
        default=os.environ.get("BRICKTRACKR_CI_DATABASE_URL"),
        help=(
            "Disposable clean PostgreSQL database DSN for full bootstrap/catalog "
            "validation. Defaults to BRICKTRACKR_CI_DATABASE_URL."
        ),
    )
    p.add_argument(
        "--query-plans",
        action="store_true",
        help="Run production-equivalent EXPLAIN/index-plan checks on --database.",
    )
    p.add_argument(
        "--pgbouncer-database",
        default=os.environ.get("BRICKTRACKR_PGBOUNCER_URL"),
        help=(
            "PgBouncer transaction-pooling DSN using the brktrkr_api login. "
            "Defaults to BRICKTRACKR_PGBOUNCER_URL."
        ),
    )
    p.add_argument(
        "--pgbouncer-user-id",
        default=os.environ.get("BRICKTRACKR_PGBOUNCER_TEST_USER_ID"),
        help=(
            "Existing BrickTrackr user UUID used by the PgBouncer USER-context "
            "test. Defaults to BRICKTRACKR_PGBOUNCER_TEST_USER_ID."
        ),
    )
    p.add_argument(
        "--require-database",
        action="store_true",
        help="Fail instead of running static-only when --database is absent.",
    )
    p.add_argument(
        "--require-pgbouncer",
        action="store_true",
        help="Fail when a PgBouncer DSN is absent.",
    )
    p.add_argument(
        "--report",
        type=Path,
        help="Optional JSON result report path.",
    )
    return p.parse_args()

def main() -> int:
    args = parse_args()
    started = time.time()
    result = {
        "contract": "bricktrackr-schema-contract",
        "contract_version": 2,
        "static": "not-run",
        "bootstrap": "not-run",
        "query_plans": "not-run",
        "pgbouncer": "not-run",
        "status": "failed",
    }

    print("===============================================================================")
    print(" BrickTrackr schema-contract CI")
    print("===============================================================================")
    print(f"Database:   {redact_dsn(args.database)}")
    print(f"PgBouncer:  {redact_dsn(args.pgbouncer_database)}")

    try:
        run_static()
        result["static"] = "passed"

        if args.require_database and not args.database:
            raise RuntimeError(
                "--require-database was specified but no CI database DSN was supplied"
            )
        if args.query_plans and not args.database:
            raise RuntimeError("--query-plans requires --database")
        if args.require_pgbouncer and not args.pgbouncer_database:
            raise RuntimeError(
                "--require-pgbouncer was specified but no PgBouncer DSN was supplied"
            )
        if args.pgbouncer_database and not args.pgbouncer_user_id:
            raise RuntimeError(
                "--pgbouncer-database requires --pgbouncer-user-id or "
                "BRICKTRACKR_PGBOUNCER_TEST_USER_ID"
            )

        if args.database or args.pgbouncer_database:
            psql = require_tool("psql")
        else:
            psql = ""

        if args.database:
            bootstrap_database(psql, args.database)
            result["bootstrap"] = "passed"
            if args.query_plans:
                run_query_plans(psql, args.database)
                result["query_plans"] = "passed"

        if args.pgbouncer_database:
            run_pgbouncer(psql, args.pgbouncer_database, args.pgbouncer_user_id)
            result["pgbouncer"] = "passed"

        result["status"] = "passed"
        result["duration_seconds"] = round(time.time() - started, 3)
        print("\n===============================================================================")
        print(" [PASS] BrickTrackr schema contract")
        print("===============================================================================")
        return 0

    except Exception as exc:
        result["error"] = str(exc)
        result["duration_seconds"] = round(time.time() - started, 3)
        print("\n===============================================================================", file=sys.stderr)
        print(f" [FAIL] BrickTrackr schema contract: {exc}", file=sys.stderr)
        print("===============================================================================", file=sys.stderr)
        return 1

    finally:
        if args.report:
            write_report(args.report, result)

if __name__ == "__main__":
    raise SystemExit(main())
