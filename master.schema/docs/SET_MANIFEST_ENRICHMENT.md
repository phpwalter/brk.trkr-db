# SET Manifest Enrichment

Greenfield installs the schema and execute-only routines for source-backed
STICKER_SHEET, INSTRUCTIONS, and PACKAGING manifest evidence.

Installed automatically by `bootstrap.sql`:
- `definition.set_manifest_components`
- `import.upsert_set_manifest_component(...)`
- `import.mark_set_manifest_component_missing(...)`
- `reporting.get_set_manifest_enrichment(text)`
- validation `1226`
- stored-procedure contract test `5904`

The collector `import/enrich_set_manifest.py` is included in the repository but
is not invoked automatically for all sets by the Rebrickable nightly refresh.
It is intentionally per-set because sticker evidence currently comes from a
separate source and packaging remains curated/source-backed.

Example:
    python import/enrich_set_manifest.py --set-num 72005

The importer role remains execute-only and receives no direct DML on
`definition.set_manifest_components`.
