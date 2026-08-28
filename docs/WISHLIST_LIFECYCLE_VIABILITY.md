# BrickTrackr Wishlist Lifecycle Viability Suite

This is a standalone Wishlist lifecycle assessment. It is intentionally
separate from the Set, MOC, Minifig, and Build Goal lifecycle suites.

The Wishlist lifecycle covered here is:

1. Create Wishlist
2. Add / Manage Entries
3. Share / View
4. Gift Reservations
5. Satisfy / Acquire
6. Archive / Restore

Cross-cutting checks cover runtime security, optimistic concurrency, and
separation of manual Wishlist intent from Build Goal shortages.

## Scope boundary

`wanted.build_goals` and `wanted.build_allocations` are not treated as Wishlist
lifecycle state. They represent build planning/shortage/allocation behavior and
should be assessed independently.

Wishlist intent remains manual acquisition intent.

## Result model

Each check returns:

- `PASS` — capability exists.
- `GAP` — the underlying lifecycle is viable, but the target feature is not yet
  implemented.
- `FAIL` — a foundational Wishlist invariant is missing.

Overall:

- `READY` / exit 0
- `PARTIAL` / exit 1
- `BLOCKED` / exit 2
- `ERROR` / exit 3

`GAP` findings are roadmap items and must not fail Greenfield installation.

## Run

```text
python tools/run_wishlist_lifecycle_viability.py \
  --database postgresql://root@localhost:5432/bricktrackr \
  --report logs/wishlist_lifecycle_viability.json
```

Use libpq password handling (`PGPASSWORD`, pgpass, or service configuration).

## Coverage

The 27 checks cover:

- owner-scoped Wishlist identity
- PRIVATE / FAMILY / PUBLIC visibility
- one active default Wishlist per owner
- Wishlist create/update runtime API
- catalog-item / part-variant target exclusivity
- desired quantity and priority
- preferred semantic inventory version
- target price / currency integrity
- entry mutation runtime API
- visibility-aware RLS
- owner-management RLS
- shared/public Wishlist read API
- retained gift reservations
- hidden-from-owner surprise reservations
- reserver-only modification
- reservation chronology
- reservation/release runtime API
- ACTIVE / PARTIALLY_SATISFIED / SATISFIED lifecycle
- satisfaction timestamps
- acquisition/satisfaction integration
- Wishlist soft archive
- entry archive state
- archive/restore runtime API
- hard-delete protection
- execute-only runtime security
- ETag / If-Match concurrency
- separation from Build Goal state

## Likely first-run gaps

The current schema already has a strong Wishlist data model and RLS layer.
Likely gaps are the application-facing stored-procedure/API surface, explicit
archive/restore procedures, hard-delete guards, and optimistic concurrency.
