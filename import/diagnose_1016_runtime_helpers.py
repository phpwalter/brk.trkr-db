#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

TARGET = "1000_function/1016_rebrickable_catalog_reconcile.sql"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8-sig").replace("\r\n", "\n").replace("\r", "\n")


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema-root", required=True)
    ap.add_argument("--output", default="diagnose_1016_runtime_helpers.txt")
    a = ap.parse_args()

    root = Path(a.schema_root).resolve()
    verifier = root / "tools" / "verify_dependencies.py"
    sql = root / TARGET

    if not verifier.exists():
        raise RuntimeError(f"Missing {verifier}")
    if not sql.exists():
        raise RuntimeError(f"Missing {sql}")

    manifest_path, manifest_obj = find_manifest(root)
    entry = find_entry(manifest_obj)

    verifier_lines = read(verifier).splitlines()
    needle_hits = [
        i for i, line in enumerate(verifier_lines)
        if "runtime helper dependencies differ from JSON manifest" in line
    ]

    if not needle_hits:
        raise RuntimeError("Could not find runtime-helper mismatch message in verifier")

    sections = []

    for hit in needle_hits:
        start = max(0, hit - 45)
        end = min(len(verifier_lines), hit + 30)
        block = "\n".join(
            f"{i+1:5}: {verifier_lines[i]}"
            for i in range(start, end)
        )
        sections.append(block)

    sql_text = read(sql)

    # Helpful inventory of schema-qualified function calls in 1016.
    calls = sorted(set(
        m.group(1)
        for m in re.finditer(
            r"\b((?:app|import|catalog|reference|definition|audit|identity)\."
            r"[A-Za-z_][A-Za-z0-9_]*)\s*\(",
            sql_text,
        )
    ))

    report = []
    report.append("=" * 79)
    report.append(" 1016 runtime-helper dependency diagnostic")
    report.append("=" * 79)
    report.append("")
    report.append(f"Schema root: {root}")
    report.append(f"Manifest:    {manifest_path.relative_to(root).as_posix()}")
    report.append(f"SQL:         {TARGET}")
    report.append("")
    report.append("--- 1016 JSON manifest entry ---")
    report.append(json.dumps(entry, indent=2, ensure_ascii=False))
    report.append("")
    report.append("--- Schema-qualified function calls found in 1016 ---")
    for call in calls:
        report.append(f"  {call}")
    if not calls:
        report.append("  (none)")
    report.append("")
    report.append("--- verify_dependencies.py runtime-helper comparison block ---")
    report.extend(sections)
    report.append("")

    output_path = Path(a.output)
    if not output_path.is_absolute():
        output_path = root.parent / "import" / output_path

    output_path.write_text("\n".join(report), encoding="utf-8", newline="\n")
    print("\n".join(report))
    print("")
    print(f"[PASS] report written to {output_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}")
        raise SystemExit(1)
