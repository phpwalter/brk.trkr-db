BrickTrackr Rebrickable Phase 6B - semantic relationship reconciliation
======================================================================

Prerequisite:
  Phase 6A source run:
    01a02e65-b610-7d42-8e5e-87828deda6be

Design:
- Preserve every Rebrickable relationship in:
    catalog.external_item_relationships
- Full-snapshot SOURCE_MISSING semantics apply to that source provenance.
- Materialize only the exact safe canonical mapping:
    A -> catalog.relationship_kind ALTERNATE
- B/M/P/R/T remain source-valid UNMAPPED rows.
- Self-links remain source evidence but are QUARANTINED because
  catalog.item_relationships rejects self-links.
- Runtime importer has EXECUTE only; canonical DML is inside the
  SECURITY DEFINER reconcile function.
- app.set_import_context(source_run_id) is the only importer context setter.

Step 1 - install live schema/function hotfix as root:
  .\run_apply_phase6b_relationship_provenance_hotfix.ps1

Step 2 - reconcile as bricktrackr_import:
  .\run_rebrickable_phase6b_secure.ps1

Expected source run is already the default:
  01a02e65-b610-7d42-8e5e-87828deda6be

Step 3 - optional verification:
  psql -U root -d bricktrackr -f .\verify_rebrickable_phase6b.sql

This package is intentionally a live pre-canonicalization artifact.
After verification, the table/function/grants must be folded into master.schema
and the clean schema contract rerun.
