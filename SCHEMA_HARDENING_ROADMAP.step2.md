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

3. **Adversarial authorization tests — PLANNED**
   - User A vs User B, family/guardian revocation, stale JWT roles, forged body IDs, missing identity, admin-only paths.

4. **PgBouncer transaction-context contract tests — PLANNED**
   - Prove `app.current_user_id` is transaction-local and cannot leak between pooled requests.

5. **Stored-procedure/API surface manifest — STARTED**
   - Initial API allowlist is enforced by item 1.
   - Expand into a reviewed API contract with signatures, intended role, and authorization class.

6. **Forward-only migration discipline — PLANNED**
   - Fresh bootstrap + upgrade-from-previous-release tests; transactional/nontransactional migration classification.

7. **Financial-readiness invariants — PLANNED**
   - Mechanically verify money/currency/idempotency/immutability/source-event anchors and future ledger constraints.

8. **Operational integrity and plan regression checks — PLANNED**
   - FK/orphan/uniqueness/index assumptions plus representative EXPLAIN-plan guards for high-volume paths.

9. **Runtime/admin/deployment role separation — PARTIALLY ENFORCED**
   - Runtime vs admin separation now catalog-checked.
   - Deployment/owner role contract still to be formalized and checked.

10. **Single schema-contract CI entrypoint — PLANNED**
    - One command builds, migrates, runs dependency checks, security assertions, authorization tests, financial invariants, and destructive-change checks.

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
