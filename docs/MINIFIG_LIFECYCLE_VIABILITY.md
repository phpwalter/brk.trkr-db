# BrickTrackr Minifig Lifecycle Viability Suite

This suite evaluates the current BrickTrackr database against the target
minifigure lifecycle:

1. Create
2. Build Composition (working)
3. Version Composition (semantic snapshot)
4. Publish / Share
5. Maintain
6. Retire / Restore

It also evaluates collection usage, source provenance, authority behavior,
optimistic concurrency, and runtime security.

## Important distinction

The suite separates:

- `PASS` — the current schema supports the capability.
- `GAP` — the database foundation is sound, but the target lifecycle feature
  is not implemented yet.
- `FAIL` — a foundational lifecycle invariant is missing.

A `GAP` must not fail the Greenfield schema installation.

## Run

```text
python tools/run_minifig_lifecycle_viability.py \
  --database postgresql://root@localhost:5432/bricktrackr \
  --report logs/minifig_lifecycle_viability.json
```

Use libpq password handling (`PGPASSWORD`, pgpass, service configuration).
Do not place the password in the DSN.

## Verdicts

- `READY` / exit 0 — all foundation and target checks pass.
- `PARTIAL` / exit 1 — foundations pass but lifecycle product gaps remain.
- `BLOCKED` / exit 2 — one or more foundational invariants fail.
- `ERROR` / exit 3 — runner or database execution failure.

## Coverage

The 24 checks cover:

- canonical MINIFIGURE identity
- source/Rebrickable ID separation
- BrickTrackr public item identifier
- canonical-vs-custom lifecycle distinction
- normalized composition graph
- structural role / side / position metadata
- working edit revision
- semantic version uniqueness
- immutable finalized snapshots
- effective/default authority
- complete structural/accessory snapshot capability
- visibility
- set inclusion separation
- owner publish/share API
- durable admin corrections
- ETag / If-Match concurrency
- owner mutation/version API
- soft-delete/archive state
- approved catalog lifecycle procedures
- custom-owner delete/restore API
- personal collection identity reference
- exact composition-version pinning
- source presence / last-seen provenance
- execute-only runtime security

## Expected first assessment

The current schema is expected to be strong on canonical identity, source
mapping, normalized composition, immutable semantic versions, authority,
catalog-level collection ownership, provenance, and role separation.

Likely target gaps include:

- dedicated public `item_num`
- explicit canonical-vs-custom minifig discriminator
- working `edit_revision`
- minifig visibility
- owner-facing custom minifig lifecycle APIs
- ETag / If-Match enforcement
- custom-owner retire/restore procedures
- exact-version collection pinning

The JSON report is designed to be consumable by a future GUI viability panel.
