# BrickTrackr MOC Lifecycle Viability Suite

This suite evaluates the current database against the target MOC lifecycle:

1. Create
2. Add Content
3. Edit (Working)
4. Create New Version
5. Publish / Share
6. Use in Collection
7. Soft Delete
8. Restore

It also evaluates the target cross-cutting principles: stable catalog identity,
immutable version history, current/default version semantics, owner-managed
visibility, optimistic concurrency, exact-version collection references,
data retention, and API coverage.

## Why this is separate from Greenfield

The suite intentionally detects product-design gaps. A healthy database may
therefore receive a `PARTIAL` verdict. These gaps must not make the canonical
Greenfield schema installation fail.

## Run

```text
python tools/run_moc_lifecycle_viability.py \
  --database postgresql://root@localhost:5432/bricktrackr \
  --report logs/moc_lifecycle_viability.json
```

Supply the database password through the normal libpq environment
(`PGPASSWORD`, pgpass, or service configuration), never in the command line.

## Verdicts

- `READY` / exit 0 — all foundation and target lifecycle capabilities exist.
- `PARTIAL` / exit 1 — foundations are sound, but one or more target lifecycle
  capabilities are still gaps.
- `BLOCKED` / exit 2 — a foundational invariant is missing.
- `ERROR` / exit 3 — the runner itself or database connection failed.

Individual checks are `PASS`, `GAP`, or `FAIL`.

## Expected first assessment

The present schema is expected to be strong on:

- canonical MOC identity and ownership
- revision-scoped assets/licenses/subassemblies
- draft vs published revisions
- immutable published revisions
- semantic MOC manifest versions
- immutable finalized manifest graphs
- private/unlisted/public visibility
- catalog-level collection ownership
- execute-only runtime security
- MOC read API coverage

Likely target gaps are intentionally tested rather than assumed:

- generated public MOC identifier (`item_num`-style)
- edit revision / ETag / If-Match concurrency
- exactly one current/default manifest
- exact-version pinning from collection state
- owner lifecycle mutation procedures
- MOC-specific soft-delete/restore procedures
- explicit hard-delete guard for authored MOC identity

The JSON report is suitable for a future dedicated GUI panel.
