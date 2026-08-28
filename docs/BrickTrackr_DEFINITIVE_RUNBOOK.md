# BrickTrackr database: definitive file/run order

Repository root assumed:

`L:\var\www\Brk.Trkr\brk.trkr-db`

## Human entry points — run only these

1. Greenfield schema build: `master.schema\install_bricktrackr_greenfield.ps1`
2. Initial Rebrickable data load: `run_rebrickable_initial_load.ps1`
3. Nightly Rebrickable refresh: `run_rebrickable_nightly.ps1`

Optional one-time scheduler registration: `register_rebrickable_nightly_task.ps1`

---

## 1. Greenfield database build

Run:

```powershell
cd L:\var\www\Brk.Trkr\brk.trkr-db
.\master.schema\install_bricktrackr_greenfield.ps1 -Database bricktrackr -ForceRecreate
```

Call graph:

```text
master.schema\install_bricktrackr_greenfield.ps1
  -> master.schema\tools\verify_dependencies.py
  -> psql: CREATE/DROP database
  -> master.schema\bootstrap.sql
       -> the 135 dependency-managed SQL files below, in manifest/bootstrap order
  -> installer smoke checks
```

### Complete greenfield SQL file order

001. `master.schema\0000_bootstrap\0000_dependency_preflight.sql`
002. `master.schema\0000_bootstrap\0000_extensions.sql`
003. `master.schema\0000_bootstrap\0001_schemas.sql`
004. `master.schema\0000_bootstrap\0002_types.sql`
005. `master.schema\0000_bootstrap\0003_uuid.sql`
006. `master.schema\0000_bootstrap\0004_validation_helpers.sql`
007. `master.schema\0000_bootstrap\0005_migration_framework.sql`
008. `master.schema\1200_validation\1200_bootstrap_validation.sql`
009. `master.schema\0100_identity\0100_users.sql`
010. `master.schema\0100_identity\0101_authentication.sql`
011. `master.schema\0100_identity\0102_families.sql`
012. `master.schema\0100_identity\0103_family_memberships.sql`
013. `master.schema\0100_identity\0104_family_permissions.sql`
014. `master.schema\0100_identity\0105_guardianships.sql`
015. `master.schema\0100_identity\0106_owners.sql`
016. `master.schema\1200_validation\1201_identity_validation.sql`
017. `master.schema\0200_reference\0200_external_sources.sql`
018. `master.schema\0200_reference\0201_colors.sql`
019. `master.schema\0200_reference\0202_themes.sql`
020. `master.schema\0200_reference\0203_categories.sql`
021. `master.schema\0200_reference\0204_minifig_roles.sql`
022. `master.schema\1200_validation\1202_reference_validation.sql`
023. `master.schema\0300_catalog\0300_catalog_items.sql`
024. `master.schema\0300_catalog\0301_catalog_sets.sql`
025. `master.schema\0300_catalog\0302_catalog_parts.sql`
026. `master.schema\0300_catalog\0303_catalog_minifigures.sql`
027. `master.schema\0300_catalog\0304_catalog_books.sql`
028. `master.schema\0300_catalog\0305_catalog_mocs.sql`
029. `master.schema\0300_catalog\0306_catalog_sticker_sheets.sql`
030. `master.schema\0300_catalog\0307_catalog_instructions.sql`
031. `master.schema\0300_catalog\0308_catalog_packaging.sql`
032. `master.schema\0300_catalog\0309_catalog_gear.sql`
033. `master.schema\0300_catalog\0310_catalog_accessories.sql`
034. `master.schema\0300_catalog\0311_catalog_polybags.sql`
035. `master.schema\0300_catalog\0312_catalog_promotional_items.sql`
036. `master.schema\0300_catalog\0313_catalog_publications.sql`
037. `master.schema\0300_catalog\0314_catalog_other.sql`
038. `master.schema\0300_catalog\0315_part_variants.sql`
039. `master.schema\0300_catalog\0316_lego_elements.sql`
040. `master.schema\0300_catalog\0317_external_identifiers.sql`
041. `master.schema\0300_catalog\0318_catalog_authority.sql`
042. `master.schema\0300_catalog\0319_part_tooling.sql`
043. `master.schema\0300_catalog\0320_catalog_search_media.sql`
044. `master.schema\1200_validation\1203_catalog_validation.sql`
045. `master.schema\0400_definitions\0400_inventory_definitions.sql`
046. `master.schema\0400_definitions\0401_inventory_versions.sql`
047. `master.schema\0400_definitions\0402_requirement_groups.sql`
048. `master.schema\0400_definitions\0403_requirement_options.sql`
049. `master.schema\0400_definitions\0404_definition_authority.sql`
050. `master.schema\0400_definitions\0405_manifest_graph.sql`
051. `master.schema\0400_definitions\0406_minifig_compositions.sql`
052. `master.schema\1200_validation\1204_definition_validation.sql`
053. `master.schema\0500_collections\0500_storage_locations.sql`
054. `master.schema\0500_collections\0501_collection_entries.sql`
055. `master.schema\0500_collections\0502_collection_instances.sql`
056. `master.schema\0500_collections\0503_instance_adjustments.sql`
057. `master.schema\0500_collections\0504_storage_allocations.sql`
058. `master.schema\0500_collections\0505_transfers.sql`
059. `master.schema\0500_collections\0506_acquisitions.sql`
060. `master.schema\0500_collections\0507_tags.sql`
061. `master.schema\1200_validation\1205_collection_validation.sql`
062. `master.schema\0600_wanted\0600_wishlists.sql`
063. `master.schema\0600_wanted\0601_wishlist_entries.sql`
064. `master.schema\0600_wanted\0602_wishlist_reservations.sql`
065. `master.schema\0600_wanted\0603_build_goals.sql`
066. `master.schema\0600_wanted\0604_build_allocations.sql`
067. `master.schema\1200_validation\1206_wanted_validation.sql`
068. `master.schema\0700_mocs\0700_mocs.sql`
069. `master.schema\0700_mocs\0701_moc_revisions.sql`
070. `master.schema\0700_mocs\0702_moc_forks.sql`
071. `master.schema\0700_mocs\0703_moc_subassemblies.sql`
072. `master.schema\0700_mocs\0704_moc_licenses.sql`
073. `master.schema\0700_mocs\0705_moc_assets.sql`
074. `master.schema\1200_validation\1207_moc_validation.sql`
075. `master.schema\0750_marketplace\0750_market_prices.sql`
076. `master.schema\0750_marketplace\0751_marketplace.sql`
077. `master.schema\0760_finance\0760_financial_ledger.sql`
078. `master.schema\0760_finance\0761_financial_readiness_anchors.sql`
079. `master.schema\0800_imports\0800_import_jobs.sql`
080. `master.schema\0800_imports\0801_source_runs.sql`
081. `master.schema\0800_imports\0802_raw_staging.sql`
082. `master.schema\0800_imports\0803_source_run_datasets.sql`
083. `master.schema\0800_imports\0804_normalized_records.sql`
084. `master.schema\0800_imports\0805_import_matches.sql`
085. `master.schema\0800_imports\0806_user_mapping_suggestions.sql`
086. `master.schema\0800_imports\0807_import_applications.sql`
087. `master.schema\1200_validation\1208_import_validation.sql`
088. `master.schema\0850_operations\0850_jobs_notifications.sql`
089. `master.schema\0900_audit\0900_audit_events.sql`
090. `master.schema\0900_audit\0901_audit_changes.sql`
091. `master.schema\1200_validation\1209_audit_validation.sql`
092. `master.schema\1000_function\1000_identity_function.sql`
093. `master.schema\1000_function\1001_hierarchy_function.sql`
094. `master.schema\1000_function\1002_catalog_function.sql`
095. `master.schema\1000_function\1003_definition_function.sql`
096. `master.schema\1000_function\1004_collection_function.sql`
097. `master.schema\1000_function\1005_wanted_function.sql`
098. `master.schema\1000_function\1006_moc_function.sql`
099. `master.schema\1000_function\1007_import_function.sql`
100. `master.schema\1000_function\1008_audit_function.sql`
101. `master.schema\1000_function\1009_integrity_hardening.sql`
102. `master.schema\1000_function\1010_moc_access_function.sql`
103. `master.schema\1000_function\1011_request_context.sql`
104. `master.schema\1000_function\1012_graph_function.sql`
105. `master.schema\1000_function\1013_operational_api.sql`
106. `master.schema\1000_function\1014_finance_function.sql`
107. `master.schema\1000_function\1015_rebrickable_reference_reconcile.sql`
108. `master.schema\1000_function\1016_rebrickable_catalog_reconcile.sql`
109. `master.schema\1000_function\1020_fail_source_run.sql`
110. `master.schema\1200_validation\1210_function_validation.sql`
111. `master.schema\1050_reporting\1050_reporting_views.sql`
112. `master.schema\1100_security\1100_roles.sql`
113. `master.schema\1100_security\1101_rls_identity.sql`
114. `master.schema\1100_security\1102_rls_collections.sql`
115. `master.schema\1100_security\1103_rls_wanted.sql`
116. `master.schema\1100_security\1104_rls_mocs.sql`
117. `master.schema\1100_security\1105_rls_imports.sql`
118. `master.schema\1100_security\1106_rls_audit.sql`
119. `master.schema\1100_security\1108_rls_catalog_definition.sql`
120. `master.schema\1100_security\1109_rls_extended.sql`
121. `master.schema\1100_security\1107_grants.sql`
122. `master.schema\1100_security\1110_api_surface_lockdown.sql`
123. `master.schema\1100_security\1111_role_ownership_separation.sql`
124. `master.schema\1200_validation\1211_security_validation.sql`
125. `master.schema\1200_validation\1212_integrity_validation.sql`
126. `master.schema\1200_validation\1214_extended_architecture_validation.sql`
127. `master.schema\1200_validation\1215_security_contract_validation.sql`
128. `master.schema\1200_validation\1216_adversarial_authorization_validation.sql`
129. `master.schema\1200_validation\1217_pgbouncer_transaction_context_validation.sql`
130. `master.schema\1200_validation\1218_api_surface_validation.sql`
131. `master.schema\1200_validation\1219_migration_framework_validation.sql`
132. `master.schema\1200_validation\1220_financial_readiness_validation.sql`
133. `master.schema\1200_validation\1221_operational_integrity_validation.sql`
134. `master.schema\1200_validation\1222_role_separation_validation.sql`
135. `master.schema\1200_validation\1213_dependency_validation.sql`

