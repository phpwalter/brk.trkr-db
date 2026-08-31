#!/usr/bin/env python3
"""Static verification of BrickTrackr role/ownership separation."""
from pathlib import Path
import re, sys

ROOT = Path(__file__).resolve().parents[1]
ROLES = ROOT / "1100_security" / "1100_roles.sql"
OWNERSHIP = ROOT / "1100_security" / "1111_role_ownership_separation.sql"
VALIDATOR = ROOT / "1200_validation" / "1222_role_separation_validation.sql"
MIGRATOR = ROOT / "tools" / "apply_migrations.py"

def main() -> int:
    errors = []
    roles = ROLES.read_text(encoding="utf-8")
    ownership = OWNERSHIP.read_text(encoding="utf-8")
    validator = VALIDATOR.read_text(encoding="utf-8")
    migrator = MIGRATOR.read_text(encoding="utf-8")

    for role in ("brktrkr_owner", "brktrkr_migrator"):
        if f"CREATE ROLE {role}" not in roles:
            errors.append(f"{role}: missing role creation")
        if "NOLOGIN" not in roles:
            errors.append("role definitions must remain NOLOGIN")

    required_owner_fragments = [
        "GRANT brktrkr_owner TO brktrkr_migrator",
        "ALTER SCHEMA %I OWNER TO brktrkr_owner",
        "ALTER ROUTINE %s OWNER TO brktrkr_owner",
        "ALTER DEFAULT PRIVILEGES FOR ROLE brktrkr_owner",
        "REVOKE brktrkr_owner",
        "REVOKE brktrkr_migrator",
    ]
    for fragment in required_owner_fragments:
        if fragment not in ownership:
            errors.append(f"ownership contract missing: {fragment}")

    if "SET ROLE brktrkr_owner" not in migrator:
        errors.append("migration runner does not SET ROLE brktrkr_owner")

    for needle in (
        "pg_has_role('brktrkr_migrator', 'brktrkr_owner', 'MEMBER')",
        "An application schema is not owned by brktrkr_owner",
        "An application relation/sequence is not owned by brktrkr_owner",
        "An application routine is not owned by brktrkr_owner",
    ):
        if needle not in validator:
            errors.append(f"role-separation validator missing assertion: {needle}")

    # Operational group roles must never be made members of owner/deployer in source.
    forbidden = re.compile(
        r"GRANT\s+(?:brktrkr_owner|brktrkr_migrator)\s+TO\s+"
        r"(?:lego_api|lego_app|lego_admin|lego_importer|lego_reporting)\b",
        re.I
    )
    for p in ROOT.rglob("*.sql"):
        if "migrations" in p.relative_to(ROOT).parts:
            continue
        if forbidden.search(p.read_text(encoding="utf-8", errors="ignore")):
            errors.append(f"forbidden elevated membership grant in {p.relative_to(ROOT)}")

    if errors:
        print("ROLE SEPARATION VERIFICATION FAILED")
        for e in errors:
            print("-", e)
        return 1
    print("ROLE SEPARATION VERIFICATION PASSED")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
