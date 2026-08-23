BrickTrackr Rebrickable Phase 6 canonicalization
==============================================

This folds the verified Phase 6 relationship model into master.schema.

It:
- locates the canonical SQL file containing catalog.item_relationships
- adds catalog.external_item_relationships there
- adds import.phase6b_reconcile(uuid) to 1016_rebrickable_catalog_reconcile.sql
- adds Phase 6 ownership/revoke/grant rules to 1107_grants.sql
- grants lego_owner EXECUTE on app.set_import_context(uuid)
- adds the relationship-table SQL file to 1016's dependency contract
- synchronizes the 1016 header, inline bt_preflight(), and JSON manifest
- preserves the existing manifest ordinal and unrelated manifest fields
- runs tools/verify_dependencies.py automatically after apply

Dry run:
  .\run_canonicalize_rebrickable_phase6.ps1 `
      -SchemaRoot ..\master.schema

Apply:
  .\run_canonicalize_rebrickable_phase6.ps1 `
      -SchemaRoot ..\master.schema `
      -Apply

After PASS:
- recreate the disposable CI database
- run python .\tools\verify_schema_contract.py
