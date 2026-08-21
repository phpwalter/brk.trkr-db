/*
===============================================================================
 File:           0500_collections/0500_storage_locations.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define hierarchical owner-scoped physical storage locations.
 Depends On:     identity.owners
 Creates:        collection.storage_locations
 Key Rules:      Storage belongs to exactly one user/family owner.
                 Parent and child storage locations must remain within the same
                 owner.
                 Recursive hierarchy cycles are prohibited by runtime logic.
 Validation:     Prevents direct self-parenting and validates owner consistency
                 through collection runtime functions/domain validation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0500_collections/0500_storage_locations.sql', ARRAY['identity.owners']::text[]);



CREATE TABLE collection.storage_locations (
    storage_location_id uuid NOT NULL DEFAULT app.uuid_v7(),

    owner_id uuid NOT NULL,
    parent_storage_location_id uuid,

    location_name text NOT NULL,
    description text,

    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,

    CONSTRAINT pk_storage_locations
        PRIMARY KEY (storage_location_id),

    CONSTRAINT fk_storage_locations_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT fk_storage_locations_parent
        FOREIGN KEY (parent_storage_location_id)
        REFERENCES collection.storage_locations(
            storage_location_id
        ),

    CONSTRAINT ck_storage_locations_name
        CHECK (btrim(location_name) <> ''),

    CONSTRAINT ck_storage_locations_not_self
        CHECK (
            parent_storage_location_id IS NULL
            OR parent_storage_location_id <> storage_location_id
        )
);

CREATE INDEX ix_storage_locations_owner
    ON collection.storage_locations(owner_id);

CREATE INDEX ix_storage_locations_parent
    ON collection.storage_locations(parent_storage_location_id);

SELECT app.assert_table_exists(
    'collection',
    'storage_locations'
);

\echo '[PASS] 0500_storage_locations.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0500_storage_locations.sql');
