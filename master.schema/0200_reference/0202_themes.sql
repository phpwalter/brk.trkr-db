/*
===============================================================================
 File:           0200_reference/0202_themes.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define canonical hierarchical themes and external theme mappings.
 Depends On:     reference.external_sources
 Creates:        reference.themes
                 reference.external_theme_mappings
 Key Rules:      Theme hierarchy is canonical and independent of source IDs.
                 Retired themes remain queryable.
                 Recursive cycles are prohibited by runtime hierarchy logic.
 Validation:     Prevents direct self-parenting, duplicate sibling names and
                 invalid source observation chronology.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0200_reference/0202_themes.sql', ARRAY['reference.external_sources']::text[]);



CREATE TABLE reference.themes (
    theme_id integer GENERATED ALWAYS AS IDENTITY,

    parent_theme_id integer,
    theme_name text NOT NULL,

    is_retired boolean NOT NULL DEFAULT false,

    CONSTRAINT pk_themes
        PRIMARY KEY (theme_id),

    CONSTRAINT fk_themes_parent
        FOREIGN KEY (parent_theme_id)
        REFERENCES reference.themes(theme_id),

    CONSTRAINT ck_themes_name
        CHECK (btrim(theme_name) <> ''),

    CONSTRAINT ck_themes_not_self
        CHECK (
            parent_theme_id IS NULL
            OR parent_theme_id <> theme_id
        )
);

CREATE UNIQUE INDEX uq_themes_root_name
    ON reference.themes(theme_name)
    WHERE parent_theme_id IS NULL;

CREATE UNIQUE INDEX uq_themes_child_name
    ON reference.themes(
        parent_theme_id,
        theme_name
    )
    WHERE parent_theme_id IS NOT NULL;

CREATE INDEX ix_themes_parent
    ON reference.themes(parent_theme_id);


CREATE TABLE reference.external_theme_mappings (
    external_theme_mapping_id bigint GENERATED ALWAYS AS IDENTITY,

    source_id smallint NOT NULL,
    external_theme_id text NOT NULL,
    external_theme_name text,

    theme_id integer NOT NULL,

    source_present boolean NOT NULL DEFAULT true,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_external_theme_mappings
        PRIMARY KEY (external_theme_mapping_id),

    CONSTRAINT fk_external_theme_mappings_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT fk_external_theme_mappings_theme
        FOREIGN KEY (theme_id)
        REFERENCES reference.themes(theme_id),

    CONSTRAINT uq_external_theme_mapping
        UNIQUE (source_id, external_theme_id),

    CONSTRAINT ck_external_theme_mapping_id
        CHECK (btrim(external_theme_id) <> ''),

    CONSTRAINT ck_external_theme_mapping_seen
        CHECK (last_seen_at >= first_seen_at)
);

CREATE INDEX ix_external_theme_mappings_theme
    ON reference.external_theme_mappings(theme_id);

SELECT app.assert_table_exists('reference', 'themes');
SELECT app.assert_table_exists('reference', 'external_theme_mappings');

\echo '[PASS] 0202_themes.sql'
SELECT pg_temp.bt_mark_completed('0200_reference/0202_themes.sql');
