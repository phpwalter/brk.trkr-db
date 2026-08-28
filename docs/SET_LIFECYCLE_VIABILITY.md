# BrickTrackr Set Lifecycle Viability Suite

This suite evaluates the current BrickTrackr database against the target
canonical LEGO set lifecycle:

1. Import / Create
2. Canonicalize / enrich metadata
3. Manifest sync / semantic snapshot
4. Publish to public catalog
5. Maintain through ongoing source synchronization
6. Retire / archive without hard deletion

Collection-state checks are included because set instances must remain separate
from canonical set data. Wishlist lifecycle is intentionally **not** included;
it belongs to a separate viability suite and test run.

## Result model

Each check is classified as:

- `PASS` — capability exists.
- `GAP` — lifecycle foundation is sound, but a target feature is not implemented.
- `FAIL` — a foundational lifecycle invariant is missing.

Overall verdicts:

- `READY` / exit 0
- `PARTIAL` / exit 1
- `BLOCKED` / exit 2
- `ERROR` / exit 3

A `GAP` is a roadmap result and must not cause Greenfield installation to fail.

## Run

```text
python tools/run_set_lifecycle_viability.py \
  --database postgresql://root@localhost:5432/bricktrackr \
  --report logs/set_lifecycle_viability.json
```

Use normal libpq password handling (`PGPASSWORD`, pgpass, or service config).

## Coverage

The 25 checks cover:

- canonical SET identity
- source/Rebrickable identity mapping
- public BrickTrackr item identifier
- canonical set metadata
- source-value history and durable admin overrides
- image/instruction resource management
- SET_MANIFEST definition/version engine
- semantic version uniqueness
- finalized manifest immutability
- effective/current manifest authority
- manifest submodels/subassemblies
- edit revision / ETag support
- controlled catalog search
- system-managed set visibility
- set-to-catalog-item inclusions
- source-present / last-seen reconciliation
- durable override persistence
- ETag / If-Match concurrency
- SOURCE_MISSING lifecycle
- absence of normal-user delete/restore APIs for canonical sets
- collection entry/instance separation
- exact manifest-version pinning on set instances
- physical condition/completeness/assembly state
- runtime execute-only security
- importer reconciliation entry points

## Important lifecycle interpretation

Canonical LEGO sets are different from user-created MOCs/custom entities:

- source disappearance must not delete the canonical set;
- normal users never edit canonical set truth;
- collection-instance state never changes canonical catalog data;
- source values and administrator overrides remain separate;
- semantic manifest versions remain immutable snapshots;
- Wishlist lifecycle is tested separately.
