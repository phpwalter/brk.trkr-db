# BrickTrackr Part Lifecycle Viability Suite

This standalone suite evaluates BrickTrackr against the target LEGO Part lifecycle:

1. Discover / Source
2. Normalize / Match
3. Catalog
4. Inventory / Collection
5. Market / Valuation
6. Change Management
7. Archive / Retain

Cross-cutting checks cover execute-only runtime security and the ways parts
participate in manifests and wishlists.

## Result model

Each check returns:

- `PASS` — the capability exists.
- `GAP` — the lifecycle foundation is viable but a target capability is absent.
- `FAIL` — a foundational invariant is missing.

Overall verdict:

- `READY` / exit 0
- `PARTIAL` / exit 1
- `BLOCKED` / exit 2
- `ERROR` / exit 3

`GAP` is a roadmap outcome and must not fail Greenfield installation.

## Run

```text
python tools/run_part_lifecycle_viability.py \
  --database postgresql://root@localhost:5432/bricktrackr \
  --report logs/part_lifecycle_viability.json
```

Use libpq password handling (`PGPASSWORD`, pgpass, or service configuration).

## Coverage

The 26 checks cover:

- canonical PART identity
- external/source identity mapping
- source presence / last-seen provenance
- design / variant / LEGO element separation
- normalized color/mold/decoration state
- base variant deduplication
- design metadata and category
- part supersession
- source-value history
- durable administrator overrides
- BrickTrackr public part identifier
- loose-inventory exact variant references
- owned quantities
- storage allocations
- condition tracking
- source-attributed market prices
- valuation context over time
- dedicated market/valuation API
- source correction history
- importer reconciliation
- RETIRED / SOURCE_MISSING retention
- archive timestamp
- explicit hard-delete protection
- execute-only runtime security
- participation in versioned manifests
- Wishlist exact-part-variant references

## Lifecycle interpretation

Canonical part identity is long-lived. Source disappearance, source corrections,
new molds, alternate variants, and supersession must not rewrite or erase
historical identity. User inventory, Wishlist state, market observations, and
manifest usage remain separate from canonical catalog truth.
