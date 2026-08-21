/*
===============================================================================
 File:           0500_collections/0504_storage_allocations.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Place owned quantities or physical instances into storage
                 locations.
 Depends On:     collection.entries
                 collection.instances
                 collection.storage_locations
 Creates:        collection.storage_allocations
 Key Rules:      Storage locations and collection entries must share an owner.
                 An instance-specific allocation must reference an instance that
                 belongs to the same collection entry.
                 Quantities may be split across multiple storage locations.
 Validation:     Runtime trigger enforces owner and entry/instance consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0500_collections/0504_storage_allocations.sql', ARRAY['collection.entries', 'collection.instances', 'collection.storage_locations']::text[]);



CREATE TABLE collection.storage_allocations (
    storage_allocation_id bigint GENERATED ALWAYS AS IDENTITY,

    collection_entry_id uuid NOT NULL,
    collection_instance_id uuid,
    storage_location_id uuid NOT NULL,

    quantity app.quantity NOT NULL,

    CONSTRAINT pk_storage_allocations
        PRIMARY KEY (storage_allocation_id),

    CONSTRAINT fk_storage_allocations_entry
        FOREIGN KEY (collection_entry_id)
        REFERENCES collection.entries(collection_entry_id),

    CONSTRAINT fk_storage_allocations_instance
        FOREIGN KEY (collection_instance_id)
        REFERENCES collection.instances(collection_instance_id),

    CONSTRAINT fk_storage_allocations_location
        FOREIGN KEY (storage_location_id)
        REFERENCES collection.storage_locations(
            storage_location_id
        )
);

CREATE INDEX ix_storage_allocations_entry
    ON collection.storage_allocations(collection_entry_id);

CREATE INDEX ix_storage_allocations_instance
    ON collection.storage_allocations(collection_instance_id)
    WHERE collection_instance_id IS NOT NULL;

CREATE INDEX ix_storage_allocations_location
    ON collection.storage_allocations(storage_location_id);

SELECT app.assert_table_exists(
    'collection',
    'storage_allocations'
);

\echo '[PASS] 0504_storage_allocations.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0504_storage_allocations.sql');
