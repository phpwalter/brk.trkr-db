/*
===============================================================================
 File:           5000_function/5200_api/5270_api_market_reporting.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Provide generalized market history, owned-inventory valuation
                 and operational reporting surfaces required by the v3 API.
 Depends On:     identity.current_user_id()
                 identity.can_view_owner()
                 catalog.items
                 catalog.part_variants
                 marketplace.market_price_observations
                 reference.external_sources
                 collection.entries
                 reporting.system_summary
 Creates:        api.market_reporting_operation()
 Key Rules:      Market observations are source-attributed history. Valuation is
                 a derived view and never rewrites owned cost/provenance.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5270_api_market_reporting.sql',
    ARRAY[
        'identity.current_user_id()',
        'identity.can_view_owner()',
        'catalog.items',
        'catalog.part_variants',
        'marketplace.market_price_observations',
        'reference.external_sources',
        'collection.entries',
        'reporting.system_summary'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.market_reporting_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, identity, catalog, marketplace, reference, collection, reporting
AS $$
DECLARE
    v_user uuid := identity.current_user_id();
    v_item_num text := NULLIF(p_params->>'item_num','');
    v_catalog_id uuid;
    v_currency text := upper(COALESCE(NULLIF(p_params->>'currency',''),'USD'));
    v_limit integer := LEAST(GREATEST(COALESCE((p_params->>'limit')::integer,50),1),200);
    v_result jsonb;
BEGIN
    IF p_operation IN ('get_catalog_market','get_catalog_market_history') THEN
        SELECT catalog_item_id INTO v_catalog_id FROM catalog.items WHERE item_num=v_item_num AND status NOT IN('ARCHIVED','UNRESOLVED_CUSTOM');
        IF v_catalog_id IS NULL THEN RAISE EXCEPTION 'Catalog item not found' USING ERRCODE='P0404'; END IF;
    END IF;

    CASE p_operation
    WHEN 'get_catalog_market' THEN
        WITH latest AS (
            SELECT DISTINCT ON (m.source_id,m.condition,m.currency,m.part_variant_id)
                   m.*,s.source_code,s.source_name
            FROM marketplace.market_price_observations m
            JOIN reference.external_sources s USING(source_id)
            WHERE (m.catalog_item_id=v_catalog_id OR m.part_variant_id IN(SELECT part_variant_id FROM catalog.part_variants WHERE part_catalog_item_id=v_catalog_id))
              AND (NULLIF(p_params->>'condition','') IS NULL OR m.condition::text=upper(p_params->>'condition'))
            ORDER BY m.source_id,m.condition,m.currency,m.part_variant_id,m.observed_at DESC
        )
        SELECT jsonb_build_object('item_num',v_item_num,'observations',COALESCE(jsonb_agg(jsonb_build_object(
            'source',source_code,'source_name',source_name,'condition',condition::text,'currency',currency::text,
            'low_price',low_price,'median_price',median_price,'high_price',high_price,'sample_size',sample_size,'observed_at',observed_at,
            'part_variant_id',part_variant_id
        ) ORDER BY source_code,condition,currency),'[]'::jsonb)) INTO v_result FROM latest;

    WHEN 'get_catalog_market_history' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'source',s.source_code,'source_name',s.source_name,'condition',m.condition::text,'currency',m.currency::text,
            'low_price',m.low_price,'median_price',m.median_price,'high_price',m.high_price,'sample_size',m.sample_size,
            'observed_at',m.observed_at,'part_variant_id',m.part_variant_id
        ) ORDER BY m.observed_at DESC),'[]'::jsonb) INTO v_result
        FROM (
            SELECT * FROM marketplace.market_price_observations x
            WHERE (x.catalog_item_id=v_catalog_id OR x.part_variant_id IN(SELECT part_variant_id FROM catalog.part_variants WHERE part_catalog_item_id=v_catalog_id))
              AND (NULLIF(p_params->>'from','') IS NULL OR x.observed_at>=(p_params->>'from')::timestamptz)
              AND (NULLIF(p_params->>'to','') IS NULL OR x.observed_at<=(p_params->>'to')::timestamptz)
            ORDER BY x.observed_at DESC LIMIT v_limit
        ) m JOIN reference.external_sources s USING(source_id);

    WHEN 'get_inventory_valuation' THEN
        WITH owned AS (
            SELECT e.collection_entry_id,e.owner_id,e.catalog_item_id,e.part_variant_id,e.quantity
            FROM collection.entries e
            WHERE e.status='ACTIVE' AND identity.can_view_owner(v_user,e.owner_id,'COLLECTION')
        ), priced AS (
            SELECT o.*,
                   COALESCE((
                       SELECT m.median_price
                       FROM marketplace.market_price_observations m
                       WHERE ((o.catalog_item_id IS NOT NULL AND m.catalog_item_id=o.catalog_item_id)
                              OR (o.part_variant_id IS NOT NULL AND m.part_variant_id=o.part_variant_id))
                         AND m.currency::text=v_currency
                       ORDER BY m.observed_at DESC LIMIT 1
                   ),0) AS unit_value
            FROM owned o
        )
        SELECT jsonb_build_object(
            'currency',v_currency,
            'estimated_value',COALESCE(sum(quantity*unit_value),0),
            'priced_entries',count(*) FILTER(WHERE unit_value>0),
            'unpriced_entries',count(*) FILTER(WHERE unit_value=0),
            'entries',COALESCE(jsonb_agg(jsonb_build_object('inventory_item_id',collection_entry_id,'quantity',quantity,'unit_value',unit_value,'extended_value',quantity*unit_value)),'[]'::jsonb)
        ) INTO v_result FROM priced;

    WHEN 'get_system_summary' THEN
        SELECT to_jsonb(s) INTO v_result FROM reporting.system_summary s LIMIT 1;
        v_result:=COALESCE(v_result,'{}'::jsonb);

    WHEN 'get_import_health' THEN
        SELECT jsonb_build_object(
            'summary',COALESCE((SELECT to_jsonb(s) FROM reporting.system_summary s LIMIT 1),'{}'::jsonb),
            'generated_at',now()
        ) INTO v_result;

    ELSE
        RAISE EXCEPTION 'Unknown market/reporting API operation: %',p_operation USING ERRCODE='22023';
    END CASE;

    RETURN COALESCE(v_result,'null'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.market_reporting_operation(text,jsonb) FROM PUBLIC;

\echo '[PASS] 5270_api_market_reporting.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5270_api_market_reporting.sql');
