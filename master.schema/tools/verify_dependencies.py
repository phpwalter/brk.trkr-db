#!/usr/bin/env python3
"""Verify BrickTrackr dependency declarations, bootstrap coverage, and preflight manifests."""
from __future__ import annotations

from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
BASE_MANIFEST = ROOT / "DEPENDENCY_MANIFEST.json"
V3_MANIFEST = ROOT / "DEPENDENCY_MANIFEST_V3.json"
BASE_HELPER = ROOT / "0000_bootstrap/0000_dependency_preflight.sql"
V3_HELPER = ROOT / "0000_bootstrap/0006_dependency_preflight_v3.sql"


def deps_from_header(text: str):
    end = text.find("*/")
    head = text[:end] if end != -1 else text[:3000]
    m = re.search(
        r"Depends On:\s*(.*?)(?=\n\s*(?:Creates:|Purpose:|Key Rules:|Validation:|Notes:|Seed Data:|===============================================================================))",
        head,
        re.S | re.I,
    )
    if not m:
        return None
    deps = []
    for line in m.group(1).splitlines():
        value = re.sub(r"^\s*\*\s?", "", line).strip()
        if value:
            deps.append(value)
    return deps


def load_manifest(path: Path) -> dict[str, dict]:
    payload = json.loads(path.read_text())
    return {entry["file"]: entry for entry in payload["files"]}


def parse_helper_rows(text: str) -> dict[str, dict]:
    rows: dict[str, dict] = {}
    row_re = re.compile(r"\((\d+),\s*'([^']+)',\s*ARRAY\[(.*?)\]::text\[\]\)", re.S)
    for match in row_re.finditer(text):
        values = [
            value.replace("''", "'")
            for value in re.findall(r"'((?:''|[^'])*)'", match.group(3))
        ]
        rows[match.group(2)] = {
            "ordinal": int(match.group(1)),
            "depends_on": values,
        }
    return rows


