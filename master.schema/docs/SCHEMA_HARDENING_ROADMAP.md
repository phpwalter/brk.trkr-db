# Schema Hardening Roadmap

This file is the working implementation checklist for the ten schema-hardening items agreed during the security review.

## Status

1. **Database security verification suite — IMPLEMENTED (install-time contract)**
   - Added `1200_validation/1215_security_contract_validation.sql`.
   - Enforces execute-only runtime roles, no direct table/sequence privileges, no ownership, no schema CREATE, no BYPASSRLS/escalation attributes, hardened SECURITY DEFINER routines, no PUBLIC execution, elevated-role separation, and an explicit runtime API allowlist.
   - Hardened `1100_security/1107_grants.sql` so both `lego_api` and compatibility `lego_app` resolve to an execute-only runtime boundary.
   - Wired the verifier into security-domain and final bootstrap validation.
   - Added the previously missing `DEPENDENCY_MANIFEST.json` and updated the generated runtime manifest.

2. **Centralize and fail-close caller identity — IMPLEMENTED**
   - `identity.current_user_id()` now fails closed with SQLSTATE `28000` when authenticated request context is missing or malformed.
   - Added `identity.current_user_id_optional()` only for explicitly anonymous-safe PUBLIC/UNLISTED exact-ID reads.
   - MOC anonymous-safe API reads use the optional helper; protected RLS/procedure paths continue to use the required helper.
   - `1215_security_contract_validation.sql` proves helper behavior, rejects direct `app.current_user_id` reads outside the canonical helpers, restricts optional-helper consumers to an explicit allowlist, and rejects runtime API signatures that accept caller/authenticated identity arguments.

3. **Adversarial authorization tests — IMPLEMENTED**
   - `1216_adversarial_authorization_validation.sql` exercises User A vs User B denial, active/revoked guardianship, stale frontend JWT-role hints, missing identity, cross-user API mutation, and runtime/admin separation.
   - Fixtures execute inside a forced-rollback subtransaction and leave no persistent test rows.

4. **PgBouncer transaction-context contract tests — IMPLEMENTED; ENVIRONMENT PASS REQUIRED**
   - Added canonical `app.set_authenticated_user(uuid)` using transaction-local `set_config(..., true)`.
   - Hardened request/trace context helpers and `app.set_request_context(...)` with pinned `pg_catalog` search paths and transaction-local writes.
   - `1217_pgbouncer_transaction_context_validation.sql` rejects alternate context writers, role/database defaults, PUBLIC setter execution, and validates rollback/local-scope behavior.
   - `tools/verify_pgbouncer_transaction_context.psql` must be executed through the production-equivalent PgBouncer transaction-pooling endpoint to prove real COMMIT/ROLLBACK pool-boundary isolation.

5. **Stored-procedure/API surface manifest — IMPLEMENTED**
   - Added `app.runtime_api_allowlist` as the canonical reviewed runtime API contract.
   - Added `1100_security/1110_api_surface_lockdown.sql` to revoke ambient API execution, remove PUBLIC/runtime default EXECUTE, and grant only exact allowlisted signatures.
   - Runtime roles retain `USAGE` but never `CREATE` on `api`.
   - Added `1218_api_surface_validation.sql` to prove the installed runtime-executable set exactly equals the allowlist, all allowlisted routines are hardened SECURITY DEFINER routines, PUBLIC cannot execute any `api.*` routine, and every API routine owner has safe global routine defaults.
   - Removed runtime `GRANT EXECUTE ON ALL ROUTINES IN SCHEMA api` from `1107_grants.sql`.
   - New routines are therefore private by default and require an explicit reviewed allowlist/grant change before runtime use.

