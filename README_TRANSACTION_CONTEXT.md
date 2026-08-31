# BrickTrackr Transaction Pooling & Request Context Hardening Package

This package replaces the BrickTrackr request-context implementation and adds
static, install-time, same-backend, actor-matrix, failure-recovery, and optional
real-PgBouncer verification.

## Files

- `master.schema/5000_function/5700_system/5709_system_request_context.sql`
  - canonical transaction-local setter, clearer, getters, ownership and ACLs.
- `master.schema/5000_function/5900_tests/5979_test_system_request_context.sql`
  - bootstrap-safe unit regression checks.
- `master.schema/1200_validation/1217_pgbouncer_transaction_context_validation.sql`
  - installed-catalog security/ACL/default-setting validation.
- `master.schema/tools/verify_transaction_context.py`
  - static source contract; forbids alternate writers and non-local writes.
- `master.schema/tools/verify_pgbouncer_transaction_context.psql`
  - real PgBouncer transaction-mode boundary checks.
- `master.schema/tools/verify_schema_contract.py`
  - full schema verifier with transaction-context static check added.
- `master.schema/tools/sync_transaction_context_dependencies.py`
  - synchronizes existing manifest/helper rows without inventing ordinals.
- `tests/transaction_context.sql`
  - same-backend COMMIT/ROLLBACK/autocommit/SAVEPOINT/error/validation suite.
- `tools/test_transaction_context.ps1`
  - direct PostgreSQL adversarial role-matrix and behavioral runner.
- `tools/verify_bricktrackr.ps1`
  - top-level database verification with the transaction-context suite added.
- `tools/apply_transaction_context_package.ps1`
  - copies the package into the repository, synchronizes dependency metadata,
    and runs dependency + static verification.

## Core security contract

| Actor class | Authorized capability |
|---|---|
| USER | `brktrkr_api` |
| ADMIN | `brktrkr_admin` |
| IMPORTER | `brktrkr_import` |
| SYSTEM | `brktrkr_migrator` or `brktrkr_owner` |

`brktrkr_owner` is deliberately **not** a fallback for USER, ADMIN, or IMPORTER.
This prevents the `brktrkr_migrator -> brktrkr_owner` membership relationship
from collapsing the actor-class boundary.

All four request GUCs are written only with:

```sql
pg_catalog.set_config(name, value, TRUE)
```

The `TRUE` flag is non-configurable and makes each setting transaction-local.

## Install

From the unpacked package directory:

```powershell
.\tools\apply_transaction_context_package.ps1 `
  -RepoRoot "L:\var\www\Brk.Trkr\brk.trkr-db"
```

The installer:
1. replaces the package files;
2. updates only the existing dependency-manifest rows for 5709, 5979, and 1217;
3. updates their runtime preflight-helper rows;
4. runs `verify_dependencies.py`;
5. runs `verify_transaction_context.py`.

It refuses to invent missing manifest ordinals.

## Full local verification

```powershell
cd L:\var\www\Brk.Trkr\brk.trkr-db
.\tools\verify_bricktrackr.ps1
```

The transaction-context runner defaults to the existing local development
login names and password `root`. Override any password/role with parameters if
the local environment differs.

If `identity.users` is empty or owner RLS intentionally hides all users, provide
an existing user UUID:

```powershell
.\tools\test_transaction_context.ps1 `
  -FixtureUser "00000000-0000-0000-0000-000000000000"
```

## Optional real PgBouncer verification

`verify_schema_contract.py` supports a production-equivalent PgBouncer endpoint:

```powershell
$env:BRICKTRACKR_PGBOUNCER_URL = "postgresql://..."
$env:BRICKTRACKR_PGBOUNCER_TEST_USER_ID = "<existing BrickTrackr user UUID>"

python .\master.schema\tools\verify_schema_contract.py `
  --pgbouncer-database $env:BRICKTRACKR_PGBOUNCER_URL `
  --pgbouncer-user-id $env:BRICKTRACKR_PGBOUNCER_TEST_USER_ID `
  --require-pgbouncer
```

The PgBouncer DSN must authenticate as the API runtime login/capability.

## Behavioral coverage

The suite verifies:

- USER context establishment.
- typed getter behavior.
- strict getter behavior.
- autocommit context wipe.
- COMMIT cleanup.
- ROLLBACK cleanup.
- SAVEPOINT rollback restoration.
- repeated context replacement.
- idempotent explicit clearing.
- failed-transaction recovery.
- rejected calls do not replace a valid outer context.
- missing USER UUID rejection.
- nonexistent USER rejection.
- NULL request ID rejection.
- blank trace rejection.
- oversized trace rejection.
- control-character trace rejection.
- invalid actor rejection.
- same PostgreSQL backend reuse with no leakage.
- API cannot self-elevate to ADMIN/IMPORTER/SYSTEM.
- ADMIN/IMPORTER/MIGRATOR cannot establish USER context.
- migrator's owner membership cannot claim ADMIN or IMPORTER.
- ADMIN, IMPORTER, SYSTEM positive role cases.
- SECURITY DEFINER identity lookup works under the installed forced-RLS policy.
- PUBLIC cannot execute context mutators.
- role/database defaults cannot pre-seed request GUCs.
- no authoritative SQL can introduce another context writer.
- no authoritative SQL can use `set_config(..., false)` for request context.

## Expected top-level result

```text
[PASS] Schema Contract Verification
[PASS] Transaction Context Contract Verification
[PASS] Admin User Contract Verification

===============================================================================
[PASS] BrickTrackr database verification completed successfully.
===============================================================================
```
