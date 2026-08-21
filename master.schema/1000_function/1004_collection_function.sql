/*
===============================================================================
 File:           1000_function/1004_collection_function.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Enforce collection owner consistency and expose explicit loose
                 part ownership/allocation balances.
 Depends On:     collection.entries
                 collection.instances
                 collection.storage_locations
                 collection.storage_allocations
                 wanted.build_allocations
 Creates:        collection.validate_storage_allocation()
                 collection.explicit_part_balance()
                 trg_validate_storage_allocation
 Key Rules:      Storage allocation may never cross owners.
                 Instance-specific storage allocations must reference an instance
                 belonging to the same entry.
                 Owned, allocated and available quantities remain separate.
 Validation:     Runtime trigger enforces storage owner/instance consistency;
                 balance function computes non-negative available quantity.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1000_function/1004_collection_function.sql', ARRAY['collection.entries', 'collection.instances', 'collection.storage_locations', 'collection.storage_allocations', 'wanted.build_allocations']::text[]);



CREATE FUNCTION collection.validate_storage_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_entry_owner uuid;
    v_storage_owner uuid;
    v_instance_entry uuid;
BEGIN
    SELECT owner_id
    INTO v_entry_owner
    FROM collection.entries
    WHERE collection_entry_id =
          NEW.collection_entry_id;

    SELECT owner_id
    INTO v_storage_owner
    FROM collection.storage_locations
    WHERE storage_location_id =
          NEW.storage_location_id;

    IF v_entry_owner IS DISTINCT FROM
       v_storage_owner
    THEN
        RAISE EXCEPTION
            'Storage allocation crosses owners';
    END IF;

    IF NEW.collection_instance_id IS NOT NULL THEN
        SELECT collection_entry_id
        INTO v_instance_entry
        FROM collection.instances
        WHERE collection_instance_id =
              NEW.collection_instance_id;

        IF v_instance_entry IS DISTINCT FROM
           NEW.collection_entry_id
        THEN
            RAISE EXCEPTION
                'Collection instance does not belong to the allocated entry';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_storage_allocation
BEFORE INSERT OR UPDATE
ON collection.storage_allocations
FOR EACH ROW
EXECUTE FUNCTION collection.validate_storage_allocation();


CREATE FUNCTION collection.explicit_part_balance(
    p_owner_id uuid,
    p_part_variant_id uuid
)
RETURNS TABLE (
    owned_quantity numeric,
    allocated_quantity numeric,
    available_quantity numeric
)
LANGUAGE sql
STABLE
AS $$
    WITH owned AS (
        SELECT
            coalesce(sum(e.quantity), 0)::numeric AS qty
        FROM collection.entries e
        WHERE e.owner_id = p_owner_id
          AND e.part_variant_id = p_part_variant_id
          AND e.status = 'ACTIVE'
    ),
    allocated AS (
        SELECT
            coalesce(sum(a.quantity), 0)::numeric AS qty
        FROM wanted.build_allocations a
        JOIN collection.entries e
          ON e.collection_entry_id =
             a.collection_entry_id
        WHERE e.owner_id = p_owner_id
          AND e.part_variant_id = p_part_variant_id
          AND e.status = 'ACTIVE'
          AND a.released_at IS NULL
    )
    SELECT
        o.qty,
        a.qty,
        greatest(
            o.qty - a.qty,
            0
        )
    FROM owned o
    CROSS JOIN allocated a;
$$;

\echo '[PASS] 1004_collection_function.sql'
SELECT pg_temp.bt_mark_completed('1000_function/1004_collection_function.sql');
