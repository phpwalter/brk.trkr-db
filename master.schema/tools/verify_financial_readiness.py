#!/usr/bin/env python3
"""Statically verify BrickTrackr financial-readiness source anchors."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

def require(text, needle, label, errors):
    if needle not in text:
        errors.append(f"{label}: missing required source anchor: {needle}")

def main():
    errors=[]

    types=(ROOT/"0000_bootstrap/0002_types.sql").read_text()
    ledger=(ROOT/"0760_finance/0760_financial_ledger.sql").read_text()
    anchors=(ROOT/"0760_finance/0761_financial_readiness_anchors.sql").read_text()
    funcs=(ROOT/"1000_function/1014_finance_function.sql").read_text()
    grants=(ROOT/"1100_security/1107_grants.sql").read_text()
    validator=(ROOT/"1200_validation/1220_financial_readiness_validation.sql").read_text()

    require(types, "CREATE DOMAIN app.money_amount AS numeric(18,4)", "types", errors)
    require(types, "CREATE DOMAIN app.idempotency_key AS text", "types", errors)

    require(ledger, "idempotency_key app.idempotency_key NOT NULL UNIQUE", "ledger", errors)
    require(ledger, "request_hash app.sha256_digest NOT NULL", "ledger", errors)
    require(ledger, "financial_source_event_id uuid", "ledger", errors)

    for needle in [
        "CREATE TABLE finance.source_events",
        "payload_sha256 app.sha256_digest NOT NULL",
        "CREATE TRIGGER trg_finance_source_event_payload_hash",
        "ADD CONSTRAINT fk_finance_transaction_source_event",
        "ADD CONSTRAINT uq_finance_transaction_source_event",
    ]:
        require(anchors, needle, "financial anchors", errors)

    for needle in [
        "public.digest(",
        "v_existing_hash IS DISTINCT FROM v_request_hash",
        "different financial request",
        "CREATE TRIGGER trg_finance_ledger_currency",
        "CREATE TRIGGER trg_finance_posted_account_identity",
        "CREATE TRIGGER trg_finance_source_events_immutable",
    ]:
        require(funcs, needle, "finance functions", errors)

    # Runtime roles must remain excluded from the finance schema/table surface.
    require(grants, "finance,\n    operations,\n    reporting\nFROM lego_app;", "runtime grants", errors)

    # The installed-catalog validator must cover the important mechanical rules.
    for needle in [
        "app.money_amount must remain numeric(18,4)",
        "Source-event UPDATE must be blocked after insertion",
        "Ledger transaction/account currency consistency trigger is missing",
        "must not have direct privileges on %s",
    ]:
        require(validator, needle, "financial validator", errors)

    # Prohibit approximate/native monetary declarations in finance source DDL.
    finance_sources = ledger + "\n" + anchors
    if re.search(r"\b(?:real|double\s+precision|money)\b", finance_sources, re.I):
        # Ignore documentation/comment occurrences only by testing executable lines.
        executable = "\n".join(
            line for line in finance_sources.splitlines()
            if not line.lstrip().startswith(("*", "--"))
        )
        if re.search(r"\b(?:real|double\s+precision|money)\b", executable, re.I):
            errors.append("finance DDL: approximate/native money type detected")

    if errors:
        print("FINANCIAL READINESS VERIFICATION FAILED")
        for e in errors:
            print("-", e)
        return 1

    print("FINANCIAL READINESS VERIFICATION PASSED")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