Also required by greenfield but not counted among the 135:

- `master.schema\bootstrap.sql`
- `master.schema\DEPENDENCY_MANIFEST.json`
- `master.schema\tools\verify_dependencies.py`

Recommended release/CI verifier, not called by normal greenfield installer:

- `master.schema\tools\verify_schema_contract.py`

---

## 2. Initial Rebrickable data load

Run only:

```powershell
.\run_rebrickable_initial_load.ps1
```

Call graph:

```text
run_rebrickable_initial_load.ps1
  -> import\download_rebrickable_snapshot.py
       -> downloads fresh 12-file snapshot to import\runtime\snapshots\<run-id>\
  -> import\run_rebrickable_full_refresh.ps1 -StartPhase PHASE1 -SnapshotDir <run snapshot>
       -> PHASE1  import\import_rebrickable_phase1.py
       -> PHASE2  import\import_rebrickable_phase2.py
       -> PHASE3A import\import_rebrickable_phase3.py
       -> PHASE3B import\reconcile_rebrickable_phase3_checkpointed.py
       -> PHASE4A import\import_rebrickable_phase4a_elements.py
       -> PHASE4B import\reconcile_rebrickable_phase4b_checkpointed.py
       -> PHASE5A import\import_rebrickable_phase5a_inventory.py
       -> PHASE5B import\reconcile_rebrickable_phase5b_checkpointed.py
       -> PHASE6A import\import_rebrickable_phase6a_relationships.py
       -> PHASE6B import\reconcile_rebrickable_phase6b_relationships.py
```

