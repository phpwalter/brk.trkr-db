#!/usr/bin/env python3
"""Static verification of BrickTrackr forward-only migration files."""
from __future__ import annotations
from pathlib import Path
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "migrations"
MANIFEST_PATH = MIGRATIONS / "MIGRATION_MANIFEST.json"
FILE_RE = re.compile(r"^(?P<id>\d{6})__(?P<slug>[a-z0-9][a-z0-9_]*)\.sql$")
TX_CONTROL_RE = re.compile(r"(?im)^\s*(BEGIN|START\s+TRANSACTION|COMMIT|END|ROLLBACK)\s*;")
PSQL_INCLUDE_RE = re.compile(r"(?im)^\s*\\i(?:r)?\b")

def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def load_manifest() -> dict:
    data = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if data.get("format_version") != 1:
        raise ValueError("unsupported migration manifest format_version")
    if not data.get("baseline_id"):
        raise ValueError("migration manifest baseline_id is required")
    if not isinstance(data.get("migrations"), list):
        raise ValueError("migration manifest migrations must be a list")
    return data

def validate() -> list[str]:
    errors: list[str] = []
    try:
        data = load_manifest()
    except Exception as exc:
        return [f"cannot load migration manifest: {exc}"]

    entries = data["migrations"]
    disk = sorted(
        p.name for p in MIGRATIONS.glob("*.sql")
        if not p.name.startswith("_")
    )
    listed = [e.get("file") for e in entries]

    if len(listed) != len(set(listed)):
        errors.append("migration manifest contains duplicate file names")
    if set(disk) != set(listed):
        errors.append(
            f"migration manifest/disk mismatch: "
            f"missing_from_manifest={sorted(set(disk)-set(listed))}, "
            f"missing_from_disk={sorted(set(listed)-set(disk))}"
        )

    ids: list[int] = []
    for e in entries:
        required = {"id", "file", "name", "sha256", "transaction_mode"}
        missing = sorted(required - set(e))
        if missing:
            errors.append(f"migration entry missing required fields {missing}: {e!r}")
            continue

        try:
            mid = int(e["id"])
        except Exception:
            errors.append(f"{e.get('file')}: migration id must be an integer")
            continue
        ids.append(mid)

        if mid <= 0:
            errors.append(f"{e['file']}: migration id must be positive")

        m = FILE_RE.match(e["file"])
        if not m:
            errors.append(
                f"{e['file']}: filename must match NNNNNN__lower_snake_case.sql"
            )
        elif int(m.group("id")) != mid:
            errors.append(
                f"{e['file']}: filename id {m.group('id')} differs from manifest id {mid}"
            )

        if e["transaction_mode"] not in {"transactional", "nontransactional"}:
            errors.append(
                f"{e['file']}: transaction_mode must be transactional or nontransactional"
            )
        if e["transaction_mode"] == "nontransactional" and not str(e.get("reason", "")).strip():
            errors.append(f"{e['file']}: nontransactional migration requires reason")

        path = MIGRATIONS / e["file"]
        if not path.exists():
            continue

        actual = sha256(path)
        if e["sha256"] != actual:
            errors.append(
                f"{e['file']}: SHA-256 mismatch; manifest={e['sha256']} actual={actual}"
            )

        text = path.read_text(encoding="utf-8")
        if TX_CONTROL_RE.search(text):
            errors.append(
                f"{e['file']}: migration contains transaction control; runner owns boundaries"
            )
        if PSQL_INCLUDE_RE.search(text):
            errors.append(
                f"{e['file']}: migration may not include other SQL files"
            )

        required_header_values = {
            "Migration ID": f"{mid:06d}",
            "Transaction": e["transaction_mode"],
        }
        for key, expected in required_header_values.items():
            hm = re.search(rf"(?im)^\s*\*?\s*{re.escape(key)}:\s*(\S+)", text)
            if not hm:
                errors.append(f"{e['file']}: missing '{key}:' header")
            elif hm.group(1) != expected:
                errors.append(
                    f"{e['file']}: header {key}={hm.group(1)!r} expected {expected!r}"
                )

    if len(ids) != len(set(ids)):
        errors.append("migration manifest contains duplicate migration IDs")
    if ids != sorted(ids):
        errors.append("migration manifest entries must be in ascending migration-id order")

    return errors

def main() -> int:
    errors = validate()
    if errors:
        print("MIGRATION VERIFICATION FAILED", file=sys.stderr)
        for e in errors:
            print(f" - {e}", file=sys.stderr)
        return 1

    count = len(load_manifest()["migrations"])
    print(
        f"MIGRATION VERIFICATION PASSED: {count} forward migration(s); "
        f"baseline={load_manifest()['baseline_id']}"
    )
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
