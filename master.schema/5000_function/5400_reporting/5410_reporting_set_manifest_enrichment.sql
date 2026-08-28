/*
===============================================================================
 File:           5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql
 Project:        BrickTrackr
 PostgreSQL:     16+
 Purpose:        Execute-only reporting view of SET manifest enrichment.
 Depends On:     0400_definitions/0410_set_manifest_components.sql
                 1100_security/1100_roles.sql
 Creates:        reporting.get_set_manifest_enrichment(text)
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql', ARRAY['0400_definitions/0410_set_manifest_components.sql', '1100_security/1100_roles.sql']::text[]);

CREATE OR REPLACE FUNCTION reporting.get_set_manifest_enrichment(
    p_set_num text
)
RETURNS TABLE (
    component_kind text,
    external_id text,
    display_name text,
    source_code text,
    source_url text,
    quantity integer,
    source_present boolean,
    component_catalog_item_id uuid,
    last_seen_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
    WITH set_id AS (
        SELECT ei.catalog_item_id
        FROM catalog.external_identifiers ei
        JOIN reference.external_sources es ON es.source_id = ei.source_id
        JOIN catalog.items ci ON ci.catalog_item_id = ei.catalog_item_id
        WHERE es.source_code = 'REBRICKABLE'
          AND ei.entity_namespace = 'SET'
          AND ci.item_kind = 'SET'::catalog.item_kind
          AND (
              ei.external_id = btrim(p_set_num)
              OR ei.external_id = btrim(p_set_num) || '-1'
              OR split_part(ei.external_id, '-', 1) = btrim(p_set_num)
          )
        ORDER BY CASE
            WHEN ei.external_id = btrim(p_set_num) || '-1' THEN 0
            WHEN ei.external_id = btrim(p_set_num) THEN 1
            ELSE 2
        END
        LIMIT 1
    )
    SELECT
        c.component_kind::text,
        c.external_id,
        c.display_name,
        c.source_code,
        c.source_url,
        c.quantity,
        c.source_present,
        c.component_catalog_item_id,
        c.last_seen_at
    FROM definition.set_manifest_components c
    JOIN set_id s ON s.catalog_item_id = c.set_catalog_item_id
    ORDER BY c.component_kind, c.external_id
$function$;

REVOKE ALL ON FUNCTION reporting.get_set_manifest_enrichment(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION reporting.get_set_manifest_enrichment(text)
TO lego_reporting;

SELECT pg_temp.bt_mark_completed('5000_function/5400_reporting/5410_reporting_set_manifest_enrichment.sql');
