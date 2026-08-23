/*
===============================================================================
 BrickTrackr Rebrickable Phase 6 Relationship Contract Inspection
===============================================================================

 Purpose: Inspect the live canonical relationship model needed to map
          Rebrickable part_relationships rel_type codes exactly.

 No DML is performed.
===============================================================================
*/

\pset pager off
\set ON_ERROR_STOP on

\echo '==============================================================================='
\echo ' Phase 6 relationship contract'
\echo '==============================================================================='

\echo ''
\echo '--- catalog.relationship_kind enum values ---'
SELECT
    e.enumsortorder,
    e.enumlabel
FROM pg_type t
JOIN pg_namespace n
  ON n.oid = t.typnamespace
JOIN pg_enum e
  ON e.enumtypid = t.oid
WHERE n.nspname = 'catalog'
  AND t.typname = 'relationship_kind'
ORDER BY e.enumsortorder;

\echo ''
\echo '--- catalog.item_relationships columns ---'
SELECT
    a.attnum,
    a.attname,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
    a.attnotnull,
    pg_get_expr(ad.adbin, ad.adrelid) AS default_expr
FROM pg_attribute a
JOIN pg_class c
  ON c.oid = a.attrelid
JOIN pg_namespace n
  ON n.oid = c.relnamespace
LEFT JOIN pg_attrdef ad
  ON ad.adrelid = a.attrelid
 AND ad.adnum = a.attnum
WHERE n.nspname = 'catalog'
  AND c.relname = 'item_relationships'
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY a.attnum;

\echo ''
\echo '--- catalog.item_relationships constraints ---'
SELECT
    con.conname,
    con.contype,
    pg_get_constraintdef(con.oid, true) AS definition
FROM pg_constraint con
JOIN pg_class c
  ON c.oid = con.conrelid
JOIN pg_namespace n
  ON n.oid = c.relnamespace
WHERE n.nspname = 'catalog'
  AND c.relname = 'item_relationships'
ORDER BY con.contype, con.conname;

\echo ''
\echo '--- Existing relationship_kind counts ---'
SELECT
    relationship_kind,
    count(*)::bigint AS row_count
FROM catalog.item_relationships
GROUP BY relationship_kind
ORDER BY relationship_kind::text;

\echo ''
\echo '--- Existing Rebrickable-linked PART relationship sample ---'
WITH rb AS (
    SELECT source_id
    FROM reference.external_sources
    WHERE lower(source_name) = 'rebrickable'
    ORDER BY source_id
    LIMIT 1
),
part_ids AS (
    SELECT
        e.catalog_item_id,
        e.external_id
    FROM catalog.external_identifiers e
    JOIN rb
      ON rb.source_id = e.source_id
    WHERE e.entity_namespace = 'PART'
      AND e.source_present
)
SELECT
    fr.external_id AS from_part_num,
    tr.external_id AS to_part_num,
    r.relationship_kind
FROM catalog.item_relationships r
JOIN part_ids fr
  ON fr.catalog_item_id = r.from_catalog_item_id
JOIN part_ids tr
  ON tr.catalog_item_id = r.to_catalog_item_id
ORDER BY r.created_at, r.catalog_item_relationship_id
LIMIT 50;

\echo ''
\echo '--- Source/target PART external identifier shape ---'
WITH rb AS (
    SELECT source_id
    FROM reference.external_sources
    WHERE lower(source_name) = 'rebrickable'
    ORDER BY source_id
    LIMIT 1
)
SELECT
    count(*)::bigint AS active_part_external_ids,
    count(*) FILTER (WHERE catalog_item_id IS NULL)::bigint AS null_catalog_item_ids,
    count(*) FILTER (WHERE part_variant_id IS NOT NULL)::bigint AS unexpected_variant_ids
FROM catalog.external_identifiers e
JOIN rb
  ON rb.source_id = e.source_id
WHERE e.entity_namespace = 'PART'
  AND e.source_present;

\echo ''
\echo '[PASS] Phase 6 relationship contract inspection completed.'
