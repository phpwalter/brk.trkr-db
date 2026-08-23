#!/usr/bin/env python3
"""
Clean redundant one-off files from master.schema/tools.

Default behavior is DRY RUN.

Usage:
    python .\tools\cleanup_tools_directory.py
    python .\tools\cleanup_tools_directory.py --apply

Run from the master.schema root or directly from the tools directory.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


# Permanent tools that must be preserved.
KEEP_FILES = {
    "apply_migrations.py",
    "verify_api_surface.py",
    "verify_dependencies.py",
    "verify_financial_readiness.py",
    "verify_migrations.py",
    "verify_operational_integrity.py",
    "verify_pgbouncer_transaction_context.psql",
    "verify_query_plans.psql",
    "verify_role_separation.py",
    "verify_schema_contract.py",
    "cleanup_tools_directory.py",
}

# One-off repair/canonicalization artifacts that are now redundant because
# the clean schema contract passes with Phase 3B/4 canonicalized.
REMOVE_FILES = {
    "canonicalize_rebrickable_phase4.py",
    "canonicalize_rebrickable_phase4_resume.py",
    "canonicalize_rebrickable_phase4_resume_v2.py",
    "canonicalize_rebrickable_phase4_resume_v3.py",
    "fix_1016_stray_dependency_bullets.py",
    "fix_phase3b_grants.py",
    "fix_phase3b_import_context_contract.py",
    "fix_phase3b_import_context_contract_v2.py",
    "fix_rebrickable_dependency_contract.py",
    "fix_rebrickable_dependency_contract_v2.py",
}

REMOVE_DIRS = {
    "__pycache__",
}


def find_tools_dir() -> Path:
    cwd = Path.cwd().resolve()

    if cwd.name == "tools":
        return cwd

    candidate = cwd / "tools"
    if candidate.is_dir():
        return candidate

    raise SystemExit(
        "[FAIL] Could not locate tools directory.\n"
        "Run this script from master.schema or master.schema/tools."
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove redundant one-off BrickTrackr tools safely."
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually delete redundant files. Without this flag, only preview.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Fail if any expected redundant file is missing.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    tools = find_tools_dir()

    print("==============================================================================")
    print(" BrickTrackr tools cleanup")
    print("==============================================================================")
    print(f"[INFO] Tools directory: {tools}")
    print(f"[INFO] Mode: {'APPLY' if args.apply else 'DRY RUN'}")
    print("")

    missing = []
    remove_paths: list[Path] = []

    for name in sorted(REMOVE_FILES):
        path = tools / name
        if path.exists():
            remove_paths.append(path)
        else:
            missing.append(name)

    for name in sorted(REMOVE_DIRS):
        path = tools / name
        if path.exists():
            remove_paths.append(path)
        else:
            missing.append(name + "/")

    if missing:
        print("[INFO] Already absent:")
        for name in missing:
            print(f"  - {name}")
        print("")

        if args.strict:
            print("[FAIL] --strict specified and expected cleanup targets are missing.")
            return 2

    if remove_paths:
        print("[REMOVE]")
        for path in remove_paths:
            suffix = "/" if path.is_dir() else ""
            print(f"  - {path.name}{suffix}")
    else:
        print("[INFO] No redundant files remain.")

    print("")
    print("[KEEP]")
    existing_keep = []
    missing_keep = []

    for name in sorted(KEEP_FILES):
        path = tools / name
        if path.exists():
            existing_keep.append(name)
            print(f"  + {name}")
        else:
            missing_keep.append(name)

    if missing_keep:
        print("")
        print("[WARN] Expected permanent tools not found:")
        for name in missing_keep:
            print(f"  ! {name}")

    # Safety check: show anything not explicitly classified.
    known = KEEP_FILES | REMOVE_FILES | REMOVE_DIRS
    unknown = sorted(
        p.name
        for p in tools.iterdir()
        if p.name not in known
    )

    if unknown:
        print("")
        print("[WARN] Unclassified entries were left untouched:")
        for name in unknown:
            print(f"  ? {name}")

    if not args.apply:
        print("")
        print("[DRY RUN] Nothing deleted.")
        print("To apply:")
        print(r"  python .\tools\cleanup_tools_directory.py --apply")
        return 0

    print("")
    for path in remove_paths:
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        print(f"[DELETED] {path.name}")

    # Verify permanent tools were not touched.
    accidentally_missing = [
        name for name in existing_keep
        if not (tools / name).exists()
    ]
    if accidentally_missing:
        print("[FAIL] Permanent tool verification failed:")
        for name in accidentally_missing:
            print(f"  - {name}")
        return 3

    print("")
    print("[PASS] Redundant tools removed.")
    print(f"[INFO] Removed {len(remove_paths)} item(s).")
    print("[INFO] Permanent migration/verification tooling preserved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
