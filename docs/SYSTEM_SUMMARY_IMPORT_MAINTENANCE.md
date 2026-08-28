# BrickTrackr System Summary — Import Maintenance

## Design

`reporting.system_summary` is a singleton cached system snapshot.

Canonical catalog counters are maintained incrementally by PostgreSQL
statement-level transition-table triggers on `catalog.items`.

This means a reconciliation statement that inserts 5,000 PART rows updates the
summary row once for the statement, not once for each row.

The source-run lifecycle is also tracked from `import.source_runs`.

## Why the Python importers are not modified

The current staging scripts do not perform canonical catalog DML. The
checkpointed reconciliation functions already own transactional/resume
semantics. Putting counters in Python would create retry/double-count risks.

Instead:

1. reconciliation changes `catalog.items`;
2. the same transaction updates `reporting.system_summary`;
3. rollback rolls back both;
4. resume processes only remaining canonical work.

## Cached metrics

The summary contains:

- total catalog items
- ACTIVE / RETIRED / SOURCE_MISSING / UNRESOLVED_CUSTOM / ARCHIVED counts
- SET
- PART
- MINIFIGURE
- BOOK
- MOC
- STICKER_SHEET
- INSTRUCTIONS
- PACKAGING
- GEAR
- ACCESSORY
- POLYBAG
- PROMOTIONAL_ITEM
- PUBLICATION
- OTHER
- latest Rebrickable source-run ID/status/timestamps

## Read surface

Runtime roles use:

```sql
SELECT reporting.get_system_summary();
```

They are not granted direct DML on the summary table.

## Existing databases

The module executes one initial:

```sql
SELECT reporting.rebuild_system_summary();
```

when installed. Normal imports do not rebuild the summary.

`reporting.rebuild_system_summary()` remains an owner/root repair operation and
is not granted to runtime roles.

## Full refresh logging

The updated `run_rebrickable_full_refresh.ps1` logs the cached summary after
canonical reconciliation phases 3B, 4B, 5B, and 6B.
