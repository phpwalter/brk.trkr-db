/*
===============================================================================
 File:           5000_function/5700_system/5708_system_integrity_hardening.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Enforce cross-table invariants that cannot be expressed safely
                 with single-row CHECK constraints, plus targeted supporting
                 indexes and lifecycle constraints.
 Depends On:     identity.users
                 identity.families
                 identity.guardianships
                 reference.themes
                 reference.categories
                 collection.storage_locations
                 collection.entries
                 collection.instances
                 collection.storage_allocations
                 collection.acquisition_items
                 wanted.wishlist_entries
                 wanted.build_goals
                 wanted.build_allocations
                 moc.revisions
                 moc.subassemblies
                 moc.forks
                 import.normalized_records
                 definition.definition_authority
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5700_system/5708_system_integrity_hardening.sql', ARRAY['identity.users', 'identity.families', 'identity.guardianships', 'reference.themes', 'reference.categories', 'collection.storage_locations', 'collection.entries', 'collection.instances', 'collection.storage_allocations', 'collection.acquisition_items', 'wanted.wishlist_entries', 'wanted.build_goals', 'wanted.build_allocations', 'moc.revisions', 'moc.subassemblies', 'moc.forks', 'import.normalized_records', 'definition.definition_authority']::text[]);



/* ==========================================================================
 * Stronger lifecycle constraints
 * ========================================================================== */

ALTER TABLE identity.users
    DROP CONSTRAINT ck_users_archived,
    ADD CONSTRAINT ck_users_archived
        CHECK (
            (account_status = 'ARCHIVED') =
            (archived_at IS NOT NULL)
        );

ALTER TABLE identity.families
    DROP CONSTRAINT ck_families_archived,
    ADD CONSTRAINT ck_families_archived
        CHECK (
            (status = 'ARCHIVED') =
            (archived_at IS NOT NULL)
        );

ALTER TABLE catalog.items
    DROP CONSTRAINT ck_catalog_items_archive,
    ADD CONSTRAINT ck_catalog_items_archive
        CHECK (
            (status = 'ARCHIVED') =
            (archived_at IS NOT NULL)
        );

ALTER TABLE collection.entries
    DROP CONSTRAINT ck_collection_entries_archive,
    ADD CONSTRAINT ck_collection_entries_archive
        CHECK (
            (status = 'ARCHIVED') =
            (archived_at IS NOT NULL)
        );

ALTER TABLE identity.one_time_tokens
    ADD CONSTRAINT ck_one_time_tokens_consumed_before_expiry
        CHECK (
            consumed_at IS NULL
            OR consumed_at <= expires_at
        );

ALTER TABLE identity.user_sessions
    ADD CONSTRAINT ck_user_sessions_last_seen_before_expiry
        CHECK (
            last_seen_at <= expires_at
        );


/* ==========================================================================
 * Definition integrity
 * ========================================================================== */

CREATE FUNCTION definition.validate_inventory_version_source_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.source_id IS NULL THEN
        IF NEW.source_external_id IS NOT NULL
           OR NEW.source_external_version IS NOT NULL
           OR NEW.source_run_id IS NOT NULL
        THEN
            RAISE EXCEPTION
                'Inventory source metadata requires source_id';
        END IF;
    ELSE
        IF NEW.source_external_id IS NULL
           OR btrim(NEW.source_external_id) = ''
        THEN
            RAISE EXCEPTION
                'Source-backed inventory version requires source_external_id';
        END IF;
    END IF;

    IF NEW.status = 'DRAFT'
       AND NEW.finalized_at IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Draft inventory version may not have finalized_at';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inventory_version_source_identity
BEFORE INSERT OR UPDATE OF
    source_id,
    source_external_id,
    source_external_version,
    source_run_id,
    status,
    finalized_at
ON definition.inventory_versions
FOR EACH ROW
EXECUTE FUNCTION definition.validate_inventory_version_source_identity();


