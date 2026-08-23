BrickTrackr Rebrickable Phase 6 relationship contract
===================================================

This is a read-only inspection step before the Phase 6 importer/reconciler.

It reports:
- exact catalog.relationship_kind enum values
- catalog.item_relationships columns and constraints
- existing relationship-kind counts
- sample existing relationships between Rebrickable-linked PART items
- active PART external-identifier shape

Run from import:

  .\run_phase6_relationship_contract.ps1

Output:

  phase6_relationship_contract.txt
