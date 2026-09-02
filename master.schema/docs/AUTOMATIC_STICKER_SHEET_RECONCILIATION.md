# Automatic Rebrickable Sticker-Sheet Reconciliation

BrickTrackr's Rebrickable CSV inventory represents sticker sheets in the
PART/inventory_parts source domain.  BrickTrackr promotes those source rows into
first-class STICKER_SHEET catalog items after Phase 5B.

The classifier uses the canonical Rebrickable part-category mapping and selects
categories whose name contains `sticker` (case-insensitive).  For each sticker:

- create/reuse `catalog.items(item_kind='STICKER_SHEET')`;
- create/update `catalog.sticker_sheets`;
- create/reuse a Rebrickable external identifier in namespace `STICKER_SHEET`;
- upsert `definition.set_manifest_components` for the latest imported inventory
  version of each SET;
- bind `component_catalog_item_id` to the promoted sticker-sheet item.

The full-refresh orchestrator calls
`import.reconcile_rebrickable_sticker_sheets(source_run_id)` automatically after
Phase 5B.

No direct canonical DML is granted to `brktrkr_import`; the reconciliation
function is SECURITY DEFINER and checks importer membership.
