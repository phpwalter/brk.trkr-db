#!/usr/bin/env python3
"""BrickTrackr transaction-context static contract verifier.

File:    master.schema/tools/verify_transaction_context.py
Version: 1.2.0

Purpose:
    Enforce the BrickTrackr transaction-context source contract while allowing
    narrowly-scoped, intentional transaction-local context writes used by
    administrative audit routines and security/adversarial validation.

Canonical writer:
    5000_function/5700_system/5709_system_request_context.sql

Intentional exceptions:
    1. 1200_validation/1215_security_contract_validation.sql
       may write request-context GUCs only to validate required/optional
       identity helper behavior and cleanup.

    2. 1200_validation/1216_adversarial_authorization_validation.sql
       may write request-context GUCs for adversarial authorization tests.

    3. 5000_function/5100_admin/*.sql
       may write app.actor_class for transaction-local ADMIN audit provenance.

    4. 5000_function/5900_tests/5901_test_identity_lifecycle.sql
       may write a malformed raw app.current_user_id GUC value to prove
       identity.current_user_id() fails closed (SQLSTATE 28000) instead of
       silently accepting corrupt context.

Hard failures:
    * set_config(..., FALSE) for any request-context GUC.
    * direct SET / SET LOCAL of request-context GUCs.
    * noncanonical production writes to app.current_user_id, app.request_id,
      or app.trace_id.
    * app.actor_class writes outside canonical 5709, admin routines, or the
      approved validation files.
    * weakening of the canonical 5709 security contract.
"""
from __future__ import annotations

from pathlib import Path
import re

FILE_VERSION = "1.2.0"

ROOT = Path(__file__).resolve().parents[1]
CANONICAL_REL = "5000_function/5700_system/5709_system_request_context.sql"
CANONICAL = ROOT / CANONICAL_REL

ADMIN_PREFIX = "5000_function/5100_admin/"
VALIDATION_ALLOWLIST = {
    "1200_validation/1215_security_contract_validation.sql",
    "1200_validation/1216_adversarial_authorization_validation.sql",
    "5000_function/5900_tests/5901_test_identity_lifecycle.sql",
}

CONTEXT_KEYS = {
    "app.current_user_id",
    "app.request_id",
    "app.trace_id",
    "app.actor_class",
}

EXCLUDED_PARTS = {
    ".git",
    ".venv",
    "__pycache__",
}


def strip_sql_comments(text: str) -> str:
    """Strip SQL comments while preserving executable SQL/PLpgSQL bodies."""
    out: list[str] = []
    i = 0
    n = len(text)
    state = "normal"
    block_depth = 0

    while i < n:
        if state == "normal":
            if text.startswith("--", i):
                state = "line_comment"
                out.extend("  ")
                i += 2
                continue

            if text.startswith("/*", i):
                state = "block_comment"
                block_depth = 1
                out.extend("  ")
                i += 2
                continue

            out.append(text[i])
            i += 1
            continue

        if state == "line_comment":
            if text[i] == "\n":
                state = "normal"
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue

        if state == "block_comment":
            if text.startswith("/*", i):
                block_depth += 1
                out.extend("  ")
                i += 2
            elif text.startswith("*/", i):
                block_depth -= 1
                out.extend("  ")
                i += 2
                if block_depth == 0:
                    state = "normal"
            else:
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            continue

    return "".join(out)


def split_top_level_args(body: str) -> list[str]:
    args: list[str] = []
    start = 0
    depth = 0
    state = "normal"
    i = 0

    while i < len(body):
        c = body[i]

        if state == "normal":
            if c == "'":
                state = "single"
            elif c == '"':
                state = "double"
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif c == "," and depth == 0:
                args.append(body[start:i].strip())
                start = i + 1

        elif state == "single":
            if c == "'":
                if i + 1 < len(body) and body[i + 1] == "'":
                    i += 1
                else:
                    state = "normal"

        elif state == "double":
            if c == '"':
                if i + 1 < len(body) and body[i + 1] == '"':
                    i += 1
                else:
                    state = "normal"

        i += 1

    args.append(body[start:].strip())
    return args


def iter_set_config_calls(text: str):
    lower = text.lower()
    pos = 0
    needle = "set_config"

    while True:
        idx = lower.find(needle, pos)
        if idx < 0:
            return

        paren = idx + len(needle)
        while paren < len(text) and text[paren].isspace():
            paren += 1

        if paren >= len(text) or text[paren] != "(":
            pos = idx + len(needle)
            continue

        i = paren + 1
        depth = 1
        state = "normal"

        while i < len(text) and depth:
            c = text[i]

            if state == "normal":
                if c == "'":
                    state = "single"
                elif c == '"':
                    state = "double"
                elif c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1

            elif state == "single":
                if c == "'":
                    if i + 1 < len(text) and text[i + 1] == "'":
                        i += 1
                    else:
                        state = "normal"

            elif state == "double":
                if c == '"':
                    if i + 1 < len(text) and text[i + 1] == '"':
                        i += 1
                    else:
                        state = "normal"

            i += 1

        if depth == 0:
            yield split_top_level_args(text[paren + 1:i - 1])

        pos = max(i, idx + len(needle))


