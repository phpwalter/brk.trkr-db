#!/usr/bin/env python3
"""Static operational-integrity checks for the BrickTrackr master schema."""
from pathlib import Path
import re, sys

ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "1200_validation" / "1221_operational_integrity_validation.sql"

def main() -> int:
    errors = []
    validator = VALIDATOR.read_text()

    # The validator's reviewed index-name literals are the source contract for
    # static source verification. Keep this list in sync with the SQL validator.
    contract_names = re.findall(
        r"\('[a-z_]+','[a-z_]+','(ix_[a-z0-9_]+)'",
        validator,
        re.I,
    )
    contract_names = list(dict.fromkeys(contract_names))
    if not contract_names:
        errors.append("no critical-index contract entries found in 1221 validator")

    ddl_text = "\n".join(
        p.read_text()
        for p in ROOT.rglob("*.sql")
        if "1200_validation" not in p.relative_to(ROOT).parts
        and "migrations" not in p.relative_to(ROOT).parts
        and p.name != "bootstrap.sql"
    )

    for name in contract_names:
        count = len(re.findall(
            rf"\bCREATE\s+(?:UNIQUE\s+)?INDEX(?:\s+IF\s+NOT\s+EXISTS)?\s+{re.escape(name)}\b",
            ddl_text,
            re.I,
        ))
        if count != 1:
            errors.append(
                f"critical index {name}: expected exactly one CREATE INDEX, found {count}"
            )

    # Fresh-install bootstrap must not contain deferred integrity holes.
    for p in ROOT.rglob("*.sql"):
        rel = p.relative_to(ROOT)
        if "migrations" in rel.parts or "1200_validation" in rel.parts:
            continue
        text = p.read_text()
        if re.search(r"\bNOT\s+VALID\b", text, re.I):
            errors.append(f"{rel}: NOT VALID constraint is forbidden in master bootstrap")
        if re.search(r"\bCREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY\b", text, re.I):
            errors.append(
                f"{rel}: CREATE INDEX CONCURRENTLY is incompatible with atomic bootstrap"
            )

    if errors:
        print("OPERATIONAL INTEGRITY VERIFICATION FAILED")
        for error in errors:
            print(" -", error)
        return 1

    print(
        "OPERATIONAL INTEGRITY VERIFICATION PASSED: "
        f"{len(contract_names)} critical index contract(s)"
    )
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