CREATE FUNCTION definition.validate_inventory_finalization()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_bad_group bigint;
BEGIN
    IF NEW.status <> 'FINALIZED'
       OR OLD.status = 'FINALIZED'
    THEN
        RETURN NEW;
    END IF;

    SELECT rg.requirement_group_id
    INTO v_bad_group
    FROM definition.requirement_groups rg
    LEFT JOIN definition.requirement_options ro
      ON ro.requirement_group_id = rg.requirement_group_id
    WHERE rg.inventory_version_id = NEW.inventory_version_id
    GROUP BY
        rg.requirement_group_id,
        rg.fulfillment_rule,
        rg.minimum_options
    HAVING count(ro.requirement_option_id) = 0
        OR (
            rg.fulfillment_rule = 'AT_LEAST_N'
            AND count(ro.requirement_option_id) < rg.minimum_options
        )
    LIMIT 1;

    IF v_bad_group IS NOT NULL THEN
        RAISE EXCEPTION
            'Inventory version cannot be finalized: requirement group % has insufficient options',
            v_bad_group;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inventory_version_finalize_graph
BEFORE UPDATE OF status
ON definition.inventory_versions
FOR EACH ROW
EXECUTE FUNCTION definition.validate_inventory_finalization();


/* ==========================================================================
 * Catalog identity integrity
 * ========================================================================== */

CREATE UNIQUE INDEX uq_part_variants_identity
    ON catalog.part_variants (
        part_catalog_item_id,
        color_id,
        decoration_code,
        mold_code
    )
    NULLS NOT DISTINCT;

CREATE UNIQUE INDEX uq_lego_elements_active_id
    ON catalog.lego_elements(lego_element_id)
    WHERE valid_to IS NULL;

CREATE UNIQUE INDEX uq_user_mapping_suggestion_identity
    ON import.user_mapping_suggestions(
        user_id,
        source_id,
        entity_namespace,
        external_id
    );


/* ==========================================================================
 * Collection cross-row integrity
 * ========================================================================== */

CREATE FUNCTION collection.validate_instance_definition()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_entry_item uuid;
    v_version_item uuid;
BEGIN
    IF NEW.inventory_version_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT coalesce(
               e.catalog_item_id,
               pv.part_catalog_item_id
           )
    INTO v_entry_item
    FROM collection.entries e
    LEFT JOIN catalog.part_variants pv
      ON pv.part_variant_id = e.part_variant_id
    WHERE e.collection_entry_id = NEW.collection_entry_id;

    SELECT d.catalog_item_id
    INTO v_version_item
    FROM definition.inventory_versions v
    JOIN definition.inventory_definitions d
      ON d.inventory_definition_id = v.inventory_definition_id
    WHERE v.inventory_version_id = NEW.inventory_version_id;

    IF v_entry_item IS DISTINCT FROM v_version_item THEN
        RAISE EXCEPTION
            'Collection instance inventory version does not describe its collection entry';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_collection_instance_definition
BEFORE INSERT OR UPDATE OF
    collection_entry_id,
    inventory_version_id
ON collection.instances
FOR EACH ROW
EXECUTE FUNCTION collection.validate_instance_definition();


CREATE FUNCTION collection.validate_instance_adjustment()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_instance_version uuid;
    v_group_version uuid;
BEGIN
    IF NEW.expected_requirement_group_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT inventory_version_id
    INTO v_instance_version
    FROM collection.instances
    WHERE collection_instance_id = NEW.collection_instance_id;

    SELECT inventory_version_id
    INTO v_group_version
    FROM definition.requirement_groups
    WHERE requirement_group_id = NEW.expected_requirement_group_id;

    IF v_instance_version IS NULL THEN
        RAISE EXCEPTION
            'Adjustment references a requirement group but the instance has no inventory version';
    END IF;

    IF v_group_version IS DISTINCT FROM v_instance_version THEN
        RAISE EXCEPTION
            'Adjustment requirement group does not belong to the instance inventory version';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_instance_adjustment
BEFORE INSERT OR UPDATE OF
    collection_instance_id,
    expected_requirement_group_id
ON collection.instance_adjustments
FOR EACH ROW
EXECUTE FUNCTION collection.validate_instance_adjustment();


CREATE FUNCTION collection.validate_acquisition_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_acquisition_owner uuid;
    v_entry_owner uuid;
    v_instance_entry uuid;
