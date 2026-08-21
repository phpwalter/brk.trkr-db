/*
===============================================================================
 File:           0800_imports/0806_user_mapping_suggestions.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Preserve user-local external-ID mapping decisions and optional
                 administrator promotion metadata.
 Depends On:     identity.users
                 reference.external_sources
                 catalog.items
                 catalog.part_variants
 Creates:        import.user_mapping_suggestions
 Key Rules:      User-resolved mappings remain private/local unless promoted.
                 Promotion to global mapping is an explicit administrator action.
                 A suggestion targets exactly one catalog item or part variant.
 Validation:     Enforces namespace/ID validity, target exclusivity and complete
                 promotion metadata.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0800_imports/0806_user_mapping_suggestions.sql', ARRAY['identity.users', 'reference.external_sources', 'catalog.items', 'catalog.part_variants']::text[]);



CREATE TABLE import.user_mapping_suggestions (
    mapping_suggestion_id uuid NOT NULL DEFAULT app.uuid_v7(),

    user_id uuid NOT NULL,
    source_id smallint NOT NULL,

    entity_namespace text NOT NULL,
    external_id text NOT NULL,

    catalog_item_id uuid,
    part_variant_id uuid,

    created_at timestamptz NOT NULL DEFAULT now(),

    promoted_to_global_at timestamptz,
    promoted_by_user_id uuid,

    CONSTRAINT pk_user_mapping_suggestions
        PRIMARY KEY (mapping_suggestion_id),

    CONSTRAINT fk_user_mapping_suggestions_user
        FOREIGN KEY (user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_user_mapping_suggestions_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT fk_user_mapping_suggestions_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_user_mapping_suggestions_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT fk_user_mapping_suggestions_promoted_by
        FOREIGN KEY (promoted_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_user_mapping_suggestions_namespace
        CHECK (
            entity_namespace ~ '^[A-Z0-9_]+$'
        ),

    CONSTRAINT ck_user_mapping_suggestions_external_id
        CHECK (btrim(external_id) <> ''),

    CONSTRAINT ck_user_mapping_suggestions_target
        CHECK (
            num_nonnulls(
                catalog_item_id,
                part_variant_id
            ) = 1
        ),

    CONSTRAINT ck_user_mapping_suggestions_promotion
        CHECK (
            (
                promoted_to_global_at IS NULL
                AND promoted_by_user_id IS NULL
            )
            OR
            (
                promoted_to_global_at IS NOT NULL
                AND promoted_by_user_id IS NOT NULL
            )
        )
);

CREATE INDEX ix_user_mapping_suggestions_lookup
    ON import.user_mapping_suggestions(
        user_id,
        source_id,
        entity_namespace,
        external_id
    );

SELECT app.assert_table_exists(
    'import',
    'user_mapping_suggestions'
);

\echo '[PASS] 0806_user_mapping_suggestions.sql'
SELECT pg_temp.bt_mark_completed('0800_imports/0806_user_mapping_suggestions.sql');
