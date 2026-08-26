#!/usr/bin/env python3
"""Static verifier for the BrickTrackr runtime api.* surface.

This complements 1218_api_surface_validation.sql:
- this script checks version-controlled SQL before database installation;
- 1218 checks the actual PostgreSQL catalog after installation.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LOCKDOWN = ROOT / "1100_security" / "1110_api_surface_lockdown.sql"

def split_args(arg_text: str):
    args = []
    buf = []
    depth = 0
    in_quote = False
    i = 0
    while i < len(arg_text):
        ch = arg_text[i]
        if ch == "'":
            in_quote = not in_quote
            buf.append(ch)
        elif not in_quote and ch == "(":
            depth += 1
            buf.append(ch)
        elif not in_quote and ch == ")":
            depth -= 1
            buf.append(ch)
        elif not in_quote and depth == 0 and ch == ",":
            args.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
        i += 1
    if "".join(buf).strip():
        args.append("".join(buf).strip())
    return args

def normalize_arg_type(arg: str):
    # Remove DEFAULT expression; current schema uses simple defaults.
    arg = re.split(r"\s+DEFAULT\s+", arg, maxsplit=1, flags=re.I)[0].strip()
    parts = arg.split()
    if not parts:
        return ""
    if parts[0].upper() in {"IN", "OUT", "INOUT", "VARIADIC"}:
        parts = parts[1:]
    # API declarations use named parameters. Drop the argument name.
    if len(parts) < 2:
        return parts[0].lower()
    return " ".join(parts[1:]).lower()

def created_api_signatures():
    found = set()
    pat = re.compile(
        r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|PROCEDURE)\s+"
        r"(api\.[A-Za-z_][A-Za-z0-9_]*)\s*\((.*?)\)"
        r"(?=\s*(?:RETURNS|LANGUAGE|AS|SECURITY|SET|;))",
        re.I | re.S,
    )
    for path in ROOT.rglob("*.sql"):
        if path.name == "bootstrap.sql":
            continue
        text = path.read_text()
        for m in pat.finditer(text):
            types = [normalize_arg_type(a) for a in split_args(m.group(2))]
            found.add(f"{m.group(1).lower()}({','.join(types)})")
    return found

def allowlisted_signatures():
    text = LOCKDOWN.read_text()
    insert = re.search(
        r"INSERT\s+INTO\s+app\.runtime_api_allowlist\s*\([^;]+?\)\s*VALUES\s*(.*?);",
        text,
        re.I | re.S,
    )
    if not insert:
        return set()
    return set(
        s.lower()
        for s in re.findall(r"\(\s*'(api\.[^']+\))'\s*,", insert.group(1), re.I)
    )

def main():
    errors = []
    if not LOCKDOWN.exists():
        errors.append("missing 1100_security/1110_api_surface_lockdown.sql")
    else:
        created = created_api_signatures()
        allowed = allowlisted_signatures()

        if created != allowed:
            errors.append(
                "api surface/allowlist mismatch: "
                f"unallowlisted={sorted(created-allowed)}, "
                f"missing={sorted(allowed-created)}"
            )

        all_sql = "\n".join(
            p.read_text()
            for p in ROOT.rglob("*.sql")
            if p.name != "bootstrap.sql"
        )
        broad = re.compile(
            r"GRANT\s+EXECUTE\s+ON\s+ALL\s+ROUTINES\s+IN\s+SCHEMA\s+api\s+"
            r"TO\s+[^;]*(?:lego_api|lego_app)",
            re.I | re.S,
        )
        if broad.search(all_sql):
            errors.append(
                "broad runtime API grant found; runtime EXECUTE must come only "
                "from app.runtime_api_allowlist"
            )

        lockdown = LOCKDOWN.read_text()
        if re.search(
            r"ALTER\s+DEFAULT\s+PRIVILEGES\s+IN\s+SCHEMA\s+api\s+"
            r"REVOKE\s+EXECUTE\s+ON\s+ROUTINES\s+FROM\s+PUBLIC",
            lockdown,
            re.I | re.S,
        ):
            errors.append(
                "PUBLIC routine default revoke is schema-local; PostgreSQL "
                "requires a global default revoke to remove built-in PUBLIC EXECUTE"
            )

        required = [
            r"ALTER\s+DEFAULT\s+PRIVILEGES\s+"
            r"REVOKE\s+EXECUTE\s+ON\s+ROUTINES\s+FROM\s+PUBLIC",
            r"REVOKE\s+EXECUTE\s+ON\s+ALL\s+ROUTINES\s+IN\s+SCHEMA\s+api\s+"
            r"FROM\s+PUBLIC\s*,\s*lego_api\s*,\s*lego_app",
            r"REVOKE\s+CREATE\s+ON\s+SCHEMA\s+api\s+"
            r"FROM\s+PUBLIC\s*,\s*lego_api\s*,\s*lego_app",
        ]
        for required_pattern in required:
            if not re.search(required_pattern, lockdown, re.I | re.S):
                errors.append(
                    "lockdown file is missing required deny-by-default control: "
                    + required_pattern
                )

    bootstrap = (ROOT / "bootstrap.sql").read_text()
    if "\\ir 1100_security/1110_api_surface_lockdown.sql" not in bootstrap:
        errors.append("bootstrap does not install 1110_api_surface_lockdown.sql")
    if "\\ir 1200_validation/1218_api_surface_validation.sql" not in bootstrap:
        errors.append("bootstrap does not execute 1218_api_surface_validation.sql")

    if errors:
        print("API SURFACE VERIFICATION FAILED")
        for e in errors:
            print("-", e)
        return 1

    print(
        "API SURFACE VERIFICATION PASSED: "
        f"{len(created_api_signatures())} allowlisted runtime routines"
    )
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
