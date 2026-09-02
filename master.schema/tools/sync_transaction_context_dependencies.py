#!/usr/bin/env python3
"""Synchronize BrickTrackr transaction-context dependencies and repair ordering.

This version performs a stable topological sort of the entire authoritative
DEPENDENCY_MANIFEST.json, but only file dependencies participate in graph
ordering.

BrickTrackr manifests may also contain external prerequisites such as
"PostgreSQL 16+" or extension/runtime requirements. Those are valid dependency
annotations but are not manifest file nodes and therefore must not be treated
as missing SQL files.

Rules:
  * dependency ending in ".sql" => must exist in manifest and becomes a graph edge
  * non-.sql dependency         => preserved as an external prerequisite
  * missing ".sql" dependency   => hard failure

The tool updates together:
  1. SQL Depends On headers for 5709 / 5979 / 1217
  2. SQL pg_temp.bt_preflight(...) calls
  3. DEPENDENCY_MANIFEST.json dependencies
  4. DEPENDENCY_MANIFEST.json execution order / ordinals
  5. 0000_bootstrap/0000_dependency_preflight.sql ordinals
  6. bootstrap.sql explicit include order, when present
"""
from __future__ import annotations

from pathlib import Path
import heapq
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "DEPENDENCY_MANIFEST.json"
HELPER = ROOT / "0000_bootstrap/0000_dependency_preflight.sql"
BOOTSTRAP = ROOT / "bootstrap.sql"

CONTEXT = "5000_function/5700_system/5709_system_request_context.sql"
TEST5900 = "5000_function/5900_tests/5900_test_app_lifecycle.sql"
VALID1217 = "1200_validation/1217_pgbouncer_transaction_context_validation.sql"

FILES = {
    CONTEXT: [
        "0000_bootstrap/0001_schemas.sql",
        "0100_identity/0100_users.sql",
        "1100_security/1100_roles.sql",
    ],
    TEST5900: [CONTEXT, "0000_bootstrap/0005_migration_framework.sql"],
    VALID1217: [CONTEXT],
}

def is_internal_file_dependency(dep: object) -> bool:
    return isinstance(dep, str) and dep.strip().lower().endswith(".sql")

def array_sql(deps: list[str]) -> str:
    return "ARRAY[" + ", ".join("'" + d.replace("'", "''") + "'" for d in deps) + "]::text[]"

def update_header(text: str, deps: list[str]) -> str:
    lines = text.splitlines()
    start = None
    end = None

    for i, line in enumerate(lines):
        if re.match(r"^\s*Depends On:\s*", line):
            start = i
            end = i + 1
            while end < len(lines):
                nxt = lines[end]
                if re.match(r"^\s+\S.*\.sql\s*$", nxt) and not re.match(
                    r"^\s*(Creates:|Purpose:|Project:|PostgreSQL:|File:)", nxt
                ):
                    end += 1
                    continue
                break
            break

    if start is None:
        raise RuntimeError("missing Depends On header")

    indent = re.match(r"^(\s*)Depends On:", lines[start]).group(1)
    repl = [f"{indent}Depends On:     {deps[0]}"]
    repl.extend(f"{indent}                {dep}" for dep in deps[1:])

    out = "\n".join(lines[:start] + repl + lines[end:])
    return out + ("\n" if text.endswith("\n") else "")

def update_preflight(text: str, rel: str, deps: list[str]) -> str:
    repl = f"SELECT pg_temp.bt_preflight('{rel}', {array_sql(deps)});"
    pat = re.compile(
        r"SELECT\s+pg_temp\.bt_preflight\s*\(\s*'"
        + re.escape(rel)
        + r"'\s*,\s*ARRAY\s*\[.*?\]\s*(?:::text\[\])?\s*\)\s*;",
        re.S,
    )
    if not pat.search(text):
        raise RuntimeError(f"missing generated preflight call: {rel}")
    return pat.sub(repl, text, count=1)

def update_completion(text: str, rel: str) -> str:
    repl = f"SELECT pg_temp.bt_mark_completed('{rel}');"
    pat = re.compile(
        r"SELECT\s+pg_temp\.bt_mark_completed\s*\(\s*'"
        + re.escape(rel)
        + r"'\s*\)\s*;",
        re.S,
    )
    if not pat.search(text):
        raise RuntimeError(f"missing completion marker: {rel}")
    return pat.sub(repl, text, count=1)

def stable_toposort(rows: list[dict]) -> list[dict]:
    by_file = {row["file"]: row for row in rows}
    original_index = {row["file"]: i for i, row in enumerate(rows)}

    indegree = {name: 0 for name in by_file}
    children: dict[str, list[str]] = {name: [] for name in by_file}

    external_count = 0

    for name, row in by_file.items():
        deps = row.get("depends_on", [])
        if deps is None:
            deps = []
        if not isinstance(deps, list):
            raise RuntimeError(f"{name}: depends_on must be a list")

        for dep in deps:
            if not isinstance(dep, str):
                raise RuntimeError(f"{name}: invalid non-string dependency: {dep!r}")

            dep = dep.strip()
            if not is_internal_file_dependency(dep):
                external_count += 1
                continue

            if dep not in by_file:
                raise RuntimeError(
                    f"{name}: SQL file dependency is missing from manifest: {dep}"
                )

            indegree[name] += 1
            children[dep].append(name)

    heap: list[tuple[int, str]] = []
    for name, degree in indegree.items():
        if degree == 0:
            heapq.heappush(heap, (original_index[name], name))

    ordered_names: list[str] = []
    while heap:
        _, name = heapq.heappop(heap)
        ordered_names.append(name)

        for child in sorted(children[name], key=lambda x: original_index[x]):
            indegree[child] -= 1
            if indegree[child] == 0:
                heapq.heappush(heap, (original_index[child], child))

    if len(ordered_names) != len(rows):
        cyclic = [name for name, degree in indegree.items() if degree > 0]
        raise RuntimeError(
            "dependency graph contains a cycle involving: "
            + ", ".join(cyclic[:20])
        )

    print(f"[INFO] Preserved {external_count} external/non-file dependency annotation(s).")
    return [by_file[name] for name in ordered_names]

