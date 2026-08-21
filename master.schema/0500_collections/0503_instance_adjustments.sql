/*
===============================================================================
 File:           0500_collections/0503_instance_adjustments.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Record physical-instance deviations from an expected inventory
                 manifest.
 Depends On:     collection.instances
                 definition.requirement_groups
                 catalog.items
                 catalog.part_variants
 Creates:        collection.adjustment_type
                 collection.instance_adjustments
 Key Rules:      Incomplete instances store deviations, not copied manifests.
                 Missing, extra and substituted quantities are explicit.
                 Substitutions identify both the expected target and replacement.
 Validation:     Enforces target exclusivity and requires a replacement target
                 for SUBSTITUTED adjustments.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0500_collections/0503_instance_adjustments.sql', ARRAY['collection.instances', 'definition.requirement_groups', 'catalog.items', 'catalog.part_variants']::text[]);



CREATE TYPE collection.adjustment_type AS ENUM (
    'MISSING',
    'EXTRA',
    'SUBSTITUTED'
);

CREATE TABLE collection.instance_adjustments (
    instance_adjustment_id bigint GENERATED ALWAYS AS IDENTITY,

    collection_instance_id uuid NOT NULL,

    adjustment_type collection.adjustment_type NOT NULL,

    expected_requirement_group_id bigint,

    catalog_item_id uuid,
    part_variant_id uuid,

    quantity app.quantity NOT NULL,

    replacement_catalog_item_id uuid,
    replacement_part_variant_id uuid,

    notes text,

    CONSTRAINT pk_instance_adjustments
        PRIMARY KEY (instance_adjustment_id),

    CONSTRAINT fk_instance_adjustments_instance
        FOREIGN KEY (collection_instance_id)
        REFERENCES collection.instances(
            collection_instance_id
        )
        ON DELETE CASCADE,

    CONSTRAINT fk_instance_adjustments_requirement
        FOREIGN KEY (expected_requirement_group_id)
        REFERENCES definition.requirement_groups(
            requirement_group_id
        ),

    CONSTRAINT fk_instance_adjustments_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_instance_adjustments_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT fk_instance_adjustments_replacement_item
        FOREIGN KEY (replacement_catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_instance_adjustments_replacement_variant
        FOREIGN KEY (replacement_part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT ck_instance_adjustments_target
        CHECK (
            num_nonnulls(
                catalog_item_id,
                part_variant_id
            ) = 1
        ),

    CONSTRAINT ck_instance_adjustments_replacement
        CHECK (
            (
                adjustment_type = 'SUBSTITUTED'
                AND num_nonnulls(
                    replacement_catalog_item_id,
                    replacement_part_variant_id
                ) = 1
            )
            OR
            (
                adjustment_type <> 'SUBSTITUTED'
                AND replacement_catalog_item_id IS NULL
                AND replacement_part_variant_id IS NULL
            )
        )
);

CREATE INDEX ix_instance_adjustments_instance
    ON collection.instance_adjustments(
        collection_instance_id
    );

SELECT app.assert_table_exists(
    'collection',
    'instance_adjustments'
);

\echo '[PASS] 0503_instance_adjustments.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0503_instance_adjustments.sql');