Required Rebrickable import files:

- `run_rebrickable_initial_load.ps1`
- `import\download_rebrickable_snapshot.py`
- `import\run_rebrickable_full_refresh.ps1`
- `import\import_rebrickable_phase1.py`
- `import\import_rebrickable_phase2.py`
- `import\import_rebrickable_phase3.py`
- `import\reconcile_rebrickable_phase3_checkpointed.py`
- `import\import_rebrickable_phase4a_elements.py`
- `import\reconcile_rebrickable_phase4b_checkpointed.py`
- `import\import_rebrickable_phase5a_inventory.py`
- `import\reconcile_rebrickable_phase5b_checkpointed.py`
- `import\import_rebrickable_phase6a_relationships.py`
- `import\reconcile_rebrickable_phase6b_relationships.py`

Fresh snapshot datasets downloaded every initial-load run:

- `themes.csv.gz`
- `colors.csv.gz`
- `part_categories.csv.gz`
- `parts.csv.gz`
- `sets.csv.gz`
- `minifigs.csv.gz`
- `elements.csv.gz`
- `inventories.csv.gz`
- `inventory_parts.csv.gz`
- `inventory_sets.csv.gz`
- `inventory_minifigs.csv.gz`
- `part_relationships.csv.gz`

These are runtime artifacts, not source-controlled prerequisites.

