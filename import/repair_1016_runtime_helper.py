#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

TARGET = "1000_function/1016_rebrickable_catalog_reconcile.sql"
HELPER_REL = "0000_bootstrap/0000_dependency_preflight.sql"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")


def write(p: Path, text: str):
    p.write_text(text, encoding="utf-8", newline="\n")


def find_manifest(root: Path):
    hits = []
    for p in root.rglob("*.json"):
        try:
            obj = json.loads(read(p))
        except Exception:
            continue
        if TARGET in json.dumps(obj):
            hits.append((p, obj))
    if len(hits) != 1:
        raise RuntimeError(f"Expected one manifest containing 1016; found {len(hits)}")
    return hits[0]


def find_entry(obj):
    hits = []

    def walk(x):
        if isinstance(x, dict):
            path = None
            for k in ("path", "file", "sql_file", "filename"):
                if isinstance(x.get(k), str):
                    path = x[k].replace("\\", "/")
                    break
            if path and path.endswith(TARGET):
                hits.append(x)
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)

    walk(obj)

    if len(hits) != 1:
        raise RuntimeError(f"Expected one 1016 manifest entry; found {len(hits)}")
    return hits[0]


def dep_field(entry):
    for k in ("depends_on", "dependencies", "dependsOn"):
        if k in entry:
            return k
    raise RuntimeError("1016 manifest entry has no dependency list")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema-root", required=True)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    root = Path(a.schema_root).resolve()
    helper = root / HELPER_REL
    verifier = root / "tools" / "verify_dependencies.py"

    if not helper.exists():
        raise RuntimeError(f"Missing {HELPER_REL}")
    if not verifier.exists():
        raise RuntimeError(f"Missing {verifier}")

    manifest_path, manifest_obj = find_manifest(root)
    entry = find_entry(manifest_obj)
    key = dep_field(entry)

    ordinal = entry.get("ordinal")
    deps = entry[key]

    if ordinal is None:
        raise RuntimeError("1016 manifest entry has no ordinal")
    if not isinstance(deps, list) or not all(isinstance(x, str) for x in deps):
        raise RuntimeError("1016 manifest dependencies are not list[str]")

    text = read(helper)

    # Match the generated helper row format used by verify_dependencies.py:
    #   (108, '1000_function/1016...', ARRAY['a', 'b']::text[])
    row_pat = re.compile(
        r"\("
        r"(\d+)"
        r",\s*'"
        + re.escape(TARGET)
        + r"'"
        r",\s*ARRAY\[(.*?)\]::text\[\]"
        r"\)",
        re.S,
    )

    matches = list(row_pat.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected exactly one runtime-helper row for 1016; found {len(matches)}"
        )

    current_ordinal = int(matches[0].group(1))
    current_deps = [
        v.replace("''", "'")
        for v in re.findall(r"'((?:''|[^'])*)'", matches[0].group(2))
    ]

    dep_sql = ", ".join("'" + d.replace("'", "''") + "'" for d in deps)
    replacement = f"({ordinal}, '{TARGET}', ARRAY[{dep_sql}]::text[])"

    new = text[:matches[0].start()] + replacement + text[matches[0].end():]

    print("==============================================================================")
    print(" Repair 1016 runtime-helper dependency row")
    print("==============================================================================")
    print(f"[INFO] manifest:          {manifest_path.relative_to(root).as_posix()}")
    print(f"[INFO] helper:            {HELPER_REL}")
    print(f"[INFO] manifest ordinal:  {ordinal}")
    print(f"[INFO] helper ordinal:    {current_ordinal}")
    print(f"[INFO] manifest deps:     {len(deps)}")
    print(f"[INFO] helper deps:       {len(current_deps)}")
    print(f"[INFO] mode:              {'APPLY' if a.apply else 'DRY RUN'}")

    if current_ordinal == ordinal and current_deps == deps:
        print("[PASS] runtime-helper row already matches manifest")
        return 0

    if not a.apply:
        print("[PLAN] replace only the 1016 runtime-helper row")
        print("[PASS] dry run completed")
        print("[NEXT] rerun with -Apply")
        return 0

    backup = helper.with_suffix(helper.suffix + ".pre1016runtimehelper.bak")
    if not backup.exists():
        shutil.copy2(helper, backup)

    write(helper, new)
    print(f"[WRITE] {HELPER_REL}")

    result = subprocess.run(
        [sys.executable, str(verifier)],
        cwd=str(root),
        text=True,
        capture_output=True,
    )

    print("")
    print("=== verify_dependencies.py ===")
    if result.stdout:
        print(result.stdout.rstrip())
    if result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr)

    if result.returncode != 0:
        raise RuntimeError(
            "runtime-helper row was updated, but dependency verification still failed"
        )

    print("")
    print("[PASS] 1016 runtime-helper contract repaired")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
