
/*
===============================================================================
 File:           0600_wanted/0604_build_allocations.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Reserve owned collection quantities against build goals.
 Depends On:     wanted.build_goals
                 collection.entries
                 definition.requirement_groups
 Creates:        wanted.build_allocations
 Key Rules:      Owned, allocated and available quantities are distinct.
                 Tracking a build goal does not automatically create allocations.
                 Released allocations remain historical records.
 Validation:     Enforces positive quantities, valid goal/entry/requirement
                 references and valid release chronology.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0600_wanted/0604_build_allocations.sql', ARRAY['wanted.build_goals', 'collection.entries', 'definition.requirement_groups']::text[]);



CREATE TABLE wanted.build_allocations (
    build_allocation_id bigint GENERATED ALWAYS AS IDENTITY,

    build_goal_id uuid NOT NULL,
    collection_entry_id uuid NOT NULL,

    requirement_group_id bigint,

    quantity app.quantity NOT NULL,

    allocated_at timestamptz NOT NULL DEFAULT now(),
    released_at timestamptz,

    CONSTRAINT pk_build_allocations
        PRIMARY KEY (build_allocation_id),

    CONSTRAINT fk_build_allocations_goal
        FOREIGN KEY (build_goal_id)
        REFERENCES wanted.build_goals(build_goal_id)
        ON DELETE CASCADE,

    CONSTRAINT fk_build_allocations_entry
        FOREIGN KEY (collection_entry_id)
        REFERENCES collection.entries(collection_entry_id),

    CONSTRAINT fk_build_allocations_requirement
        FOREIGN KEY (requirement_group_id)
        REFERENCES definition.requirement_groups(
            requirement_group_id
        ),

    CONSTRAINT ck_build_allocations_release
        CHECK (
            released_at IS NULL
            OR released_at >= allocated_at
        )
);

CREATE INDEX ix_build_allocations_goal_active
    ON wanted.build_allocations(build_goal_id)
    WHERE released_at IS NULL;

CREATE INDEX ix_build_allocations_entry_active
    ON wanted.build_allocations(collection_entry_id)
    WHERE released_at IS NULL;

SELECT app.assert_table_exists(
    'wanted',
    'build_allocations'
);

\echo '[PASS] 0604_build_allocations.sql'
SELECT pg_temp.bt_mark_completed('0600_wanted/0604_build_allocations.sql');