def unquote_literal(value: str) -> str | None:
    value = value.strip()

    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1].replace("''", "'")

    return None


def sql_files():
    for path in ROOT.rglob("*.sql"):
        if any(part in EXCLUDED_PARTS for part in path.parts):
            continue
        yield path


def is_allowed_noncanonical_writer(rel: str, key: str) -> tuple[bool, str]:
    if rel in VALIDATION_ALLOWLIST:
        return True, "approved security/adversarial validation"

    if rel.startswith(ADMIN_PREFIX) and key == "app.actor_class":
        return True, "admin audit actor-class provenance"

    return False, ""


def verify_canonical(errors: list[str]) -> None:
    if not CANONICAL.is_file():
        errors.append(f"missing canonical file: {CANONICAL_REL}")
        return

    canonical = strip_sql_comments(
        CANONICAL.read_text(encoding="utf-8", errors="replace")
    )
    lower = canonical.lower()

    required_fragments = (
        "create or replace function app.set_request_context(",
        "security definer",
        "set search_path = pg_catalog",
        "create or replace function app.clear_request_context()",
        "security invoker",
        "identity.current_user_id()",
        "identity.require_current_user_id()",
        "app.current_request_id()",
        "app.current_trace_id()",
        "app.current_actor_class()",
        "owner to brktrkr_owner",
    )

    for fragment in required_fragments:
        if fragment not in lower:
            errors.append(
                f"5709 missing required contract fragment: {fragment}"
            )

    if "pg_catalog.nullif" in lower:
        errors.append("5709 illegally schema-qualifies NULLIF")

    owner_check = re.compile(
        r"pg_catalog\.pg_has_role\s*\(\s*"
        r"SESSION_USER\s*,\s*'brktrkr_owner'\s*,\s*'MEMBER'\s*\)",
        re.I | re.S,
    )

    branches = (
        ("USER", "ADMIN"),
        ("ADMIN", "IMPORTER"),
        ("IMPORTER", "SYSTEM"),
    )

    for start_actor, end_actor in branches:
        start = canonical.find(f"v_actor_class = '{start_actor}'")
        end = canonical.find(
            f"v_actor_class = '{end_actor}'",
            start + 1,
        )

        if start < 0 or end <= start:
            errors.append(
                f"5709 could not locate {start_actor} actor branch"
            )
            continue

        if owner_check.search(canonical[start:end]):
            errors.append(
                f"5709 {start_actor} authority branch contains forbidden "
                "brktrkr_owner fallback"
            )


def main() -> int:
    errors: list[str] = []
    allowed_writes: list[str] = []

    print("===============================================================================")
    print(" BrickTrackr Transaction Context Static Contract")
    print("===============================================================================")
    print(f"[INFO] Verifier version: {FILE_VERSION}")
    print(f"[INFO] Verifier path:    {Path(__file__).resolve()}")

    verify_canonical(errors)

    direct_set_pattern = re.compile(
        r"\bSET\s+(?:LOCAL\s+)?"
        r"(app\.current_user_id|app\.request_id|app\.trace_id|app\.actor_class)\b",
        re.I,
    )

    for path in sql_files():
        rel = path.relative_to(ROOT).as_posix()
        text = strip_sql_comments(
            path.read_text(encoding="utf-8", errors="replace")
        )

        for match in direct_set_pattern.finditer(text):
            errors.append(
                f"{rel}: direct SET/SET LOCAL of request-context GUC "
                f"is forbidden: {match.group(1)}"
            )

        for args in iter_set_config_calls(text):
            if len(args) < 3:
                continue

            key = unquote_literal(args[0])
            if key not in CONTEXT_KEYS:
                continue

            local_arg = re.sub(r"\s+", "", args[2]).lower()

            if local_arg != "true":
                errors.append(
                    f"{rel}: {key} must use set_config(..., TRUE); "
                    f"found third argument {args[2]!r}"
                )
                continue

            if rel == CANONICAL_REL:
                continue

            allowed, reason = is_allowed_noncanonical_writer(rel, key)

            if allowed:
                allowed_writes.append(
                    f"{rel}: {key} ({reason})"
                )
                continue

            errors.append(
                f"{rel}: unauthorized transaction-context writer: {key}"
            )

    if CANONICAL.is_file():
        canonical_raw = CANONICAL.read_text(
            encoding="utf-8",
            errors="replace",
        )

        for key in CONTEXT_KEYS:
            if canonical_raw.count(f"'{key}'") < 2:
                errors.append(
                    f"5709 does not contain both setter/clearer handling for {key}"
                )

    if errors:
        print("[FAIL] TRANSACTION CONTEXT VERIFICATION FAILED")
        for error in errors:
            print(f"- {error}")
        return 1

    print(
        f"[INFO] Accepted {len(allowed_writes)} intentional "
        "transaction-local noncanonical writer(s)."
    )

    for item in allowed_writes:
        print(f"[ALLOW] {item}")

    print("[PASS] TRANSACTION CONTEXT VERIFICATION PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