def update_helper_ordinals(text: str, rows: list[dict]) -> str:
    out = text
    for row in rows:
        rel = row["file"]
        ordinal = row["ordinal"]
        pat = re.compile(
            r"\(\s*\d+\s*,\s*'"
            + re.escape(rel)
            + r"'\s*,\s*(ARRAY\s*\[.*?\]\s*::text\[\])\s*\)",
            re.S,
        )
        m = pat.search(out)
        if not m:
            raise RuntimeError(f"runtime dependency helper row not found: {rel}")
        repl = f"({ordinal}, '{rel}', {m.group(1)})"
        out = pat.sub(repl, out, count=1)
    return out

def update_bootstrap_include_order(text: str, rows: list[dict]) -> str:
    lines = text.splitlines()
    include_re = re.compile(r"^(\s*\\(?:ir|i)\s+)(.+?)(\s*)$", re.I)
    order = [row["file"] for row in rows]
    order_set = set(order)

    line_by_file: dict[str, str] = {}
    indices: list[int] = []

    for i, line in enumerate(lines):
        m = include_re.match(line)
        if not m:
            continue
        raw = m.group(2).strip().strip("'\"").replace("\\", "/")
        while raw.startswith("./"):
            raw = raw[2:]
        if raw in order_set:
            line_by_file[raw] = line
            indices.append(i)

    if len(indices) < 10:
        return text

    ordered_lines = [line_by_file[name] for name in order if name in line_by_file]
    if len(ordered_lines) != len(indices):
        raise RuntimeError(
            "bootstrap.sql include set is ambiguous; refusing partial reorder"
        )

    for idx, line in zip(indices, ordered_lines):
        lines[idx] = line

    out = "\n".join(lines)
    return out + ("\n" if text.endswith("\n") else "")

def main() -> int:
    required = [MANIFEST, HELPER] + [ROOT / rel for rel in FILES]
    missing = [str(p) for p in required if not p.is_file()]
    if missing:
        print("[FAIL] Missing required file(s):")
        for item in missing:
            print(f"  - {item}")
        return 2

    obj = json.loads(MANIFEST.read_text(encoding="utf-8"))
    rows = obj.get("files")
    if not isinstance(rows, list):
        raise RuntimeError("DEPENDENCY_MANIFEST.json does not contain files[]")

    by_file = {row["file"]: row for row in rows}
    for rel in FILES:
        if rel not in by_file:
            raise RuntimeError(f"manifest row missing: {rel}")

    for rel, deps in FILES.items():
        by_file[rel]["depends_on"] = deps

    old_ordinals = sorted(row["ordinal"] for row in rows)
    if len(old_ordinals) != len(set(old_ordinals)):
        raise RuntimeError("manifest ordinals are not unique")

    ordered_rows = stable_toposort(rows)

    for row, ordinal in zip(ordered_rows, old_ordinals):
        row["ordinal"] = ordinal

    obj["files"] = ordered_rows

    transformed_sql: dict[Path, str] = {}
    for rel, deps in FILES.items():
        path = ROOT / rel
        text = path.read_text(encoding="utf-8")
        text = update_header(text, deps)
        text = update_preflight(text, rel, deps)
        text = update_completion(text, rel)
        transformed_sql[path] = text

    helper_text = update_helper_ordinals(
        HELPER.read_text(encoding="utf-8"),
        ordered_rows,
    )

    bootstrap_text = None
    if BOOTSTRAP.is_file():
        bootstrap_text = update_bootstrap_include_order(
            BOOTSTRAP.read_text(encoding="utf-8"),
            ordered_rows,
        )

    for path, text in transformed_sql.items():
        path.write_text(text, encoding="utf-8")

    MANIFEST.write_text(
        json.dumps(obj, indent=2) + "\n",
        encoding="utf-8",
    )
    HELPER.write_text(helper_text, encoding="utf-8")

    if bootstrap_text is not None:
        BOOTSTRAP.write_text(bootstrap_text, encoding="utf-8")

    pos = {row["file"]: i for i, row in enumerate(ordered_rows)}
    print("[PASS] Transaction-context dependency graph synchronized.")
    print(f"[INFO] 5709 manifest position: {pos[CONTEXT] + 1}/{len(ordered_rows)}")
    print("[INFO] Manifest neighborhood:")

    lo = max(0, pos[CONTEXT] - 4)
    hi = min(len(ordered_rows), pos[CONTEXT] + 5)
    for i in range(lo, hi):
        marker = "->" if ordered_rows[i]["file"] == CONTEXT else "  "
        print(f"  {marker} {ordered_rows[i]['ordinal']}: {ordered_rows[i]['file']}")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