def main() -> int:
    bootstrap = (ROOT / "bootstrap.sql").read_text()
    includes = re.findall(r"^\s*\\ir\s+([^\s]+)", bootstrap, re.M)
    unique: list[str] = []
    for value in includes:
        if value not in unique:
            unique.append(value)

    disk = sorted(
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*.sql")
        if path.name != "bootstrap.sql"
        and "migrations" not in path.relative_to(ROOT).parts
    )

    errors: list[str] = []
    if set(disk) != set(unique):
        errors.append(
            "bootstrap/disk mismatch: "
            f"missing={sorted(set(disk) - set(unique))}, "
            f"unknown={sorted(set(unique) - set(disk))}"
        )

    base = load_manifest(BASE_MANIFEST)
    supplement = load_manifest(V3_MANIFEST) if V3_MANIFEST.exists() else {}
    manifest = dict(base)
    manifest.update(supplement)

    if set(manifest) != set(disk):
        errors.append(
            "merged manifest/disk mismatch: "
            f"missing={sorted(set(disk) - set(manifest))}, "
            f"unknown={sorted(set(manifest) - set(disk))}"
        )

    helper_text = BASE_HELPER.read_text()
    supplemental_helper_text = V3_HELPER.read_text() if V3_HELPER.exists() else ""

    required_helpers = [
        "CREATE OR REPLACE FUNCTION pg_temp.bt_dependency_exists",
        "CREATE OR REPLACE FUNCTION pg_temp.bt_preflight",
        "CREATE OR REPLACE FUNCTION pg_temp.bt_mark_completed",
    ]
    positions = {signature: helper_text.find(signature) for signature in required_helpers}
    for signature, position in positions.items():
        if position < 0:
            errors.append("runtime preflight helper is incomplete: missing " + signature)
    if all(positions[signature] >= 0 for signature in required_helpers):
        if not (
            positions[required_helpers[0]]
            < positions[required_helpers[1]]
            < positions[required_helpers[2]]
        ):
            errors.append(
                "runtime preflight helper function order is invalid: "
                "bt_dependency_exists must precede bt_preflight, which must precede bt_mark_completed"
            )
    if "pg_temp.bt_dependency_exists(v_dep)" not in helper_text:
        errors.append(
            "runtime preflight helper is invalid: bt_preflight does not call "
            "pg_temp.bt_dependency_exists(v_dep)"
        )

    base_rows = parse_helper_rows(helper_text)
    supplemental_rows = parse_helper_rows(supplemental_helper_text)
    overridden = set(supplement)

    # Stable base rows must continue to match the stable base JSON manifest.
    for rel, entry in base.items():
        if rel in overridden:
            continue
        row = base_rows.get(rel)
        if row is None:
            errors.append(f"{rel}: absent from base runtime dependency helper")
            continue
        if row["ordinal"] != entry["ordinal"]:
            errors.append(
                f"{rel}: base runtime helper ordinal {row['ordinal']} differs "
                f"from base JSON manifest {entry['ordinal']}"
            )
        if row["depends_on"] != entry["depends_on"]:
            errors.append(f"{rel}: base runtime helper dependencies differ from base JSON manifest")

    # New supplemental rows must be materialized in the supplemental runtime helper.
    for rel, entry in supplement.items():
        if rel in base:
            # Existing-file overrides are expressed by an UPDATE in the supplement.
            if rel not in supplemental_helper_text:
                errors.append(f"{rel}: v3 manifest override is absent from supplemental runtime helper")
            continue
        row = supplemental_rows.get(rel)
        if row is None:
            errors.append(f"{rel}: absent from v3 supplemental runtime dependency helper")
            continue
        if row["ordinal"] != entry["ordinal"]:
            errors.append(
                f"{rel}: supplemental helper ordinal {row['ordinal']} differs "
                f"from v3 JSON manifest {entry['ordinal']}"
            )
        if row["depends_on"] != entry["depends_on"]:
            errors.append(f"{rel}: supplemental runtime helper dependencies differ from v3 JSON manifest")

    completed: set[str] = set()
    preflight_re = re.compile(
        r"SELECT pg_temp\.bt_preflight\(\s*'([^']+)'\s*,\s*ARRAY\[(.*?)\]::text\[\]\s*\);",
        re.S,
    )

    for rel in unique:
        text = (ROOT / rel).read_text()
        deps = deps_from_header(text)
        if deps is None:
            errors.append(f"{rel}: missing Depends On header")
            deps = []

        if rel != "0000_bootstrap/0000_dependency_preflight.sql":
            match = preflight_re.search(text)
            if not match:
                errors.append(f"{rel}: missing generated preflight call")
            else:
                values = [
                    value.replace("''", "'")
                    for value in re.findall(r"'((?:''|[^'])*)'", match.group(2))
                ]
                if match.group(1) != rel:
                    errors.append(f"{rel}: preflight path mismatch")
                if values != deps:
                    errors.append(f"{rel}: preflight dependencies differ from header")
            if f"bt_mark_completed('{rel}')" not in text:
                errors.append(f"{rel}: missing completion marker")

        entry = manifest.get(rel)
        if entry is None:
            errors.append(f"{rel}: absent from merged dependency manifests")
        elif entry["depends_on"] != deps:
            errors.append(f"{rel}: merged JSON manifest differs from header")

        for dep in deps:
            if dep.endswith(".sql") and dep not in completed:
                errors.append(f"{rel}: file dependency has not executed yet: {dep}")
            domain = re.match(r"^Complete ([0-9]{4}_[A-Za-z0-9_]+) domain$", dep)
            if domain:
                prefix = domain.group(1) + "/"
                expected = [candidate for candidate in unique if candidate.startswith(prefix)]
                missing = [candidate for candidate in expected if candidate not in completed]
                if missing:
                    errors.append(f"{rel}: domain dependency incomplete: {dep}: {missing}")
        completed.add(rel)

    if errors:
        print("DEPENDENCY VERIFICATION FAILED")
        for error in errors:
            print("-", error)
        return 1

    print(
        "DEPENDENCY VERIFICATION PASSED: "
        f"{len(unique)} SQL files ({len(supplement)} v3 supplemental/override entries)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
