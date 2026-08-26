/*
===============================================================================
 File:           5000_function/5200_api/5210_api_operational.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Introduce controlled runtime routines for catalog search,
                 notifications and collection transfers.
 Depends On:     catalog.item_search
                 catalog.items
                 catalog.item_images
                 catalog.instruction_assets
                 operations.notifications
                 collection.transfers
                 collection.entries
                 collection.storage_allocations
                 collection.entry_tags
                 wanted.build_allocations
                 identity.current_user_id()
                 identity.can_manage_owner()
 Creates:        api.search_catalog(...)
                 api.mark_notification_read(...)
                 api.transfer_collection_quantity(...)
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5200_api/5210_api_operational.sql', ARRAY['catalog.item_search', 'catalog.items', 'catalog.item_images', 'catalog.instruction_assets', 'operations.notifications', 'collection.transfers', 'collection.entries', 'collection.storage_allocations', 'collection.entry_tags', 'wanted.build_allocations', 'identity.current_user_id()', 'identity.can_manage_owner()']::text[]);



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

    INSERT INTO catalog.item_images(
        catalog_item_id, storage_key, alt_text, is_primary, sha256
    )
    VALUES (
        p_catalog_item_id, p_storage_key, p_alt_text, p_is_primary, p_sha256
    )
    ON CONFLICT (storage_key)
    DO UPDATE SET
        catalog_item_id = EXCLUDED.catalog_item_id,
        alt_text = EXCLUDED.alt_text,
        is_primary = EXCLUDED.is_primary,
        sha256 = EXCLUDED.sha256
    RETURNING catalog_item_image_id INTO v_image_id;

    RETURN v_image_id;
END;
$$;

CREATE OR REPLACE FUNCTION admin.remove_catalog_item_image(
    p_catalog_item_image_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
BEGIN
    DELETE FROM catalog.item_images
    WHERE catalog_item_image_id = p_catalog_item_image_id;
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
        instruction_catalog_item_id,
        storage_key,
        language_code,
        booklet_number,
        sha256,
        page_count
    )
    VALUES (
        p_instruction_catalog_item_id,
        p_storage_key,
        p_language_code,
        p_booklet_number,
        p_sha256,
        p_page_count
    )
    ON CONFLICT (storage_key)
    DO UPDATE SET
        instruction_catalog_item_id = EXCLUDED.instruction_catalog_item_id,
        language_code = EXCLUDED.language_code,
        booklet_number = EXCLUDED.booklet_number,
        sha256 = EXCLUDED.sha256,
        page_count = EXCLUDED.page_count
    RETURNING instruction_asset_id INTO v_asset_id;

    RETURN v_asset_id;
END;
$$;

CREATE OR REPLACE FUNCTION admin.remove_instruction_asset(
    p_instruction_asset_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, catalog
AS $$
BEGIN
    DELETE FROM catalog.instruction_assets
    WHERE instruction_asset_id = p_instruction_asset_id;
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
        RAISE EXCEPTION
            'Partial transfer of an entry with physical instances is ambiguous; transfer the complete entry'
            USING ERRCODE='23514';
    END IF;

    IF EXISTS (
        SELECT 1 FROM collection.storage_allocations
        WHERE collection_entry_id = p_collection_entry_id
    ) THEN
        RAISE EXCEPTION
            'Clear storage allocations before transferring a collection entry'
            USING ERRCODE='23514';
    END IF;

    IF EXISTS (
        SELECT 1 FROM wanted.build_allocations
        WHERE collection_entry_id = p_collection_entry_id
    ) THEN
        RAISE EXCEPTION
            'Release build allocations before transferring a collection entry'
            USING ERRCODE='23514';
    END IF;

    INSERT INTO collection.transfers(
        collection_entry_id, from_owner_id, to_owner_id, quantity,
        actor_user_id, reason
    )
    VALUES (
        p_collection_entry_id, v_from_owner, p_to_owner_id, p_quantity,
        v_user, p_reason
    );

    IF p_quantity = v_available THEN
        DELETE FROM collection.entry_tags
        WHERE collection_entry_id = p_collection_entry_id;

        UPDATE collection.entries
           SET owner_id = p_to_owner_id
         WHERE collection_entry_id = p_collection_entry_id;
    ELSE
        UPDATE collection.entries
           SET quantity = quantity - p_quantity
         WHERE collection_entry_id = p_collection_entry_id;

        INSERT INTO collection.entries(
            owner_id, catalog_item_id, part_variant_id, quantity, status
        )
        VALUES (
            p_to_owner_id, v_catalog_item_id, v_part_variant_id, p_quantity, 'ACTIVE'
        );
    END IF;
END;
$$;
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5210_api_operational.sql');
