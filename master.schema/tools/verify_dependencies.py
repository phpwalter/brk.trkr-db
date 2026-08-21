#!/usr/bin/env python3
"""Verify BrickTrackr dependency declarations, bootstrap coverage, and generated preflights."""
from pathlib import Path
import json, re, sys

ROOT = Path(__file__).resolve().parents[1]

def deps_from_header(text: str):
    end = text.find("*/")
    head = text[:end] if end != -1 else text[:3000]
    m = re.search(
        r"Depends On:\s*(.*?)(?=\n\s*(?:Creates:|Purpose:|Key Rules:|Validation:|Notes:|Seed Data:|===============================================================================))",
        head, re.S | re.I
    )
    if not m:
        return None
    deps=[]
    for line in m.group(1).splitlines():
        s=re.sub(r"^\s*\*\s?", "", line).strip()
        if s:
            deps.append(s)
    return deps

def main():
    bootstrap=(ROOT/"bootstrap.sql").read_text()
    includes=re.findall(r"^\s*\\ir\s+([^\s]+)", bootstrap, re.M)
    unique=[]
    for x in includes:
        if x not in unique:
            unique.append(x)

    disk=sorted(
        p.relative_to(ROOT).as_posix()
        for p in ROOT.rglob("*.sql")
        if p.name != "bootstrap.sql"
    )
    errors=[]
    if set(disk) != set(unique):
        errors.append(f"bootstrap/disk mismatch: missing={sorted(set(disk)-set(unique))}, unknown={sorted(set(unique)-set(disk))}")

    manifest=json.loads((ROOT/"DEPENDENCY_MANIFEST.json").read_text())
    mf={x["file"]:x for x in manifest["files"]}

    # The runtime preflight helper embeds its own authoritative manifest. Verify
    # that generated copy too; otherwise headers/JSON/file preflights can agree
    # while the installation-time gate is stale.
    helper_text=(ROOT/"0000_bootstrap/0000_dependency_preflight.sql").read_text()
    helper_rows={}
    row_re=re.compile(
        r"\((\d+),\s*'([^']+)',\s*ARRAY\[(.*?)\]::text\[\]\)",
        re.S
    )
    for hm in row_re.finditer(helper_text):
        values=[
            v.replace("''", "'")
            for v in re.findall(r"'((?:''|[^'])*)'", hm.group(3))
        ]
        helper_rows[hm.group(2)]={
            "ordinal": int(hm.group(1)),
            "depends_on": values,
        }

    if set(helper_rows) != set(mf):
        errors.append(
            "runtime helper/JSON manifest file-set mismatch: "
            f"missing={sorted(set(mf)-set(helper_rows))}, "
            f"unknown={sorted(set(helper_rows)-set(mf))}"
        )

    for rel, entry in mf.items():
        h=helper_rows.get(rel)
        if h is None:
            continue
        if h["ordinal"] != entry["ordinal"]:
            errors.append(
                f"{rel}: runtime helper ordinal {h['ordinal']} differs "
                f"from JSON manifest {entry['ordinal']}"
            )
        if h["depends_on"] != entry["depends_on"]:
            errors.append(
                f"{rel}: runtime helper dependencies differ from JSON manifest"
            )

    completed=set()
    for rel in unique:
        text=(ROOT/rel).read_text()
        deps=deps_from_header(text)
        if deps is None:
            errors.append(f"{rel}: missing Depends On header")
            deps=[]

        if rel != "0000_bootstrap/0000_dependency_preflight.sql":
            m=re.search(r"SELECT pg_temp\.bt_preflight\('([^']+)', ARRAY\[(.*?)\]::text\[\]\);", text, re.S)
            if not m:
                errors.append(f"{rel}: missing generated preflight call")
            else:
                values=[v.replace("''","'") for v in re.findall(r"'((?:''|[^'])*)'",m.group(2))]
                if m.group(1) != rel:
                    errors.append(f"{rel}: preflight path mismatch")
                if values != deps:
                    errors.append(f"{rel}: preflight dependencies differ from header")
            if f"bt_mark_completed('{rel}')" not in text:
                errors.append(f"{rel}: missing completion marker")

        if rel not in mf:
            errors.append(f"{rel}: absent from DEPENDENCY_MANIFEST.json")
        elif mf[rel]["depends_on"] != deps:
            errors.append(f"{rel}: JSON manifest differs from header")

        for dep in deps:
            if dep.endswith(".sql") and dep not in completed:
                errors.append(f"{rel}: file dependency has not executed yet: {dep}")
            md=re.match(r"^Complete ([0-9]{4}_[A-Za-z0-9_]+) domain$",dep)
            if md:
                prefix=md.group(1)+"/"
                expected=[r for r in unique if r.startswith(prefix)]
                missing=[r for r in expected if r not in completed]
                if missing:
                    errors.append(f"{rel}: domain dependency incomplete: {dep}: {missing}")
        completed.add(rel)

    if errors:
        print("DEPENDENCY VERIFICATION FAILED")
        for e in errors:
            print("-",e)
        return 1

    print(f"DEPENDENCY VERIFICATION PASSED: {len(unique)} SQL files")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
