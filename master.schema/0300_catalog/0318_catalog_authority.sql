/*
===============================================================================
 File:           0300_catalog/0318_catalog_authority.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Preserve authoritative source scalar state/history and
                 independent administrator overrides.
 Depends On:     catalog.items
                 reference.external_sources
                 identity.users
 Creates:        catalog.source_values
                 catalog.source_value_history
                 catalog.admin_overrides
 Key Rules:      Unchanged source observations refresh provenance/last_seen but
                 do not create history rows.
                 Source changes create explicit old/new history.
                 Active admin overrides survive later source updates and take
                 effective precedence.
                 source_run foreign keys are added after import.source_runs exists.
 Validation:     Enforces field-name validity, change-only history rows,
                 observation chronology and one active override per field/item.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0300_catalog/0318_catalog_authority.sql', ARRAY['catalog.items', 'reference.external_sources', 'identity.users']::text[]);



CREATE TABLE catalog.source_values (
    catalog_item_id uuid NOT NULL,
    source_id smallint NOT NULL,
    field_name text NOT NULL,

    source_value jsonb NOT NULL,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),

    last_source_run_id uuid,

    CONSTRAINT pk_catalog_source_values
        PRIMARY KEY (
            catalog_item_id,
            source_id,
            field_name
        ),

    CONSTRAINT fk_catalog_source_values_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_catalog_source_values_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT ck_catalog_source_values_field
        CHECK (btrim(field_name) <> ''),

    CONSTRAINT ck_catalog_source_values_seen
        CHECK (last_seen_at >= first_seen_at)
);

CREATE TABLE catalog.source_value_history (
    source_value_history_id bigint GENERATED ALWAYS AS IDENTITY,

    catalog_item_id uuid NOT NULL,
    source_id smallint NOT NULL,
    field_name text NOT NULL,

    old_value jsonb,
    new_value jsonb NOT NULL,

    source_run_id uuid,

    changed_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_catalog_source_value_history
        PRIMARY KEY (source_value_history_id),

    CONSTRAINT fk_catalog_source_value_history_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_catalog_source_value_history_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT ck_catalog_source_value_history_field
        CHECK (btrim(field_name) <> ''),

    CONSTRAINT ck_catalog_source_value_history_change
        CHECK (
            old_value IS DISTINCT FROM new_value
        )
);

CREATE INDEX ix_catalog_source_value_history_item
    ON catalog.source_value_history(
        catalog_item_id,
        changed_at DESC
    );


CREATE TABLE catalog.admin_overrides (
    admin_override_id uuid NOT NULL DEFAULT app.uuid_v7(),

    catalog_item_id uuid NOT NULL,

    field_name text NOT NULL,
    override_value jsonb NOT NULL,
    reason text NOT NULL,

    created_by_user_id uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),

    cleared_at timestamptz,
    cleared_by_user_id uuid,

    CONSTRAINT pk_catalog_admin_overrides
        PRIMARY KEY (admin_override_id),

    CONSTRAINT fk_catalog_admin_overrides_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_catalog_admin_overrides_created_by
        FOREIGN KEY (created_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_catalog_admin_overrides_cleared_by
        FOREIGN KEY (cleared_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_catalog_admin_overrides_field
        CHECK (btrim(field_name) <> ''),

    CONSTRAINT ck_catalog_admin_overrides_reason
        CHECK (btrim(reason) <> ''),

    CONSTRAINT ck_catalog_admin_overrides_clear
        CHECK (
            (
                cleared_at IS NULL
                AND cleared_by_user_id IS NULL
            )
            OR
            (
                cleared_at IS NOT NULL
                AND cleared_by_user_id IS NOT NULL
                AND cleared_at >= created_at
            )
        )
);

CREATE UNIQUE INDEX uq_active_catalog_admin_override
    ON catalog.admin_overrides(
        catalog_item_id,
        field_name
    )
    WHERE cleared_at IS NULL;

SELECT app.assert_table_exists('catalog', 'source_values');
SELECT app.assert_table_exists('catalog', 'source_value_history');
SELECT app.assert_table_exists('catalog', 'admin_overrides');

\echo '[PASS] 0318_catalog_authority.sql'
SELECT pg_temp.bt_mark_completed('0300_catalog/0318_catalog_authority.sql');