6. **Forward-only migration discipline — IMPLEMENTED; UPGRADE-PATH PASS REQUIRED**
   - Fresh databases continue to use `bootstrap.sql`; deployed databases begin from immutable baseline `master-schema-v10.0`.
   - Added `app.schema_migration_baseline` and append-only `app.schema_migrations` with SHA-256, transaction mode, application identity, timing, and release metadata.
   - Added `migrations/MIGRATION_MANIFEST.json`, strict naming/ordering rules, transactional/nontransactional classification, and a forward-only migration template.
   - `tools/verify_migrations.py` statically verifies migration files, manifest checksums, ordering, headers, and transaction ownership.
   - `tools/apply_migrations.py` verifies the target baseline and exact applied-history prefix/checksums before executing any pending migration.
   - `1219_migration_framework_validation.sql` mechanically proves migration metadata immutability and denies runtime/PUBLIC access.
   - Before closing this item for production, test a real upgrade from the previous deployed release using the migration runner and then run the complete schema contract suite.

7. **Financial-readiness invariants — COMPLETE**
   - Added `app.idempotency_key` and retained exact `numeric(18,4)` money semantics plus explicit currency domains.
   - Added immutable `finance.source_events` provenance anchors with canonical SHA-256 payload fingerprints.
   - Financial postings now bind each idempotency key to an exact request hash and reject key reuse with a different payload.
   - Added database-level ledger/account currency consistency and protection for posted account identity/currency fields.
   - Added one-to-one optional source-event linkage for financial transactions so future payment/refund events can be attached without redesign.
   - `1220_financial_readiness_validation.sql` mechanically checks precision, provenance, request fingerprinting, append-only behavior, balance/currency triggers, runtime isolation, and forbidden approximate/native money types.
   - `tools/verify_financial_readiness.py` statically verifies the source anchors before PostgreSQL installation.

8. **Operational integrity and plan regression checks — IMPLEMENTED; QUERY-PLAN ENVIRONMENT PASS REQUIRED**
   - Added `1221_operational_integrity_validation.sql` to reject unvalidated CHECK/FK constraints, disabled FK enforcement triggers, invalid/not-ready indexes, business tables without primary keys, and non-`timestamptz` lifecycle/event columns ending in `_at`.
   - Added a curated critical-index contract for authentication, authorization, catalog, collection, wishlist, MOC, import, audit, operations, finance, and marketplace access paths.
   - Added critical uniqueness checks for usernames, emails, session-token hashes, and one-time-token hashes.
   - Added `tools/verify_operational_integrity.py` for pre-install source checks and `tools/verify_query_plans.psql` for production-equivalent EXPLAIN-plan verification.
   - Query-plan verification must be run against a production-equivalent PostgreSQL environment because planner decisions depend on PostgreSQL settings/statistics.

9. **Runtime/admin/deployment role separation — COMPLETE**
   - Added dedicated `brktrkr_owner` and `brktrkr_migrator` NOLOGIN roles.
   - All application schemas, relations, routines, and standalone application types are transferred to `brktrkr_owner`.
   - `brktrkr_migrator` is the only BrickTrackr group role allowed to assume `brktrkr_owner`; runtime/admin/import/reporting roles are explicitly excluded.
   - Existing BrickTrackr roles are reconciled to exact capability envelopes so stale SUPERUSER/CREATEROLE/CREATEDB/REPLICATION privileges cannot survive deployment.
   - Owner default privileges are deny-by-default; future grants to runtime/admin/import/reporting roles must be explicit in a reviewed migration.
   - `1222_role_separation_validation.sql` checks ownership, membership boundaries, schema CREATE denial, and owner default ACLs.
   - `tools/verify_role_separation.py` performs pre-install source checks.
   - `tools/apply_migrations.py` now executes schema changes under `SET ROLE brktrkr_owner`.

10. **Single schema-contract CI entrypoint — IMPLEMENTED**
    - Added `tools/verify_schema_contract.py` as the single fail-closed promotion gate.
    - It runs every static verifier, optionally bootstraps a disposable clean PostgreSQL database (thereby running all install-time/catalog/adversarial validators), optionally runs production-equivalent query-plan checks, and optionally verifies real PgBouncer transaction-boundary isolation.
    - The runner refuses to bootstrap over an existing BrickTrackr database and can emit a machine-readable JSON CI report.
    - `docs/SCHEMA_CONTRACT_CI.md` defines required CI usage and promotion semantics.

## Security contract adopted