BEGIN
    SELECT owner_id
    INTO v_acquisition_owner
    FROM collection.acquisitions
    WHERE acquisition_id = NEW.acquisition_id;

    SELECT owner_id
    INTO v_entry_owner
    FROM collection.entries
    WHERE collection_entry_id = NEW.collection_entry_id;

    IF v_acquisition_owner IS DISTINCT FROM v_entry_owner THEN
        RAISE EXCEPTION
            'Acquisition item and collection entry must have the same owner';
    END IF;

    IF NEW.collection_instance_id IS NOT NULL THEN
        SELECT collection_entry_id
        INTO v_instance_entry
        FROM collection.instances
        WHERE collection_instance_id = NEW.collection_instance_id;

        IF v_instance_entry IS DISTINCT FROM NEW.collection_entry_id THEN
            RAISE EXCEPTION
                'Acquisition instance does not belong to the acquisition collection entry';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_acquisition_item
BEFORE INSERT OR UPDATE
ON collection.acquisition_items
FOR EACH ROW
EXECUTE FUNCTION collection.validate_acquisition_item();


CREATE FUNCTION collection.validate_entry_tag()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_entry_owner uuid;
    v_tag_owner uuid;
BEGIN
    SELECT owner_id
    INTO v_entry_owner
    FROM collection.entries
    WHERE collection_entry_id = NEW.collection_entry_id;

    SELECT owner_id
    INTO v_tag_owner
    FROM collection.tags
    WHERE tag_id = NEW.tag_id;

    IF v_entry_owner IS DISTINCT FROM v_tag_owner THEN
        RAISE EXCEPTION
            'Collection entry and tag must have the same owner';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_entry_tag
BEFORE INSERT OR UPDATE
ON collection.entry_tags
FOR EACH ROW
EXECUTE FUNCTION collection.validate_entry_tag();


CREATE FUNCTION collection.validate_transfer()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_entry_owner uuid;
BEGIN
    SELECT owner_id
    INTO v_entry_owner
    FROM collection.entries
    WHERE collection_entry_id = NEW.collection_entry_id;

    IF v_entry_owner IS DISTINCT FROM NEW.from_owner_id THEN
        RAISE EXCEPTION
            'Transfer source entry is not owned by from_owner_id';
    END IF;

    IF NOT identity.can_transfer_between(
        NEW.actor_user_id,
        NEW.from_owner_id,
        NEW.to_owner_id
    ) THEN
        RAISE EXCEPTION
            'Transfer actor is not authorized for this source/destination ownership pair';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_transfer
BEFORE INSERT
ON collection.transfers
FOR EACH ROW
EXECUTE FUNCTION collection.validate_transfer();


CREATE FUNCTION collection.prevent_transfer_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'Collection transfers are immutable; record a compensating transfer instead';
END;
$$;

CREATE TRIGGER trg_transfers_immutable
BEFORE UPDATE OR DELETE
ON collection.transfers
FOR EACH ROW
EXECUTE FUNCTION collection.prevent_transfer_mutation();


/* ==========================================================================
 * Wishlist / build-goal cross-row integrity
 * ========================================================================== */

CREATE FUNCTION wanted.validate_wishlist_entry_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_version_item uuid;
BEGIN
    IF NEW.preferred_inventory_version_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF NEW.catalog_item_id IS NULL THEN
        RAISE EXCEPTION
            'A part-variant wishlist entry cannot select an inventory version';
    END IF;

    SELECT d.catalog_item_id
    INTO v_version_item
    FROM definition.inventory_versions v
    JOIN definition.inventory_definitions d
      ON d.inventory_definition_id = v.inventory_definition_id
    WHERE v.inventory_version_id = NEW.preferred_inventory_version_id;

    IF v_version_item IS DISTINCT FROM NEW.catalog_item_id THEN
        RAISE EXCEPTION
            'Preferred inventory version does not describe the wishlist catalog item';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_wishlist_entry_version
BEFORE INSERT OR UPDATE OF
    catalog_item_id,
    part_variant_id,
    preferred_inventory_version_id
ON wanted.wishlist_entries
FOR EACH ROW
EXECUTE FUNCTION wanted.validate_wishlist_entry_version();


CREATE FUNCTION wanted.validate_reservation_capacity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_desired app.quantity;
    v_reserved numeric;
