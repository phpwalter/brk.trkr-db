BrickTrackr Rebrickable Phase 6A
================================

Dataset:
  rebrickable-downloads/part_relationships.csv.gz

Source contract:
  rel_type,child_part_num,parent_part_num

Expected rel_type values:
  A B M P R T

Behavior:
- validates exact CSV header
- validates all fields
- rejects unknown relation codes
- rejects duplicate exact triples
- computes compressed archive SHA-256
- creates a provenance source run
- stages every row into import.source_stage_records
- preserves the source self-link instead of dropping it
- stops at source run status VALIDATING
- performs NO canonical DML

Run:
  .\run_rebrickable_phase6a_secure.ps1

Expected:
  [PASS] Rebrickable Phase 6A staged successfully

Phase 6B is intentionally separate because BrickTrackr's generic
catalog.relationship_kind enum cannot losslessly represent every Rebrickable
relationship code.
