BrickTrackr Phase 6 bootstrap-order repair
=========================================

Fixes fresh bootstrap failure:

  relation "import.source_runs" does not exist

Cause:
  catalog.external_item_relationships was inserted into the canonical file
  containing catalog.item_relationships (0320...), but the provenance table has
  FKs to import.source_runs, which is created later in 0802_raw_staging.sql.

Repair:
- moves only the Phase 6 external_item_relationships table/index block to:
    0800_import/0802_raw_staging.sql
- keeps catalog.item_relationships in 0320
- keeps 0320 as a 1016 dependency
- adds 0802 as a 1016 dependency
- synchronizes:
    1016 Depends On header
    1016 inline bt_preflight()
    DEPENDENCY_MANIFEST.json
    0000_dependency_preflight runtime-helper row
- preserves 1016 ordinal
- automatically runs verify_dependencies.py

Dry run:
  .\run_repair_phase6_bootstrap_order.ps1 `
      -SchemaRoot ..\master.schema

Apply:
  .\run_repair_phase6_bootstrap_order.ps1 `
      -SchemaRoot ..\master.schema `
      -Apply
