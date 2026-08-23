#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

TARGET_1016 = "1000_function/1016_rebrickable_catalog_reconcile.sql"
HELPER = "0000_bootstrap/0000_dependency_preflight.sql"
START = "-- BRICKTRACKR_PHASE6_CANONICAL_RELATIONSHIPS_V1"


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8-sig").replace("\r\n","\n").replace("\r","\n")


def write(p: Path, s: str):
    p.write_text(s, encoding="utf-8", newline="\n")


def find_unique(root: Path, filename: str) -> Path:
    hits = [p for p in root.rglob(filename) if p.is_file()]
    if len(hits) != 1:
        raise RuntimeError(
            f"Expected exactly one {filename}; found {len(hits)}: "
            + ", ".join(str(p) for p in hits)
        )
    return hits[0]


def find_phase6_block(root: Path):
    hits = []
    for p in root.rglob("*.sql"):
        t = read(p)
        if START in t:
            hits.append((p, t))

    if len(hits) != 1:
        raise RuntimeError(
            f"Expected exactly one Phase 6 canonical table block; found {len(hits)}"
        )

    p, t = hits[0]

    pat = re.compile(
        re.escape(START)
        + r".*?"
        + r"CREATE INDEX ix_external_item_relationships_canonical"
        + r".*?WHERE catalog_item_relationship_id IS NOT NULL;\s*",
        re.S,
    )
    m = pat.search(t)

    if not m:
        raise RuntimeError(f"Could not isolate Phase 6 table block in {p}")

    return p, t, m.group(0), m.span()


def inject_before_mark_completed(text: str, rel: str, block: str) -> str:
    pat = re.compile(
        r"(?m)^SELECT\s+pg_temp\.bt_mark_completed\(\s*['\"]"
        + re.escape(rel)
        + r"['\"]\s*\)\s*;\s*$",
        re.I,
    )
    m = pat.search(text)

    if not m:
        raise RuntimeError(f"bt_mark_completed not found in {rel}")

    return text[:m.start()] + "\n" + block.strip() + "\n\n" + text[m.start():]


def find_manifest(root: Path):
    hits = []
    for p in root.rglob("*.json"):
        try:
            obj = json.loads(read(p))
        except Exception:
            continue

        if TARGET_1016 in json.dumps(obj):
            hits.append((p, obj))

    if len(hits) != 1:
        raise RuntimeError(
            f"Expected one dependency manifest containing 1016; found {len(hits)}"
        )

    return hits[0]


def find_entry(obj, target):
    hits = []

    def walk(x):
        if isinstance(x, dict):
            path = None
            for k in ("path","file","sql_file","filename"):
                if isinstance(x.get(k), str):
                    path = x[k].replace("\\","/")
                    break

            if path and path.endswith(target):
                hits.append(x)

            for v in x.values():
                walk(v)

        elif isinstance(x, list):
            for v in x:
                walk(v)

    walk(obj)

    if len(hits) != 1:
        raise RuntimeError(
            f"Expected one manifest entry for {target}; found {len(hits)}"
        )

    return hits[0]


def dep_field(entry):
    for k in ("depends_on","dependencies","dependsOn"):
        if k in entry:
            return k
    raise RuntimeError("manifest dependency field not found")


def replace_header_deps(text: str, deps: list[str]) -> str:
    lines = text.splitlines()
    dep_i = None
    end_i = None

    for i, line in enumerate(lines):
        if re.match(r"^\s*Depends On:\s*", line, re.I):
            dep_i = i
            break

    if dep_i is None:
        raise RuntimeError("1016 Depends On header not found")

    for j in range(dep_i + 1, len(lines)):
        if re.match(
            r"^\s*(Creates:|Purpose:|Key Rules:|Validation:|Notes:|Seed Data:)",
            lines[j],
            re.I,
        ) or re.match(r"^\s*[=-]{5,}\s*$", lines[j]):
            end_i = j
            break

    if end_i is None:
        raise RuntimeError("1016 dependency header boundary not found")

    block = [f" Depends On:     {deps[0]}"]
    block += [f"                 {d}" for d in deps[1:]]

    lines[dep_i:end_i] = block
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


