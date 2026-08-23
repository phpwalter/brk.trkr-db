\set ON_ERROR_STOP on
\pset pager off

\echo '--- Phase 6B provenance counts ---'
SELECT
    source_relationship_code,
    reconciliation_status,
    source_present,
    count(*)::bigint AS rows
FROM catalog.external_item_relationships
WHERE source_id = (
    SELECT source_id
    FROM reference.external_sources
    WHERE source_code = 'REBRICKABLE'
)
  AND entity_namespace = 'PART_RELATIONSHIP'
GROUP BY source_relationship_code, reconciliation_status, source_present
ORDER BY source_relationship_code, reconciliation_status, source_present DESC;

\echo ''
\echo '--- Phase 6B canonical ALTERNATE count ---'
SELECT count(*)::bigint AS canonical_alternate_rows
FROM catalog.external_item_relationships e
JOIN catalog.item_relationships r
  ON r.catalog_item_relationship_id = e.catalog_item_relationship_id
WHERE e.source_id = (
    SELECT source_id
    FROM reference.external_sources
    WHERE source_code = 'REBRICKABLE'
)
  AND e.entity_namespace = 'PART_RELATIONSHIP'
  AND e.source_present
  AND e.source_relationship_code = 'A'
  AND e.reconciliation_status = 'MAPPED'
  AND r.relationship_kind = 'ALTERNATE';

\echo ''
\echo '--- Quarantine sample ---'
SELECT
    source_relationship_code,
    child_external_id,
    parent_external_id,
    reconciliation_note
FROM catalog.external_item_relationships
WHERE source_id = (
    SELECT source_id
    FROM reference.external_sources
    WHERE source_code = 'REBRICKABLE'
)
  AND entity_namespace = 'PART_RELATIONSHIP'
  AND source_present
  AND reconciliation_status = 'QUARANTINED'
ORDER BY external_relationship_key
LIMIT 20;
