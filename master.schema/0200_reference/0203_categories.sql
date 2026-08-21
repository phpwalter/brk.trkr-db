/*
===============================================================================
 File:           0200_reference/0203_categories.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define extensible hierarchical classification categories and
                 external source category mappings.
 Depends On:     reference.external_sources
 Creates:        reference.categories
                 reference.external_category_mappings
 Key Rules:      Classification categories are distinct from catalog item kinds.
                 category_namespace permits source/domain-specific taxonomies
                 without expanding a database enum for every future category.
                 Recursive hierarchy cycles are prohibited by runtime logic.
 Validation:     Prevents direct self-parenting, duplicate sibling categories and
                 invalid source mapping chronology.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0200_reference/0203_categories.sql', ARRAY['reference.external_sources']::text[]);



CREATE TABLE reference.categories (
    category_id integer GENERATED ALWAYS AS IDENTITY,

    parent_category_id integer,

    category_namespace text NOT NULL,
    category_name text NOT NULL,

    is_retired boolean NOT NULL DEFAULT false,

    CONSTRAINT pk_categories
        PRIMARY KEY (category_id),

    CONSTRAINT fk_categories_parent
        FOREIGN KEY (parent_category_id)
        REFERENCES reference.categories(category_id),

    CONSTRAINT ck_categories_namespace
        CHECK (category_namespace ~ '^[A-Z0-9_]+$'),

    CONSTRAINT ck_categories_name
        CHECK (btrim(category_name) <> ''),

    CONSTRAINT ck_categories_not_self
        CHECK (
            parent_category_id IS NULL
            OR parent_category_id <> category_id
        )
);

CREATE UNIQUE INDEX uq_categories_root
    ON reference.categories(
        category_namespace,
        category_name
    )
    WHERE parent_category_id IS NULL;

CREATE UNIQUE INDEX uq_categories_child
    ON reference.categories(
        category_namespace,
        parent_category_id,
        category_name
    )
    WHERE parent_category_id IS NOT NULL;

CREATE INDEX ix_categories_parent
    ON reference.categories(parent_category_id);


CREATE TABLE reference.external_category_mappings (
    external_category_mapping_id bigint GENERATED ALWAYS AS IDENTITY,

    source_id smallint NOT NULL,
    external_category_id text NOT NULL,
    external_category_name text,

    category_id integer NOT NULL,

    source_present boolean NOT NULL DEFAULT true,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_external_category_mappings
        PRIMARY KEY (external_category_mapping_id),

    CONSTRAINT fk_external_category_mappings_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT fk_external_category_mappings_category
        FOREIGN KEY (category_id)
        REFERENCES reference.categories(category_id),

    CONSTRAINT uq_external_category_mapping
        UNIQUE (source_id, external_category_id),

    CONSTRAINT ck_external_category_mapping_id
        CHECK (btrim(external_category_id) <> ''),

    CONSTRAINT ck_external_category_mapping_seen
        CHECK (last_seen_at >= first_seen_at)
);

CREATE INDEX ix_external_category_mappings_category
    ON reference.external_category_mappings(category_id);

SELECT app.assert_table_exists('reference', 'categories');
SELECT app.assert_table_exists('reference', 'external_category_mappings');

\echo '[PASS] 0203_categories.sql'
SELECT pg_temp.bt_mark_completed('0200_reference/0203_categories.sql');
