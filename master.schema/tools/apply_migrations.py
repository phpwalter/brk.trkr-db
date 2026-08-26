#!/usr/bin/env python3
"""Apply BrickTrackr forward-only migrations through psql."""
from __future__ import annotations
from pathlib import Path
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "migrations"
MANIFEST_PATH = MIGRATIONS / "MIGRATION_MANIFEST.json"
VERIFY = ROOT / "tools" / "verify_migrations.py"
TOOL_VERSION = "bricktrackr-migrator/1"
LOCK_SQL = "hashtextextended('bricktrackr:schema-migrations', 0)"

def sql_literal(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + value.replace("'", "''") + "'"

def run_psql(psql: str, database: str, sql: str, *, capture: bool = True) -> subprocess.CompletedProcess:
    cmd = [
        psql, database, "-X", "-q", "-v", "ON_ERROR_STOP=1",
        "-A", "-t", "-F", "\t", "-c", sql,
    ]
    return subprocess.run(
        cmd, text=True, capture_output=capture, check=False
    )

def query_rows(psql: str, database: str, sql: str) -> list[list[str]]:
    owner_sql = "SET ROLE lego_owner;\n" + sql + "\nRESET ROLE;"
    proc = run_psql(psql, database, owner_sql, capture=True)
    if proc.returncode:
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)
    rows = []
    for line in proc.stdout.splitlines():
        if line.strip():
            rows.append(line.split("\t"))
    return rows

def verify_local() -> None:
    proc = subprocess.run([sys.executable, str(VERIFY)], cwd=ROOT)
    if proc.returncode:
        raise SystemExit(proc.returncode)

def wrapper_sql(entry: dict) -> str:
    path = (MIGRATIONS / entry["file"]).resolve().as_posix().replace("'", "''")
    mid = int(entry["id"])
    name = sql_literal(entry["name"])
    checksum = sql_literal(entry["sha256"])
    tx_mode = sql_literal(entry["transaction_mode"])
    release = sql_literal(entry.get("release_label"))
    tool = sql_literal(TOOL_VERSION)

    lines = [
        r"\set ON_ERROR_STOP on",
        rf"SELECT pg_advisory_lock({LOCK_SQL});",
        "SET ROLE lego_owner;",
        f"""DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM app.schema_migrations WHERE migration_id = {mid}
    ) THEN
        RAISE EXCEPTION
            'Migration {mid:06d} was applied after this deployment was planned; rerun migration planning';
    END IF;
END;
$$;""",
        "CREATE TEMP TABLE _bt_migration_clock(started_at timestamptz NOT NULL) ON COMMIT PRESERVE ROWS;",
        "INSERT INTO _bt_migration_clock VALUES (clock_timestamp());",
    ]
    if entry["transaction_mode"] == "transactional":
        lines.append("BEGIN;")
    lines.append(rf"\i '{path}'")
    lines.extend([
        f"""
INSERT INTO app.schema_migrations(
    migration_id, migration_name, checksum_sha256, transaction_mode,
    release_label, execution_ms, tool_version
)
SELECT
    {mid}, {name}, {checksum}, {tx_mode}, {release},
    GREATEST(0, round(extract(epoch FROM (clock_timestamp() - started_at)) * 1000)::bigint),
    {tool}
FROM _bt_migration_clock;
""".strip()
    ])
    if entry["transaction_mode"] == "transactional":
        lines.append("COMMIT;")
    lines.extend([
        "RESET ROLE;",
        rf"SELECT pg_advisory_unlock({LOCK_SQL});",
        r"\echo '[MIGRATION PASS]'",
    ])
    return "\n\n".join(lines) + "\n"

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--database", required=True, help="psql connection string / DSN")
    ap.add_argument("--psql", default=os.environ.get("PSQL", "psql"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    verify_local()
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    expected_baseline = manifest["baseline_id"]

    baseline_rows = query_rows(
        args.psql, args.database,
        "SELECT baseline_id FROM app.schema_migration_baseline WHERE singleton;"
    )
    if baseline_rows != [[expected_baseline]]:
        found = baseline_rows[0][0] if baseline_rows else "<missing>"
        raise SystemExit(
            f"BASELINE MISMATCH: database={found!r} local={expected_baseline!r}"
        )

    history_rows = query_rows(
        args.psql, args.database,
        """
SELECT migration_id::text, migration_name, checksum_sha256, transaction_mode
FROM app.schema_migrations
ORDER BY migration_id;
"""
    )

    local = manifest["migrations"]
    if len(history_rows) > len(local):
        raise SystemExit("DATABASE HISTORY IS AHEAD OF LOCAL MANIFEST")

    for idx, row in enumerate(history_rows):
        db_id, db_name, db_checksum, db_mode = row
        e = local[idx]
        expected = [
            str(int(e["id"])), e["name"], e["sha256"], e["transaction_mode"]
        ]
        if row != expected:
            raise SystemExit(
                "APPLIED MIGRATION HISTORY MISMATCH at position "
                f"{idx + 1}: database={row!r} local={expected!r}. "
                "Never edit/reorder an applied migration; create a new corrective migration."
            )

    pending = local[len(history_rows):]
    if not pending:
        print("MIGRATIONS UP TO DATE")
        return 0

    print(f"PENDING MIGRATIONS: {len(pending)}")
    for e in pending:
        print(
            f" - {int(e['id']):06d} {e['name']} "
            f"[{e['transaction_mode']}] {e['sha256'][:12]}..."
        )

    if args.dry_run:
        print("DRY RUN: no migrations applied")
        return 0

    for e in pending:
        print(f"[APPLY] {int(e['id']):06d} {e['name']}")
        wrapper = wrapper_sql(e)
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".psql", encoding="utf-8", delete=False
        ) as f:
            f.write(wrapper)
            wrapper_path = f.name
        try:
            proc = subprocess.run(
                [args.psql, args.database, "-X", "-v", "ON_ERROR_STOP=1", "-f", wrapper_path],
                text=True,
            )
            if proc.returncode:
                if e["transaction_mode"] == "nontransactional":
                    print(
                        "NONTRANSACTIONAL MIGRATION FAILED: database may contain "
                        "partial effects. Do not edit the failed migration; inspect "
                        "the target and create/execute an approved corrective path.",
                        file=sys.stderr,
                    )
                return proc.returncode
        finally:
            try:
                os.unlink(wrapper_path)
            except OSError:
                pass

    print("MIGRATIONS APPLIED SUCCESSFULLY")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