---

## 3. Nightly Rebrickable refresh

Run only:

```powershell
.\run_rebrickable_nightly.ps1
```

Call graph:

```text
run_rebrickable_nightly.ps1
  -> checks DB/importer connection + lock + no non-terminal run
  -> import\download_rebrickable_snapshot.py
       -> downloads a fresh 12-file snapshot
  -> import\run_rebrickable_full_refresh.ps1 -SnapshotDir <run snapshot>
       -> same PHASE1..PHASE6 Python files listed under Initial Load
  -> post-run lifecycle verification
  -> log/snapshot retention cleanup
```

Optional one-time Windows task registration:

```powershell
.\register_rebrickable_nightly_task.ps1
```

---

## Files that are NOT human entry points

Do not manually run the phase Python files during normal operations. They are called by `import\run_rebrickable_full_refresh.ps1`.

Do not manually run `master.schema\bootstrap.sql` during normal operations. It is called by the greenfield installer.

---

## Redundant/history files from the uploaded tree

- `patch_canonical_phase5b.ps1`
- `run_rebrickable_nightly_streaming.ps1`
- `import\run_rebrickable_full_refresh_streaming.ps1`
- `import\run_rebrickable_full_refresh_handoff.ps1`
- `import\run_rebrickable_full_refresh_finalizing.ps1`
- `import\run_rebrickable_full_refresh_resilient_fixed.ps1`
- `import\rebuild_phase5b_run_checkpoint.ps1`
- `import\rebuild_phase5b_run_checkpoint_v2.ps1`
- `import\rebuild_phase5b_run_checkpoint_v3.ps1`
- `import\rebuild_phase5b_run_checkpoint_v4.ps1`
- `import\-SchemaRoot`
- `master.schema\5000.zip`
- `master.schema\db.zip`
- `master.schema\1200_validation\master.schema.hardened-step1-fixed.zip`

Also redundant/history:

- every `*.bak`, `*.phase*.bak`, `*.pre*.bak` backup under `master.schema`
- old runtime logs
- old downloaded `.csv.gz` snapshot files

They should be archived outside the active deployable tree, then deleted after validation.

---

## Legacy wrappers not required for the three canonical workflows

- `master.schema\bootstrap.bat`
- `master.schema\bootstrap.ps1`
- `master.schema\bootstrap_with_dependency_check.ps1`
- `master.schema\verify.bat`

The canonical greenfield path is `master.schema\install_bricktrackr_greenfield.ps1 -> bootstrap.sql`.

---

## Exact operational order for a brand-new production database

```powershell
cd L:\var\www\Brk.Trkr\brk.trkr-db

# 1. Create database + canonical schema
.\master.schema\install_bricktrackr_greenfield.ps1 -Database bricktrackr -ForceRecreate

# 2. Populate all Rebrickable-backed data from a freshly downloaded snapshot
.\run_rebrickable_initial_load.ps1

# 3. Verify schema contract (release/CI gate)
python .\master.schema\tools\verify_schema_contract.py

# 4. Register nightly task once, if desired
.\register_rebrickable_nightly_task.ps1

# 5. Thereafter nightly execution is only:
.\run_rebrickable_nightly.ps1
```