BEGIN
    /* Serialize reservations for a wishlist entry. */
    SELECT desired_quantity
    INTO v_desired
    FROM wanted.wishlist_entries
    WHERE wishlist_entry_id = NEW.wishlist_entry_id
    FOR UPDATE;

    IF NEW.released_at IS NOT NULL
       OR (
           NEW.expires_at IS NOT NULL
           AND NEW.expires_at <= now()
       )
    THEN
        RETURN NEW;
    END IF;

    SELECT coalesce(sum(r.quantity), 0)
    INTO v_reserved
    FROM wanted.wishlist_reservations r
    WHERE r.wishlist_entry_id = NEW.wishlist_entry_id
      AND r.released_at IS NULL
      AND (
          r.expires_at IS NULL
          OR r.expires_at > now()
      )
      AND r.wishlist_reservation_id IS DISTINCT FROM
          NEW.wishlist_reservation_id;

    IF v_reserved + NEW.quantity > v_desired THEN
        RAISE EXCEPTION
            'Active wishlist reservations would exceed desired quantity';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_wishlist_reservation_capacity
BEFORE INSERT OR UPDATE OF
    wishlist_entry_id,
    quantity,
    expires_at,
    released_at
ON wanted.wishlist_reservations
FOR EACH ROW
EXECUTE FUNCTION wanted.validate_reservation_capacity();


CREATE FUNCTION wanted.validate_build_goal()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_version_item uuid;
    v_instance_owner uuid;
    v_instance_item uuid;
BEGIN
    SELECT d.catalog_item_id
    INTO v_version_item
    FROM definition.inventory_versions v
    JOIN definition.inventory_definitions d
      ON d.inventory_definition_id = v.inventory_definition_id
    WHERE v.inventory_version_id = NEW.inventory_version_id;

    IF v_version_item IS DISTINCT FROM NEW.target_catalog_item_id THEN
        RAISE EXCEPTION
            'Build-goal inventory version does not describe target_catalog_item_id';
    END IF;

    IF NEW.build_goal_type = 'COMPLETE_OWNED_INSTANCE' THEN
        IF NEW.collection_instance_id IS NULL THEN
            RAISE EXCEPTION
                'COMPLETE_OWNED_INSTANCE requires collection_instance_id';
        END IF;

        SELECT
            e.owner_id,
            e.catalog_item_id
        INTO
            v_instance_owner,
            v_instance_item
        FROM collection.instances i
        JOIN collection.entries e
          ON e.collection_entry_id = i.collection_entry_id
        WHERE i.collection_instance_id = NEW.collection_instance_id;

        IF v_instance_owner IS DISTINCT FROM NEW.owner_id THEN
            RAISE EXCEPTION
                'Build-goal instance must belong to the build-goal owner';
        END IF;

        IF v_instance_item IS DISTINCT FROM NEW.target_catalog_item_id THEN
            RAISE EXCEPTION
                'Build-goal instance does not match target_catalog_item_id';
        END IF;
    ELSIF NEW.collection_instance_id IS NOT NULL THEN
        RAISE EXCEPTION
            'BUILD_FROM_INVENTORY may not specify collection_instance_id';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_build_goal
BEFORE INSERT OR UPDATE OF
    owner_id,
    build_goal_type,
    target_catalog_item_id,
    inventory_version_id,
    collection_instance_id
ON wanted.build_goals
FOR EACH ROW
EXECUTE FUNCTION wanted.validate_build_goal();


CREATE FUNCTION wanted.validate_build_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_goal_owner uuid;
    v_goal_version uuid;
    v_include_family boolean;
    v_entry_owner uuid;
    v_entry_status collection.entry_status;
    v_entry_quantity numeric;
    v_group_version uuid;
    v_allocated numeric;
    v_goal_user uuid;
    v_entry_family uuid;
