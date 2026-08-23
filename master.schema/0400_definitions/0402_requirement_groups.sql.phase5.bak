/*
===============================================================================
 File:           0400_definitions/0402_requirement_groups.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Define logical requirement groups within one inventory version.
 Depends On:     definition.inventory_versions
 Creates:        definition.fulfillment_rule
                 definition.requirement_groups
 Key Rules:      Optional requirements are explicit and never represented using
                 quantity zero.
                 Spares are explicit and separate from build-required quantity.
                 Alternative fulfillment supports ANY, ALL and AT_LEAST_N.
 Validation:     Enforces valid AT_LEAST_N configuration, positive quantities and
                 non-negative optional sort order.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0400_definitions/0402_requirement_groups.sql', ARRAY['definition.inventory_versions']::text[]);



CREATE TYPE definition.fulfillment_rule AS ENUM (
    'ANY',
    'ALL',
    'AT_LEAST_N'
);

CREATE TABLE definition.requirement_groups (
    requirement_group_id bigint GENERATED ALWAYS AS IDENTITY,

    inventory_version_id uuid NOT NULL,

    required_quantity app.whole_quantity NOT NULL,

    fulfillment_rule definition.fulfillment_rule
        NOT NULL DEFAULT 'ANY',

    minimum_options smallint,

    is_required boolean NOT NULL DEFAULT true,
    is_spare boolean NOT NULL DEFAULT false,

    sort_order integer,
    notes text,

    CONSTRAINT pk_requirement_groups
        PRIMARY KEY (requirement_group_id),

    CONSTRAINT fk_requirement_groups_version
        FOREIGN KEY (inventory_version_id)
        REFERENCES definition.inventory_versions(
            inventory_version_id
        )
        ON DELETE CASCADE,

    CONSTRAINT ck_requirement_groups_minimum
        CHECK (
            (
                fulfillment_rule = 'AT_LEAST_N'
                AND minimum_options IS NOT NULL
                AND minimum_options > 0
            )
            OR
            (
                fulfillment_rule <> 'AT_LEAST_N'
                AND minimum_options IS NULL
            )
        ),

    CONSTRAINT ck_requirement_groups_sort
        CHECK (
            sort_order IS NULL
            OR sort_order >= 0
        )
);

CREATE INDEX ix_requirement_groups_version
    ON definition.requirement_groups(
        inventory_version_id,
        sort_order
    );

SELECT app.assert_table_exists(
    'definition',
    'requirement_groups'
);

\echo '[PASS] 0402_requirement_groups.sql'
SELECT pg_temp.bt_mark_completed('0400_definitions/0402_requirement_groups.sql');