def replace_inline_preflight(text: str, deps: list[str]) -> str:
    dep_sql = ", ".join("'" + d.replace("'","''") + "'" for d in deps)

    repl = (
        f"SELECT pg_temp.bt_preflight('{TARGET_1016}', "
        f"ARRAY[{dep_sql}]::text[]);"
    )

    pat = re.compile(
        r"SELECT\s+pg_temp\.bt_preflight\(\s*['\"]"
        + re.escape(TARGET_1016)
        + r"['\"]\s*,\s*ARRAY\s*\[.*?\]\s*::text\[\]\s*\)\s*;",
        re.I | re.S,
    )

    new, n = pat.subn(repl, text, count=1)

    if n != 1:
        raise RuntimeError(f"Expected one 1016 preflight call; found {n}")

    return new


def replace_helper_row(text: str, ordinal: int, deps: list[str]) -> str:
    pat = re.compile(
        r"\((\d+),\s*'"
        + re.escape(TARGET_1016)
        + r"',\s*ARRAY\[(.*?)\]::text\[\]\)",
        re.S,
    )

    m = pat.search(text)

    if not m:
        raise RuntimeError("1016 runtime-helper row not found")

    dep_sql = ", ".join("'" + d.replace("'","''") + "'" for d in deps)

    repl = (
        f"({ordinal}, '{TARGET_1016}', "
        f"ARRAY[{dep_sql}]::text[])"
    )

    return text[:m.start()] + repl + text[m.end():]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema-root", required=True)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    root = Path(a.schema_root).resolve()

    p1016 = root / TARGET_1016
    if not p1016.exists():
        raise RuntimeError(f"Missing {TARGET_1016}")

    helper = root / HELPER
    if not helper.exists():
        raise RuntimeError(f"Missing {HELPER}")

    verifier = root / "tools" / "verify_dependencies.py"
    if not verifier.exists():
        raise RuntimeError(f"Missing {verifier}")

    # v1.0.1: discover the actual canonical raw-staging file location.
    p0802 = find_unique(root, "0802_raw_staging.sql")
    rel0802 = p0802.relative_to(root).as_posix()

    src_path, src_text, block, span = find_phase6_block(root)
    src_rel = src_path.relative_to(root).as_posix()

    if src_path.resolve() == p0802.resolve():
        new_src = src_text
        new_0802 = src_text
    else:
        new_src = src_text[:span[0]] + src_text[span[1]:]

        target_text = read(p0802)
        if START in target_text:
            new_0802 = target_text
        else:
            new_0802 = inject_before_mark_completed(
                target_text,
                rel0802,
                block,
            )

    manifest_path, manifest_obj = find_manifest(root)
    entry = find_entry(manifest_obj, TARGET_1016)
    key = dep_field(entry)

    deps = list(entry[key])

    # Add the ACTUAL raw-staging path as a file dependency.
    if rel0802 not in deps:
        deps.append(rel0802)

    entry[key] = deps
    ordinal = entry["ordinal"]

    new_1016 = replace_header_deps(read(p1016), deps)
    new_1016 = replace_inline_preflight(new_1016, deps)

    new_helper = replace_helper_row(
        read(helper),
        ordinal,
        deps,
    )

    new_manifest = json.dumps(
        manifest_obj,
        indent=2,
        ensure_ascii=False,
    ) + "\n"

    print("==============================================================================")
    print(" Repair Phase 6 bootstrap ordering v1.0.1")
    print("==============================================================================")
    print(f"[INFO] Phase 6 table currently in: {src_rel}")
    print(f"[INFO] Raw staging file discovered: {rel0802}")
    print(f"[INFO] 1016 dependency count:       {len(deps)}")
    print(f"[INFO] mode:                        {'APPLY' if a.apply else 'DRY RUN'}")

    if not a.apply:
        print("[PASS] dry run completed")
        print("[NEXT] rerun with -Apply")
        return 0

    changes = []

    if src_path.resolve() != p0802.resolve():
        changes.append((src_path, new_src))
        changes.append((p0802, new_0802))

    changes.extend([
        (p1016, new_1016),
        (helper, new_helper),
        (manifest_path, new_manifest),
    ])

    for p, new in changes:
        old = read(p)

        if old == new:
            print(f"[SKIP] {p.relative_to(root).as_posix()}")
            continue

        backup = p.with_suffix(p.suffix + ".phase6_order.bak")

        if not backup.exists():
            shutil.copy2(p, backup)

        write(p, new)
        print(f"[WRITE] {p.relative_to(root).as_posix()}")

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
            "bootstrap-order repair applied, but dependency verification failed"
        )

    print("")
    print("[PASS] Phase 6 bootstrap ordering repaired")
    print(f"[INFO] canonical provenance table now belongs in {rel0802}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(
            f"[FAIL] {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        raise SystemExit(1)