BEGIN
    SELECT
        owner_id,
        inventory_version_id,
        include_family_inventory
    INTO
        v_goal_owner,
        v_goal_version,
        v_include_family
    FROM wanted.build_goals
    WHERE build_goal_id = NEW.build_goal_id;

    /* Serialize allocations competing for the same physical quantity. */
    SELECT
        owner_id,
        status,
        quantity
    INTO
        v_entry_owner,
        v_entry_status,
        v_entry_quantity
    FROM collection.entries
    WHERE collection_entry_id = NEW.collection_entry_id
    FOR UPDATE;

    IF v_entry_status IS DISTINCT FROM 'ACTIVE' THEN
        RAISE EXCEPTION
            'Build allocations require an ACTIVE collection entry';
    END IF;

    IF v_entry_owner IS DISTINCT FROM v_goal_owner THEN
        IF NOT v_include_family THEN
            RAISE EXCEPTION
                'Build allocation crosses owners while family inventory is disabled';
        END IF;

        SELECT user_id
        INTO v_goal_user
        FROM identity.owners
        WHERE owner_id = v_goal_owner
          AND owner_type = 'USER';

        SELECT family_id
        INTO v_entry_family
        FROM identity.owners
        WHERE owner_id = v_entry_owner
          AND owner_type = 'FAMILY';

        IF v_goal_user IS NULL
           OR v_entry_family IS NULL
           OR NOT EXISTS (
               SELECT 1
               FROM identity.family_memberships fm
               WHERE fm.user_id = v_goal_user
                 AND fm.family_id = v_entry_family
                 AND fm.membership_status = 'ACTIVE'
           )
        THEN
            RAISE EXCEPTION
                'Build allocation may use only the goal owner or that user''s active family inventory';
        END IF;
    END IF;

    IF NEW.requirement_group_id IS NOT NULL THEN
        SELECT inventory_version_id
        INTO v_group_version
        FROM definition.requirement_groups
        WHERE requirement_group_id = NEW.requirement_group_id;

        IF v_group_version IS DISTINCT FROM v_goal_version THEN
            RAISE EXCEPTION
                'Build allocation requirement group does not belong to the build-goal inventory version';
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM definition.requirement_options ro
            JOIN collection.entries e
              ON e.collection_entry_id = NEW.collection_entry_id
            WHERE ro.requirement_group_id = NEW.requirement_group_id
              AND (
                  (
                      e.catalog_item_id IS NOT NULL
                      AND ro.catalog_item_id = e.catalog_item_id
                  )
                  OR
                  (
                      e.part_variant_id IS NOT NULL
                      AND ro.part_variant_id = e.part_variant_id
                  )
              )
        ) THEN
            RAISE EXCEPTION
                'Allocated collection entry is not an option for the requirement group';
        END IF;
    END IF;

    IF NEW.released_at IS NULL THEN
        SELECT coalesce(sum(a.quantity), 0)
        INTO v_allocated
        FROM wanted.build_allocations a
        WHERE a.collection_entry_id = NEW.collection_entry_id
          AND a.released_at IS NULL
          AND a.build_allocation_id IS DISTINCT FROM
              NEW.build_allocation_id;

        IF v_allocated + NEW.quantity > v_entry_quantity THEN
            RAISE EXCEPTION
                'Active build allocations would exceed owned collection quantity';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_build_allocation
BEFORE INSERT OR UPDATE
ON wanted.build_allocations
FOR EACH ROW
EXECUTE FUNCTION wanted.validate_build_allocation();


/* ==========================================================================
 * MOC integrity
 * ========================================================================== */

CREATE FUNCTION moc.validate_revision_integrity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_parent_moc uuid;
    v_parent_number integer;
    v_moc_item uuid;
    v_version_item uuid;
BEGIN
    IF NEW.parent_revision_id IS NOT NULL THEN
        SELECT
            moc_id,
            revision_number
        INTO
            v_parent_moc,
            v_parent_number
        FROM moc.revisions
        WHERE moc_revision_id = NEW.parent_revision_id;

        IF v_parent_moc IS DISTINCT FROM NEW.moc_id THEN
            RAISE EXCEPTION
                'Parent revision must belong to the same MOC';
        END IF;

        IF v_parent_number >= NEW.revision_number THEN
            RAISE EXCEPTION
                'Parent revision number must be lower than child revision number';
        END IF;
    END IF;

    IF NEW.inventory_version_id IS NOT NULL THEN
        SELECT catalog_item_id
        INTO v_moc_item
        FROM moc.mocs
        WHERE moc_id = NEW.moc_id;

        SELECT d.catalog_item_id
        INTO v_version_item
        FROM definition.inventory_versions v
        JOIN definition.inventory_definitions d
          ON d.inventory_definition_id = v.inventory_definition_id
        WHERE v.inventory_version_id = NEW.inventory_version_id;

        IF v_version_item IS DISTINCT FROM v_moc_item THEN
            RAISE EXCEPTION
                'MOC revision inventory version does not describe the MOC catalog item';
        END IF;
    END IF;

    IF NEW.status = 'DRAFT'
       AND NEW.published_at IS NOT NULL
    THEN
        RAISE EXCEPTION
            'Draft MOC revision may not have published_at';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_moc_revision_integrity
