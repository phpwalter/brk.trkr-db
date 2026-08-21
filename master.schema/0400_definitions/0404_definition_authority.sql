/*
===============================================================================
 File:           0400_definitions/0404_definition_authority.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Select current source and administrator-corrected semantic
                 inventory versions.
 Depends On:     definition.inventory_definitions
                 definition.inventory_versions
 Creates:        definition.definition_authority
 Key Rules:      active_admin_version_id takes precedence over the latest source
                 version.
                 Authority pointers must reference versions belonging to the same
                 inventory definition.
                 Admin authority must reference an admin-correction version.
 Validation:     Runtime trigger validates same-definition and admin-correction
                 requirements.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0400_definitions/0404_definition_authority.sql', ARRAY['definition.inventory_definitions', 'definition.inventory_versions']::text[]);



CREATE TABLE definition.definition_authority (
    inventory_definition_id uuid NOT NULL,

    latest_source_version_id uuid,
    active_admin_version_id uuid,

    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_definition_authority
        PRIMARY KEY (inventory_definition_id),

    CONSTRAINT fk_definition_authority_definition
        FOREIGN KEY (inventory_definition_id)
        REFERENCES definition.inventory_definitions(
            inventory_definition_id
        ),

    CONSTRAINT fk_definition_authority_source
        FOREIGN KEY (latest_source_version_id)
        REFERENCES definition.inventory_versions(
            inventory_version_id
        ),

    CONSTRAINT fk_definition_authority_admin
        FOREIGN KEY (active_admin_version_id)
        REFERENCES definition.inventory_versions(
            inventory_version_id
        )
);

SELECT app.assert_table_exists(
    'definition',
    'definition_authority'
);

\echo '[PASS] 0404_definition_authority.sql'
SELECT pg_temp.bt_mark_completed('0400_definitions/0404_definition_authority.sql');
