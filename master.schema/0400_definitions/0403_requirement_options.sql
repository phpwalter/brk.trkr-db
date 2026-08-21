/*
===============================================================================
 File:           0400_definitions/0403_requirement_options.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define acceptable target options for logical requirements.
 Depends On:     definition.requirement_groups
                 catalog.items
                 catalog.part_variants
                 reference.minifig_roles
 Creates:        definition.requirement_options
 Key Rules:      Every option targets exactly one catalog item or part variant.
                 A group may have at most one primary/reference option.
                 Minifigure anatomy is represented using extensible role/side/
                 position metadata.
 Validation:     Enforces target exclusivity, role references, valid side values,
                 positive position indexes and one primary option per group.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0400_definitions/0403_requirement_options.sql', ARRAY['definition.requirement_groups', 'catalog.items', 'catalog.part_variants', 'reference.minifig_roles']::text[]);



CREATE TABLE definition.requirement_options (
    requirement_option_id bigint GENERATED ALWAYS AS IDENTITY,

    requirement_group_id bigint NOT NULL,

    catalog_item_id uuid,
    part_variant_id uuid,

    option_quantity app.whole_quantity NOT NULL DEFAULT 1,
    is_primary boolean NOT NULL DEFAULT false,

    minifig_role_id integer,
    side text,
    position_index smallint,

    notes text,

    CONSTRAINT pk_requirement_options
        PRIMARY KEY (requirement_option_id),

    CONSTRAINT fk_requirement_options_group
        FOREIGN KEY (requirement_group_id)
        REFERENCES definition.requirement_groups(
            requirement_group_id
        )
        ON DELETE CASCADE,

    CONSTRAINT fk_requirement_options_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_requirement_options_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT fk_requirement_options_role
        FOREIGN KEY (minifig_role_id)
        REFERENCES reference.minifig_roles(minifig_role_id),

    CONSTRAINT ck_requirement_options_target
        CHECK (
            num_nonnulls(
                catalog_item_id,
                part_variant_id
            ) = 1
        ),

    CONSTRAINT ck_requirement_options_position
        CHECK (
            position_index IS NULL
            OR position_index > 0
        ),

    CONSTRAINT ck_requirement_options_side
        CHECK (
            side IS NULL
            OR side IN (
                'LEFT',
                'RIGHT',
                'CENTER',
                'NONE'
            )
        )
);

CREATE UNIQUE INDEX uq_primary_requirement_option
    ON definition.requirement_options(requirement_group_id)
    WHERE is_primary;

CREATE INDEX ix_requirement_options_group
    ON definition.requirement_options(requirement_group_id);

CREATE INDEX ix_requirement_options_item
    ON definition.requirement_options(catalog_item_id)
    WHERE catalog_item_id IS NOT NULL;

CREATE INDEX ix_requirement_options_variant
    ON definition.requirement_options(part_variant_id)
    WHERE part_variant_id IS NOT NULL;

SELECT app.assert_table_exists(
    'definition',
    'requirement_options'
);

SELECT app.assert_index_exists(
    'definition',
    'uq_primary_requirement_option'
);

\echo '[PASS] 0403_requirement_options.sql'
SELECT pg_temp.bt_mark_completed('0400_definitions/0403_requirement_options.sql');
