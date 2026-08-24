BrickTrackr Phase 5B refresh-idempotency fix v1.0.0
=====================================================

Root cause
----------
A repeated Rebrickable refresh sees the same source-backed inventory version
that is already FINALIZED.

The old Phase 5B code did:

  ON CONFLICT ... DO UPDATE last_seen_at, source_run_id

and requirement graph conflicts did DO UPDATE as well.

BrickTrackr correctly forbids both:
- finalized inventory version mutation
- finalized requirement graph mutation

Policy implemented
------------------
1. Existing FINALIZED source version with identical semantic hash:
     no canonical mutation; replay is accepted.

2. Existing FINALIZED source version with DIFFERENT semantic hash:
     fail with SQLSTATE 23514.
   Rebrickable must not reuse inventory_id + version for changed content.

3. New source version:
     create DRAFT, populate graph, hash, FINALIZE as before.

4. Requirement graph replay:
     ON CONFLICT DO NOTHING.
   This is safe for validated immutable staging and resumable DRAFT construction.

Canonical patch
---------------
Dry run:

  .\run_patch_phase5b_refresh_idempotency.ps1 `
      -SchemaRoot ..\master.schema

Apply:

  .\run_patch_phase5b_refresh_idempotency.ps1 `
      -SchemaRoot ..\master.schema `
      -Apply

The apply command automatically runs verify_dependencies.py.

Live install
------------
  .\run_install_phase5b_live_hotfix.ps1 `
      -SchemaRoot ..\master.schema

Retry the failed Phase 5B run
-----------------------------
Because P5B_VERSIONS failed before committing its first batch, normal resume is
sufficient; a restart is not required:

  .\run_rebrickable_phase5b_checkpointed.ps1

If multiple VALIDATING Phase 5 runs exist, pass the exact current SourceRunId
explicitly instead.

After Phase 5B succeeds, continue Phase 6/full-refresh validation and rerun the
fresh disposable schema contract before closing Phase 7.