BEFORE INSERT OR UPDATE OF
    moc_id,
    revision_number,
    parent_revision_id,
    inventory_version_id,
    status,
    published_at
ON moc.revisions
FOR EACH ROW
EXECUTE FUNCTION moc.validate_revision_integrity();


/* ==========================================================================
 * Import integrity
 * ========================================================================== */

CREATE FUNCTION import.validate_normalized_record_job()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_raw_job uuid;
BEGIN
    IF NEW.raw_record_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT import_job_id
    INTO v_raw_job
    FROM import.raw_records
    WHERE raw_record_id = NEW.raw_record_id;

    IF v_raw_job IS DISTINCT FROM NEW.import_job_id THEN
        RAISE EXCEPTION
            'Normalized record raw_record_id belongs to another import job';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_normalized_record_job
BEFORE INSERT OR UPDATE OF
    import_job_id,
    raw_record_id
ON import.normalized_records
FOR EACH ROW
EXECUTE FUNCTION import.validate_normalized_record_job();


CREATE FUNCTION import.validate_application_actor()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_owner uuid;
BEGIN
    SELECT owner_id
    INTO v_owner
    FROM import.jobs
    WHERE import_job_id = NEW.import_job_id;

    IF NOT identity.can_manage_owner(
        NEW.applied_by_user_id,
        v_owner,
        'COLLECTION'
    ) THEN
        RAISE EXCEPTION
            'Import application actor is not authorized for the import owner';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_import_application_actor
BEFORE INSERT OR UPDATE OF
    import_job_id,
    applied_by_user_id
ON import.applications
FOR EACH ROW
EXECUTE FUNCTION import.validate_application_actor();


/* ==========================================================================
 * Supporting indexes
 * ========================================================================== */

CREATE INDEX ix_acquisitions_owner
    ON collection.acquisitions(owner_id);

CREATE INDEX ix_acquisition_items_instance
    ON collection.acquisition_items(collection_instance_id)
    WHERE collection_instance_id IS NOT NULL;

CREATE INDEX ix_collection_transfers_from_owner_time
    ON collection.transfers(from_owner_id, transferred_at DESC);

CREATE INDEX ix_collection_transfers_to_owner_time
    ON collection.transfers(to_owner_id, transferred_at DESC);

CREATE INDEX ix_wishlist_entries_catalog_item
    ON wanted.wishlist_entries(catalog_item_id)
    WHERE catalog_item_id IS NOT NULL;

CREATE INDEX ix_wishlist_reservations_user_active
    ON wanted.wishlist_reservations(
        reserved_by_user_id,
        reserved_at DESC
    )
    WHERE released_at IS NULL;

CREATE INDEX ix_moc_revisions_parent
    ON moc.revisions(parent_revision_id)
    WHERE parent_revision_id IS NOT NULL;

CREATE INDEX ix_import_jobs_source
    ON import.jobs(source_id);

CREATE INDEX ix_catalog_parts_superseded_by
    ON catalog.parts(superseded_by_catalog_item_id)
    WHERE superseded_by_catalog_item_id IS NOT NULL;

CREATE INDEX ix_audit_events_owner_time
    ON audit.events(owner_id, occurred_at DESC)
    WHERE owner_id IS NOT NULL;

CREATE INDEX ix_import_application_changes_entity
    ON import.application_changes(
        entity_schema,
        entity_table,
        entity_id
    );

CREATE UNIQUE INDEX uq_moc_assets_storage_key
    ON moc.assets(storage_key);

\echo '[PASS] 1009_integrity_hardening.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5700_system/5708_system_integrity_hardening.sql');
