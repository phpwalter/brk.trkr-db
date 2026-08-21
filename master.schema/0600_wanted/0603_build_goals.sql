/*
===============================================================================
 File:           0600_wanted/0603_build_goals.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Track build-from-inventory and complete-owned-instance goals.
 Depends On:     identity.owners
                 catalog.items
                 definition.inventory_versions
                 collection.instances
 Creates:        wanted.build_goal_type
                 wanted.build_goal_status
                 wanted.minifig_matching_mode
                 wanted.build_goals
 Key Rules:      A goal references an exact semantic inventory version.
                 Goal tracking does not itself reserve inventory.
                 Reservations are represented by build allocations.
                 Minifigure matching mode explicitly controls component matching.
 Validation:     Completion-instance goals require an owned instance and completed
                 goals require completed_at.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0600_wanted/0603_build_goals.sql', ARRAY['identity.owners', 'catalog.items', 'definition.inventory_versions', 'collection.instances']::text[]);



CREATE TYPE wanted.build_goal_type AS ENUM (
    'BUILD_FROM_INVENTORY',
    'COMPLETE_OWNED_INSTANCE'
);

CREATE TYPE wanted.build_goal_status AS ENUM (
    'PLANNED',
    'RESERVING',
    'IN_PROGRESS',
    'COMPLETE',
    'ARCHIVED'
);

CREATE TYPE wanted.minifig_matching_mode AS ENUM (
    'COMPLETE_ONLY',
    'COMPONENTS_ALLOWED'
);

CREATE TABLE wanted.build_goals (
    build_goal_id uuid NOT NULL DEFAULT app.uuid_v7(),

    owner_id uuid NOT NULL,

    build_goal_type wanted.build_goal_type NOT NULL,

    target_catalog_item_id uuid NOT NULL,
    inventory_version_id uuid NOT NULL,

    collection_instance_id uuid,

    target_quantity app.quantity NOT NULL DEFAULT 1,

    status wanted.build_goal_status
        NOT NULL DEFAULT 'PLANNED',

    include_family_inventory boolean NOT NULL DEFAULT true,
    include_contained_parts boolean NOT NULL DEFAULT true,
    include_allocated_parts boolean NOT NULL DEFAULT false,

    minifig_matching_mode wanted.minifig_matching_mode
        NOT NULL DEFAULT 'COMPLETE_ONLY',

    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,

    CONSTRAINT pk_build_goals
        PRIMARY KEY (build_goal_id),

    CONSTRAINT fk_build_goals_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT fk_build_goals_target
        FOREIGN KEY (target_catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_build_goals_version
        FOREIGN KEY (inventory_version_id)
        REFERENCES definition.inventory_versions(
            inventory_version_id
        ),

    CONSTRAINT fk_build_goals_instance
        FOREIGN KEY (collection_instance_id)
        REFERENCES collection.instances(
            collection_instance_id
        ),

    CONSTRAINT ck_build_goals_instance
        CHECK (
            build_goal_type <> 'COMPLETE_OWNED_INSTANCE'
            OR collection_instance_id IS NOT NULL
        ),

    CONSTRAINT ck_build_goals_complete
        CHECK (
            status <> 'COMPLETE'
            OR completed_at IS NOT NULL
        )
);

CREATE INDEX ix_build_goals_owner_status
    ON wanted.build_goals(
        owner_id,
        status
    );

SELECT app.assert_table_exists(
    'wanted',
    'build_goals'
);

\echo '[PASS] 0603_build_goals.sql'
SELECT pg_temp.bt_mark_completed('0600_wanted/0603_build_goals.sql');
