# Stored Procedure Tests — GUI Integration

Add a dedicated **Stored Procedure Tests** section to the left navigation,
separate from **Schema Contract Verification**.

The schema repository exposes:

    tools/run_stored_procedure_tests.py

Invoke it with the same console Python used by the existing verifier:

    python tools/run_stored_procedure_tests.py --database <DSN> --report <json-path>

Do not pass the Admin Password on the command line. Put it in the child process
environment using `PGPASSWORD`, matching the GUI's existing Settings behavior.

Recommended left-nav page:
- Run All Tests
- optional filename filter
- streaming output
- per-test PASS/FAIL status
- last run timestamp
- overall result

Stable output markers:
- [TEST START] <filename>
- [TEST PASS] <filename>
- [PASS] BrickTrackr stored procedure tests
- [FAIL] BrickTrackr stored procedure tests

Exit codes:
- 0 all tests passed
- 1 PostgreSQL test failure
- 2 runner/configuration/tool failure

The Run button should be disabled while the Admin Password is unavailable.
