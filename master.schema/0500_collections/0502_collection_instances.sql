/*
===============================================================================
 File:           0500_collections/0502_collection_instances.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store individual physical copies and their version/condition
                 state.
 Depends On:     collection.entries
                 definition.inventory_versions
 Creates:        collection.item_condition
                 collection.package_condition
                 collection.assembly_state
                 collection.completeness_state
                 collection.instances
 Key Rules:      Exact expected inventory version may be NULL when unknown.
                 A physical copy references its expected version rather than
                 copying the full manifest.
                 Parted-out/built/completeness state remains instance-specific.
 Validation:     Foreign keys enforce valid entry/version references and enums
                 constrain supported condition states.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0500_collections/0502_collection_instances.sql', ARRAY['collection.entries', 'definition.inventory_versions']::text[]);



CREATE TYPE collection.item_condition AS ENUM (
    'NEW',
    'USED',
    'DAMAGED',
    'UNKNOWN'
);

CREATE TYPE collection.package_condition AS ENUM (
    'SEALED',
    'OPENED',
    'NO_BOX',
    'UNKNOWN'
);

CREATE TYPE collection.assembly_state AS ENUM (
    'UNBUILT',
    'BUILT',
    'PARTIALLY_BUILT',
    'PARTED_OUT',
    'NOT_APPLICABLE'
);

CREATE TYPE collection.completeness_state AS ENUM (
    'COMPLETE',
    'INCOMPLETE',
    'UNKNOWN'
);

CREATE TABLE collection.instances (
    collection_instance_id uuid NOT NULL DEFAULT app.uuid_v7(),

    collection_entry_id uuid NOT NULL,

    inventory_version_id uuid,

    item_condition collection.item_condition
        NOT NULL DEFAULT 'UNKNOWN',

    package_condition collection.package_condition
        NOT NULL DEFAULT 'UNKNOWN',

    assembly_state collection.assembly_state
        NOT NULL DEFAULT 'NOT_APPLICABLE',

    completeness_state collection.completeness_state
        NOT NULL DEFAULT 'UNKNOWN',

    notes text,

    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,

    CONSTRAINT pk_collection_instances
        PRIMARY KEY (collection_instance_id),

    CONSTRAINT fk_collection_instances_entry
        FOREIGN KEY (collection_entry_id)
        REFERENCES collection.entries(collection_entry_id),

    CONSTRAINT fk_collection_instances_version
        FOREIGN KEY (inventory_version_id)
        REFERENCES definition.inventory_versions(
            inventory_version_id
        )
);

CREATE INDEX ix_collection_instances_entry
    ON collection.instances(collection_entry_id);

CREATE INDEX ix_collection_instances_version
    ON collection.instances(inventory_version_id);

SELECT app.assert_table_exists(
    'collection',
    'instances'
);

\echo '[PASS] 0502_collection_instances.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0502_collection_instances.sql');