- OAuth/OIDC authentication is verified by the API middleware.
- The API controls application JWT issuance and validation.
- The immutable internal database user UUID is derived only from a verified token.
- Frontend JWT roles are UX hints only and are never authorization evidence.
- PostgreSQL is authoritative for authorization.
- PgBouncer uses transaction pooling.
- Request identity is transaction-local.
- Runtime database roles have zero direct table DML and call reviewed stored routines only.
- Admin access uses a separate elevated role.


## Step 3 implementation
`1200_validation/1216_adversarial_authorization_validation.sql` now tests cross-user denial, active/revoked guardianship, stale/forged frontend role hints, missing authenticated context, cross-user API mutation, and runtime/admin execution separation. Fixtures run in a forced-rollback PL/pgSQL subtransaction and leave no persistent rows.


## Step 4 implementation
The database now exposes one canonical authenticated-user setter: `app.set_authenticated_user(uuid)`. Runtime middleware must call it after `BEGIN`, followed by `app.set_request_context(...)`, then call the protected `api.*` routine(s), and finally `COMMIT` or `ROLLBACK`. Install-time validation proves the setters remain transaction-local and cannot be replaced by session defaults or alternate stored-routine writers. The external PgBouncer verification script is intentionally separate because the atomic bootstrap transaction cannot test a real COMMIT boundary without committing the installation.


## Step 5 implementation
The callable runtime API is now deny-by-default. `app.runtime_api_allowlist` is the single in-database source of truth for exact routine signatures. `1110_api_surface_lockdown.sql` first revokes API EXECUTE from PUBLIC and runtime roles, configures the routine owner's global default privileges so future routines do not inherit PostgreSQL's built-in PUBLIC EXECUTE, then grants only signatures present in the allowlist. `1218_api_surface_validation.sql` compares the actual executable routine set to that allowlist in both directions and fails deployment on drift.


## Step 6 implementation
Fresh installation and production evolution are now deliberately separate workflows.
`bootstrap.sql` creates the current schema and records baseline `master-schema-v10.0`;
it is not rerun over an existing production database. Forward changes are numbered,
immutable migration files. The local manifest stores each exact SHA-256, and the
target database stores the same checksum when the migration is applied. The runner
refuses to continue if target history is not an exact prefix of the local manifest,
if an applied checksum differs, if the target baseline differs, or if a migration
has been reordered/renamed. Migration files never own transaction boundaries.
Nontransactional migrations require an explicit reason and are treated as exceptional.


## Step 7 implementation
The existing `finance` domain already contained a double-entry ledger, so Step 7
strengthens that ledger rather than creating a competing future stub. Source
business events now have durable immutable identities and payload fingerprints.
Financial posting idempotency is payload-aware: reusing a key with a different
currency, description, order, or entry set is a hard failure instead of silently
returning the earlier transaction. Ledger currency compatibility is enforced in
PostgreSQL itself, and account identity/currency fields become immutable once an
account has posted entries. Runtime roles remain unable to access finance tables
directly.


## Step 8 implementation
Operational integrity is now treated as a deployment contract rather than a best-effort review. The bootstrap fails if referential/check constraints are left unvalidated, FK enforcement is disabled, an application index is invalid/not ready, a persistent business table loses its primary key, or lifecycle/event timestamp columns lose timezone awareness. A reviewed critical-index contract protects representative high-volume access paths. A separate EXPLAIN-based check verifies that those access paths remain index-usable in a production-equivalent environment.


## Step 9 implementation
Object ownership is now a separate trust boundary rather than an accidental property of
the bootstrap login. `brktrkr_owner` is a NOLOGIN role that owns BrickTrackr application
objects. `brktrkr_migrator` is a separate NOLOGIN deployment group and is the only
BrickTrackr group role permitted to assume `brktrkr_owner`. Operational admin remains
powerful but is intentionally not an owner and cannot CREATE in application schemas.
Future migrations execute under `SET ROLE brktrkr_owner`, so newly-created objects inherit
the same ownership/default-privilege contract instead of being owned by whichever human
or CI login happened to run the deployment.
