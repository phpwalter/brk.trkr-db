/*
===============================================================================
 File:           5000_function/5200_api/5210_api_operational.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.2.0
 PostgreSQL:     16+
 Purpose:        Controlled runtime routines for public catalog/search/set/part
                 reads, notifications and collection transfers.
 Depends On:     catalog.item_search
                 catalog.items
                 catalog.sets
                 catalog.parts
                 catalog.part_variants
                 catalog.external_identifiers
                 catalog.item_images
                 catalog.item_relationships
                 catalog.instruction_assets
                 reference.external_sources
                 reference.themes
                 definition.inventory_definitions
                 definition.inventory_versions
                 definition.requirement_groups
                 definition.requirement_options
                 definition.definition_authority
                 definition.effective_inventory_version(uuid)
                 marketplace.market_price_observations
                 operations.notifications
                 collection.transfers
                 collection.entries
                 collection.storage_allocations
                 collection.entry_tags
                 wanted.build_allocations
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5200_api/5210_api_operational.sql', ARRAY['catalog.item_search', 'catalog.items', 'catalog.sets', 'catalog.parts', 'catalog.part_variants', 'catalog.external_identifiers', 'catalog.item_images', 'catalog.item_relationships', 'catalog.instruction_assets', 'reference.external_sources', 'reference.themes', 'definition.inventory_definitions', 'definition.inventory_versions', 'definition.requirement_groups', 'definition.requirement_options', 'definition.definition_authority', 'definition.effective_inventory_version(uuid)', 'marketplace.market_price_observations', 'operations.notifications', 'collection.transfers', 'collection.entries', 'collection.storage_allocations', 'collection.entry_tags', 'wanted.build_allocations', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]);

CREATE OR REPLACE FUNCTION api.search_catalog(
    p_query text,
    p_limit integer DEFAULT 50
)
RETURNS TABLE (
    catalog_item_id uuid,
    canonical_name text,
    item_kind catalog.item_kind,
    rank real
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
    SELECT i.catalog_item_id,
           i.canonical_name,
           i.item_kind,
           GREATEST(
               ts_rank(s.search_document, plainto_tsquery('simple', p_query)),
               public.similarity(s.search_text, p_query)
           )::real AS rank
    FROM catalog.item_search s
    JOIN catalog.items i USING (catalog_item_id)
    WHERE i.status <> 'UNRESOLVED_CUSTOM'
      AND (
          s.search_document @@ plainto_tsquery('simple', p_query)
          OR s.search_text OPERATOR(public.%) p_query
      )
    ORDER BY rank DESC, i.canonical_name
    LIMIT LEAST(GREATEST(p_limit, 1), 200);
$$;

CREATE OR REPLACE FUNCTION api.search_catalog_public(
    p_query text,
    p_domain text DEFAULT 'all',
    p_limit integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
    WITH ranked AS (
        SELECT
            i.item_num,
            i.canonical_name,
            i.item_kind,
            GREATEST(
                ts_rank(s.search_document, plainto_tsquery('simple', p_query)),
                public.similarity(s.search_text, p_query)
            )::real AS rank
        FROM catalog.item_search s
        JOIN catalog.items i USING (catalog_item_id)
        WHERE i.item_num IS NOT NULL
          AND i.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED')
          AND (
              lower(p_domain) = 'all'
              OR (lower(p_domain) = 'set' AND i.item_kind = 'SET')
              OR (lower(p_domain) = 'part' AND i.item_kind = 'PART')
              OR (lower(p_domain) = 'minifig' AND i.item_kind = 'MINIFIGURE')
              OR (lower(p_domain) = 'moc' AND i.item_kind = 'MOC')
          )
          AND (
              s.search_document @@ plainto_tsquery('simple', p_query)
              OR s.search_text OPERATOR(public.%) p_query
          )
        ORDER BY rank DESC, i.canonical_name, i.item_num
        LIMIT LEAST(GREATEST(p_limit, 1), 200)
    )
    SELECT jsonb_build_object(
        'query', p_query,
        'domain', lower(p_domain),
        'results', COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'item_num', item_num,
                    'canonical_name', canonical_name,
                    'item_kind', item_kind::text,
                    'rank', rank
                ) ORDER BY rank DESC, canonical_name, item_num
            ),
            '[]'::jsonb
        )
    )
    FROM ranked;
$$;

CREATE OR REPLACE FUNCTION api.get_catalog_item_by_item_num(p_item_num text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
    SELECT jsonb_build_object(
        'item_num', i.item_num,
        'name', i.canonical_name,
        'revision', 1,
        'data', jsonb_build_object(
            'item_kind', i.item_kind::text,
            'status', i.status::text
        )
    )
    FROM catalog.items i
    WHERE i.item_num = p_item_num
      AND i.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED');
$$;

CREATE OR REPLACE FUNCTION api.get_set_by_item_num(p_item_num text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, reference
AS $$
    SELECT jsonb_build_object(
        'item_num', i.item_num,
        'name', i.canonical_name,
        'revision', 1,
        'data', jsonb_strip_nulls(jsonb_build_object(
            'item_kind', i.item_kind::text,
            'status', i.status::text,
            'lego_set_id', s.lego_set_id,
            'release_year', s.release_year,
            'theme_id', s.theme_id,
            'theme_name', t.theme_name,
            'primary_image_storage_key', img.storage_key
        ))
    )
    FROM catalog.items i
    JOIN catalog.sets s USING (catalog_item_id)
    LEFT JOIN reference.themes t ON t.theme_id = s.theme_id
    LEFT JOIN LATERAL (
        SELECT storage_key
        FROM catalog.item_images x
        WHERE x.catalog_item_id = i.catalog_item_id
        ORDER BY x.is_primary DESC, x.sort_order, x.created_at
        LIMIT 1
    ) img ON true
    WHERE i.item_num = p_item_num
      AND i.item_kind = 'SET'
      AND i.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED');
$$;

CREATE OR REPLACE FUNCTION api._manifest_version_json(p_inventory_version_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, definition, catalog, reference
AS $$
    SELECT jsonb_build_object(
        'version', v.semantic_version,
        'status', v.status::text,
        'semantic_hash', CASE WHEN v.semantic_hash IS NULL THEN NULL ELSE encode(v.semantic_hash, 'hex') END,
        'requirements', COALESCE((
            SELECT jsonb_agg(
                jsonb_strip_nulls(jsonb_build_object(
                    'requirement_key', g.requirement_key,
                    'required_quantity', g.required_quantity,
                    'fulfillment_rule', g.fulfillment_rule::text,
                    'minimum_options', g.minimum_options,
                    'is_required', g.is_required,
                    'is_spare', g.is_spare,
                    'sort_order', g.sort_order,
                    'notes', g.notes,
                    'options', COALESCE((
                        SELECT jsonb_agg(
                            jsonb_strip_nulls(jsonb_build_object(
                                'item_num', oi.item_num,
                                'part_num', pi.item_num,
                                'color_id', pv.color_id,
                                'decoration_code', pv.decoration_code,
                                'mold_code', pv.mold_code,
                                'option_quantity', o.option_quantity,
                                'is_primary', o.is_primary,
                                'minifig_role_id', o.minifig_role_id,
                                'side', o.side,
                                'position_index', o.position_index,
                                'notes', o.notes
                            )) ORDER BY o.requirement_option_id
                        )
                        FROM definition.requirement_options o
                        LEFT JOIN catalog.items oi
                          ON oi.catalog_item_id = o.catalog_item_id
                        LEFT JOIN catalog.part_variants pv
                          ON pv.part_variant_id = o.part_variant_id
                        LEFT JOIN catalog.items pi
                          ON pi.catalog_item_id = pv.part_catalog_item_id
                        WHERE o.requirement_group_id = g.requirement_group_id
                    ), '[]'::jsonb)
                )) ORDER BY g.sort_order NULLS LAST, g.requirement_group_id
            )
            FROM definition.requirement_groups g
            WHERE g.inventory_version_id = v.inventory_version_id
        ), '[]'::jsonb)
    )
    FROM definition.inventory_versions v
    WHERE v.inventory_version_id = p_inventory_version_id;
$$;

CREATE OR REPLACE FUNCTION api.get_set_manifest_by_item_num(p_item_num text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, definition
AS $$
    WITH target AS (
        SELECT i.catalog_item_id, i.item_num, i.canonical_name,
               d.inventory_definition_id
        FROM catalog.items i
        JOIN definition.inventory_definitions d
          ON d.catalog_item_id = i.catalog_item_id
         AND d.definition_kind = 'SET_MANIFEST'
        WHERE i.item_num = p_item_num
          AND i.item_kind = 'SET'
          AND i.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED')
    ), chosen AS (
        SELECT t.*,
               COALESCE(
                   definition.effective_inventory_version(t.inventory_definition_id),
                   (
                       SELECT v2.inventory_version_id
                       FROM definition.inventory_versions v2
                       WHERE v2.inventory_definition_id = t.inventory_definition_id
                         AND v2.status = 'FINALIZED'
                       ORDER BY v2.semantic_version DESC
                       LIMIT 1
                   )
               ) AS inventory_version_id
        FROM target t
    )
    SELECT jsonb_build_object(
        'item_num', c.item_num,
        'name', c.canonical_name || ' manifest',
        'revision', v.semantic_version,
        'data', api._manifest_version_json(v.inventory_version_id)
    )
    FROM chosen c
    JOIN definition.inventory_versions v
      ON v.inventory_version_id = c.inventory_version_id
    WHERE v.status = 'FINALIZED';
$$;

CREATE OR REPLACE FUNCTION api.get_set_manifest_versions_by_item_num(p_item_num text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, definition
AS $$
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'version', v.semantic_version,
            'etag', format('W/"v%s-rev%s"', v.semantic_version, v.semantic_version),
            'data', api._manifest_version_json(v.inventory_version_id)
        ) ORDER BY v.semantic_version DESC
    ), '[]'::jsonb)
    FROM catalog.items i
    JOIN definition.inventory_definitions d
      ON d.catalog_item_id = i.catalog_item_id
     AND d.definition_kind = 'SET_MANIFEST'
    JOIN definition.inventory_versions v
      ON v.inventory_definition_id = d.inventory_definition_id
     AND v.status = 'FINALIZED'
    WHERE i.item_num = p_item_num
      AND i.item_kind = 'SET'
      AND i.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED');
$$;

CREATE OR REPLACE FUNCTION api.get_set_manifest_version_by_item_num(
    p_item_num text,
    p_version integer
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, definition
AS $$
    SELECT jsonb_build_object(
        'version', v.semantic_version,
        'etag', format('W/"v%s-rev%s"', v.semantic_version, v.semantic_version),
        'data', api._manifest_version_json(v.inventory_version_id)
    )
    FROM catalog.items i
    JOIN definition.inventory_definitions d
      ON d.catalog_item_id = i.catalog_item_id
     AND d.definition_kind = 'SET_MANIFEST'
    JOIN definition.inventory_versions v
      ON v.inventory_definition_id = d.inventory_definition_id
     AND v.status = 'FINALIZED'
    WHERE i.item_num = p_item_num
      AND i.item_kind = 'SET'
      AND v.semantic_version = p_version
      AND i.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED');
$$;

CREATE OR REPLACE FUNCTION api.get_set_instruction_assets_by_item_num(p_item_num text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
    WITH target AS (
        SELECT catalog_item_id
        FROM catalog.items
        WHERE item_num = p_item_num
          AND item_kind = 'SET'
          AND status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED')
    ), instruction_items AS (
        SELECT DISTINCT CASE
            WHEN r.from_catalog_item_id = t.catalog_item_id THEN r.to_catalog_item_id
            ELSE r.from_catalog_item_id
        END AS instruction_catalog_item_id
        FROM target t
        JOIN catalog.item_relationships r
          ON r.from_catalog_item_id = t.catalog_item_id
          OR r.to_catalog_item_id = t.catalog_item_id
        JOIN catalog.items ii
          ON ii.catalog_item_id = CASE
              WHEN r.from_catalog_item_id = t.catalog_item_id THEN r.to_catalog_item_id
              ELSE r.from_catalog_item_id
          END
        WHERE ii.item_kind = 'INSTRUCTIONS'
          AND ii.status <> 'ARCHIVED'
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'name', COALESCE(i.canonical_name, 'Instructions'),
            'revision', 1,
            'data', jsonb_strip_nulls(jsonb_build_object(
                'instruction_item_num', i.item_num,
                'storage_key', a.storage_key,
                'language_code', a.language_code,
                'booklet_number', a.booklet_number,
                'page_count', a.page_count,
                'sha256', CASE WHEN a.sha256 IS NULL THEN NULL ELSE encode(a.sha256, 'hex') END
            ))
        ) ORDER BY a.booklet_number NULLS LAST, a.language_code NULLS LAST, a.storage_key
    ), '[]'::jsonb)
    FROM instruction_items x
    JOIN catalog.items i
      ON i.catalog_item_id = x.instruction_catalog_item_id
    JOIN catalog.instruction_assets a
      ON a.instruction_catalog_item_id = x.instruction_catalog_item_id;
$$;

CREATE OR REPLACE FUNCTION api.get_set_market_by_item_num(
    p_item_num text,
    p_condition text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, marketplace, reference
AS $$
    WITH target AS (
        SELECT catalog_item_id, item_num, canonical_name
        FROM catalog.items
        WHERE item_num = p_item_num
          AND item_kind = 'SET'
          AND status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED')
    ), latest AS (
        SELECT DISTINCT ON (m.source_id, m.condition, m.currency)
            m.*, es.source_code, es.source_name
        FROM target t
        JOIN marketplace.market_price_observations m
          ON m.catalog_item_id = t.catalog_item_id
        JOIN reference.external_sources es USING (source_id)
        WHERE p_condition IS NULL OR m.condition::text = upper(p_condition)
        ORDER BY m.source_id, m.condition, m.currency, m.observed_at DESC
    )
    SELECT jsonb_build_object(
        'item_num', t.item_num,
        'name', t.canonical_name || ' market',
        'revision', 1,
        'data', jsonb_build_object(
            'observations', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'source', l.source_code,
                    'source_name', l.source_name,
                    'condition', l.condition::text,
                    'currency', l.currency::text,
                    'low_price', l.low_price,
                    'median_price', l.median_price,
                    'high_price', l.high_price,
                    'sample_size', l.sample_size,
                    'observed_at', l.observed_at
                ) ORDER BY l.source_code, l.condition, l.currency)
                FROM latest l
            ), '[]'::jsonb)
        )
    )
    FROM target t;
$$;

CREATE OR REPLACE FUNCTION api.get_part_by_part_num(p_part_num text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, reference
AS $$
    SELECT jsonb_build_object(
        'item_num', i.item_num,
        'name', i.canonical_name,
        'revision', 1,
        'data', jsonb_strip_nulls(jsonb_build_object(
            'item_kind', i.item_kind::text,
            'status', i.status::text,
            'lego_design_id', p.lego_design_id,
            'design_name', p.design_name,
            'category_id', p.category_id
        ))
    )
    FROM catalog.items i
    JOIN catalog.parts p USING (catalog_item_id)
    WHERE i.item_num = p_part_num
      AND i.item_kind = 'PART'
      AND i.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED');
$$;

CREATE OR REPLACE FUNCTION api.get_part_where_used(
    p_part_num text,
    p_limit integer DEFAULT 50,
    p_cursor text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, definition
AS $$
    WITH part_target AS (
        SELECT catalog_item_id
        FROM catalog.items
        WHERE item_num = p_part_num
          AND item_kind = 'PART'
          AND status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED')
    ), used AS (
        SELECT DISTINCT si.item_num, si.canonical_name
        FROM part_target pt
        JOIN catalog.part_variants pv
          ON pv.part_catalog_item_id = pt.catalog_item_id
        JOIN definition.requirement_options o
          ON o.catalog_item_id = pt.catalog_item_id
          OR o.part_variant_id = pv.part_variant_id
        JOIN definition.requirement_groups g
          ON g.requirement_group_id = o.requirement_group_id
        JOIN definition.inventory_versions v
          ON v.inventory_version_id = g.inventory_version_id
         AND v.status = 'FINALIZED'
        JOIN definition.inventory_definitions d
          ON d.inventory_definition_id = v.inventory_definition_id
         AND d.definition_kind = 'SET_MANIFEST'
        JOIN catalog.items si
          ON si.catalog_item_id = d.catalog_item_id
        WHERE si.item_num IS NOT NULL
          AND si.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED')
          AND (p_cursor IS NULL OR si.item_num > p_cursor)
        ORDER BY si.item_num
        LIMIT LEAST(GREATEST(p_limit, 1), 200)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'item_num', item_num,
        'name', canonical_name,
        'revision', 1,
        'data', jsonb_build_object('item_kind', 'SET')
    ) ORDER BY item_num), '[]'::jsonb)
    FROM used;
$$;

CREATE OR REPLACE FUNCTION api.get_part_sources(p_part_num text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, reference
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'name', es.source_name,
        'revision', 1,
        'data', jsonb_strip_nulls(jsonb_build_object(
            'source_code', es.source_code,
            'external_id', ei.external_id,
            'external_version', ei.external_version,
            'source_present', ei.source_present,
            'first_seen_at', ei.first_seen_at,
            'last_seen_at', ei.last_seen_at
        ))
    ) ORDER BY es.source_code, ei.external_id), '[]'::jsonb)
    FROM catalog.items i
    JOIN catalog.external_identifiers ei
      ON ei.catalog_item_id = i.catalog_item_id
    JOIN reference.external_sources es USING (source_id)
    WHERE i.item_num = p_part_num
      AND i.item_kind = 'PART';
$$;

CREATE OR REPLACE FUNCTION api.get_part_market(
    p_part_num text,
    p_condition text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, marketplace, reference
AS $$
    WITH target AS (
        SELECT i.catalog_item_id, i.item_num, i.canonical_name
        FROM catalog.items i
        WHERE i.item_num = p_part_num
          AND i.item_kind = 'PART'
          AND i.status NOT IN ('UNRESOLVED_CUSTOM', 'ARCHIVED')
    ), latest AS (
        SELECT DISTINCT ON (m.source_id, m.condition, m.currency, m.part_variant_id)
            m.*, es.source_code, es.source_name
        FROM target t
        LEFT JOIN catalog.part_variants pv
          ON pv.part_catalog_item_id = t.catalog_item_id
        JOIN marketplace.market_price_observations m
          ON m.catalog_item_id = t.catalog_item_id
          OR m.part_variant_id = pv.part_variant_id
        JOIN reference.external_sources es USING (source_id)
        WHERE p_condition IS NULL OR m.condition::text = upper(p_condition)
        ORDER BY m.source_id, m.condition, m.currency, m.part_variant_id, m.observed_at DESC
    )
    SELECT jsonb_build_object(
        'item_num', t.item_num,
        'name', t.canonical_name || ' market',
        'revision', 1,
        'data', jsonb_build_object(
            'observations', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'source', l.source_code,
                    'source_name', l.source_name,
                    'condition', l.condition::text,
                    'currency', l.currency::text,
                    'low_price', l.low_price,
                    'median_price', l.median_price,
                    'high_price', l.high_price,
                    'sample_size', l.sample_size,
                    'observed_at', l.observed_at
                ) ORDER BY l.source_code, l.condition, l.currency)
                FROM latest l
            ), '[]'::jsonb)
        )
    )
    FROM target t;
$$;

CREATE OR REPLACE FUNCTION api.get_part_inventory_links(p_part_num text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, catalog, collection, identity
AS $$
    WITH target AS (
        SELECT catalog_item_id
        FROM catalog.items
        WHERE item_num = p_part_num
          AND item_kind = 'PART'
    ), rows AS (
        SELECT
            e.collection_entry_id,
            e.quantity,
            e.status,
            pv.color_id,
            pv.decoration_code,
            pv.mold_code
        FROM target t
        LEFT JOIN catalog.part_variants pv
          ON pv.part_catalog_item_id = t.catalog_item_id
        JOIN collection.entries e
          ON e.catalog_item_id = t.catalog_item_id
          OR e.part_variant_id = pv.part_variant_id
        WHERE e.status = 'ACTIVE'
          AND identity.can_view_owner(
              identity.current_user_id(),
              e.owner_id,
              'COLLECTION'
          )
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'name', 'Inventory entry',
        'revision', 1,
        'data', jsonb_strip_nulls(jsonb_build_object(
            'inventory_item_id', collection_entry_id::text,
            'quantity', quantity,
            'status', status::text,
            'color_id', color_id,
            'decoration_code', decoration_code,
            'mold_code', mold_code
        ))
    ) ORDER BY collection_entry_id), '[]'::jsonb)
    FROM rows;
$$;

CREATE OR REPLACE FUNCTION api.mark_notification_read(p_notification_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, operations, identity
AS $$
DECLARE
    v_user uuid := identity.current_user_id();
BEGIN
    UPDATE operations.notifications
       SET is_read = true,
           read_at = COALESCE(read_at, now())
     WHERE notification_id = p_notification_id
       AND user_id = v_user;
    RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION admin.set_catalog_item_image(
    p_catalog_item_id uuid,
    p_storage_key text,
    p_alt_text text DEFAULT NULL,
    p_is_primary boolean DEFAULT false,
    p_sha256 app.sha256_digest DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
DECLARE
    v_image_id uuid;
BEGIN
    IF p_is_primary THEN
        UPDATE catalog.item_images
           SET is_primary = false
         WHERE catalog_item_id = p_catalog_item_id
           AND is_primary;
    END IF;
    INSERT INTO catalog.item_images(catalog_item_id, storage_key, alt_text, is_primary, sha256)
    VALUES (p_catalog_item_id, p_storage_key, p_alt_text, p_is_primary, p_sha256)
    ON CONFLICT (storage_key)
    DO UPDATE SET catalog_item_id = EXCLUDED.catalog_item_id,
                  alt_text = EXCLUDED.alt_text,
                  is_primary = EXCLUDED.is_primary,
                  sha256 = EXCLUDED.sha256
    RETURNING catalog_item_image_id INTO v_image_id;
    RETURN v_image_id;
END;
$$;

CREATE OR REPLACE FUNCTION admin.remove_catalog_item_image(p_catalog_item_image_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
BEGIN
    DELETE FROM catalog.item_images WHERE catalog_item_image_id = p_catalog_item_image_id;
    RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION admin.set_instruction_asset(
    p_instruction_catalog_item_id uuid,
    p_storage_key text,
    p_language_code text DEFAULT NULL,
    p_booklet_number smallint DEFAULT NULL,
    p_sha256 app.sha256_digest DEFAULT NULL,
    p_page_count integer DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
DECLARE
    v_asset_id uuid;
BEGIN
    INSERT INTO catalog.instruction_assets(
        instruction_catalog_item_id, storage_key, language_code,
        booklet_number, sha256, page_count
    )
    VALUES (
        p_instruction_catalog_item_id, p_storage_key, p_language_code,
        p_booklet_number, p_sha256, p_page_count
    )
    ON CONFLICT (storage_key)
    DO UPDATE SET instruction_catalog_item_id = EXCLUDED.instruction_catalog_item_id,
                  language_code = EXCLUDED.language_code,
                  booklet_number = EXCLUDED.booklet_number,
                  sha256 = EXCLUDED.sha256,
                  page_count = EXCLUDED.page_count
    RETURNING instruction_asset_id INTO v_asset_id;
    RETURN v_asset_id;
END;
$$;

CREATE OR REPLACE FUNCTION admin.remove_instruction_asset(p_instruction_asset_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
BEGIN
    DELETE FROM catalog.instruction_assets WHERE instruction_asset_id = p_instruction_asset_id;
    RETURN FOUND;
END;
$$;

CREATE OR REPLACE PROCEDURE api.transfer_collection_quantity(
    p_collection_entry_id uuid,
    p_to_owner_id uuid,
    p_quantity app.quantity,
    p_reason text DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, collection, identity
AS $$
DECLARE
    v_user uuid := identity.current_user_id();
    v_from_owner uuid;
    v_available app.quantity;
    v_catalog_item_id uuid;
    v_part_variant_id uuid;
    v_status collection.entry_status;
    v_instance_count bigint;
BEGIN
    SELECT owner_id, quantity, catalog_item_id, part_variant_id, status
      INTO v_from_owner, v_available, v_catalog_item_id, v_part_variant_id, v_status
      FROM collection.entries
     WHERE collection_entry_id = p_collection_entry_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Collection entry not found' USING ERRCODE='P0002';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Only ACTIVE collection entries can be transferred' USING ERRCODE='23514';
    END IF;
    IF v_from_owner = p_to_owner_id THEN
        RAISE EXCEPTION 'Source and destination owners must differ' USING ERRCODE='23514';
    END IF;
    IF NOT identity.can_transfer_between(v_user, v_from_owner, p_to_owner_id) THEN
        RAISE EXCEPTION 'Transfer is not authorized' USING ERRCODE='42501';
    END IF;
    IF p_quantity > v_available THEN
        RAISE EXCEPTION 'Transfer quantity exceeds available quantity' USING ERRCODE='23514';
    END IF;

    SELECT count(*) INTO v_instance_count
    FROM collection.instances
    WHERE collection_entry_id = p_collection_entry_id
      AND archived_at IS NULL;

    IF v_instance_count > 0 AND p_quantity <> v_available THEN
        RAISE EXCEPTION 'Partial transfer of an entry with physical instances is ambiguous; transfer the complete entry' USING ERRCODE='23514';
    END IF;
    IF EXISTS (SELECT 1 FROM collection.storage_allocations WHERE collection_entry_id = p_collection_entry_id) THEN
        RAISE EXCEPTION 'Clear storage allocations before transferring a collection entry' USING ERRCODE='23514';
    END IF;
    IF EXISTS (SELECT 1 FROM wanted.build_allocations WHERE collection_entry_id = p_collection_entry_id) THEN
        RAISE EXCEPTION 'Release build allocations before transferring a collection entry' USING ERRCODE='23514';
    END IF;

    INSERT INTO collection.transfers(
        collection_entry_id, from_owner_id, to_owner_id, quantity, actor_user_id, reason
    ) VALUES (
        p_collection_entry_id, v_from_owner, p_to_owner_id, p_quantity, v_user, p_reason
    );

    IF p_quantity = v_available THEN
        DELETE FROM collection.entry_tags WHERE collection_entry_id = p_collection_entry_id;
        UPDATE collection.entries SET owner_id = p_to_owner_id WHERE collection_entry_id = p_collection_entry_id;
    ELSE
        UPDATE collection.entries SET quantity = quantity - p_quantity WHERE collection_entry_id = p_collection_entry_id;
        INSERT INTO collection.entries(owner_id, catalog_item_id, part_variant_id, quantity, status)
        VALUES (p_to_owner_id, v_catalog_item_id, v_part_variant_id, p_quantity, 'ACTIVE');
    END IF;
END;
$$;

/* SECURITY DEFINER routines are private until 1110_api_surface_lockdown.sql grants exact signatures. */
REVOKE EXECUTE ON FUNCTION api.search_catalog_public(text,text,integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_catalog_item_by_item_num(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_set_by_item_num(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_set_manifest_by_item_num(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_set_manifest_versions_by_item_num(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_set_manifest_version_by_item_num(text,integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_set_instruction_assets_by_item_num(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_set_market_by_item_num(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_part_by_part_num(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_part_where_used(text,integer,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_part_sources(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_part_market(text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.get_part_inventory_links(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api._manifest_version_json(uuid) FROM PUBLIC;

SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5210_api_operational.sql');
