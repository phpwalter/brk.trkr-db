# BrickTrackr Schema Contract CI

`tools/verify_schema_contract.py` is the single promotion gate for schema changes.

## Required local/static gate

```powershell
python tools/verify_schema_contract.py
```

This runs all source-level contract verifiers and requires no database.

## Full clean-database CI gate

Point `BRICKTRACKR_CI_DATABASE_URL` at a **disposable, empty PostgreSQL 16+ database**
using a deployment-capable login that can install the required extensions and create
roles/schemas.

```powershell
$env:BRICKTRACKR_CI_DATABASE_URL = "<disposable-ci-database-dsn>"
python tools/verify_schema_contract.py --require-database
```

The runner refuses to bootstrap if any BrickTrackr application schema already exists.
`bootstrap.sql` then runs the complete install-time/catalog/adversarial validation suite.

## Full promotion gate including query plans

```powershell
python tools/verify_schema_contract.py `
  --require-database `
  --query-plans
```

Query-plan checks should use production-equivalent PostgreSQL settings/statistics when
they are used as a release gate.

## PgBouncer transaction-pooling gate

Set `BRICKTRACKR_PGBOUNCER_URL` to the same PgBouncer transaction-pooling endpoint and
runtime database role used by the API:

```powershell
$env:BRICKTRACKR_PGBOUNCER_URL = "<runtime-pgbouncer-dsn>"

python tools/verify_schema_contract.py `
  --require-database `
  --query-plans `
  --require-pgbouncer
```

## Machine-readable report

```powershell
python tools/verify_schema_contract.py `
  --require-database `
  --report artifacts/schema-contract.json
```

A non-zero process exit code means the schema must not be promoted.

## Contract layers

1. Static source verification.
2. Fresh-database bootstrap and all SQL/catalog validators.
3. Optional production-equivalent query-plan verification.
4. Optional real PgBouncer COMMIT/ROLLBACK isolation verification.
5. Forward migrations remain independently checked by `verify_migrations.py` and are
   applied only by `apply_migrations.py`; production upgrade testing should run this
   same schema-contract gate against the resulting release candidate environment.
