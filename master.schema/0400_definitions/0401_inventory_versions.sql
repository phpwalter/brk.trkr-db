/*
===============================================================================
 File:           0400_definitions/0401_inventory_versions.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store semantic versions of normalized inventory/composition
                 graphs.
 Depends On:     definition.inventory_definitions
                 reference.external_sources
                 identity.users
 Creates:        definition.inventory_version_status
                 definition.inventory_versions
 Key Rules:      A nightly source observation is not a semantic version.
                 New semantic versions are created only when normalized truth
                 changes.
                 Finalized semantic versions are immutable.
                 Source external version suffixes are distinct from internal
                 semantic_version.
 Validation:     Enforces unique semantic numbers/hashes, finalized fingerprint
                 requirements, valid source-version values and chronology.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0400_definitions/0401_inventory_versions.sql', ARRAY['definition.inventory_definitions', 'reference.external_sources', 'identity.users']::text[]);



CREATE TYPE definition.inventory_version_status AS ENUM (
    'DRAFT',
    'FINALIZED'
);

CREATE TABLE definition.inventory_versions (
    inventory_version_id uuid NOT NULL DEFAULT app.uuid_v7(),

    inventory_definition_id uuid NOT NULL,

    semantic_version integer NOT NULL,
    semantic_hash app.sha256_digest,

    status definition.inventory_version_status
        NOT NULL DEFAULT 'DRAFT',

    source_id smallint,
    source_external_id text,
    source_external_version integer,
    source_run_id uuid,

    is_admin_correction boolean NOT NULL DEFAULT false,
    created_by_user_id uuid,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),

    finalized_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_inventory_versions
        PRIMARY KEY (inventory_version_id),

    CONSTRAINT fk_inventory_versions_definition
        FOREIGN KEY (inventory_definition_id)
        REFERENCES definition.inventory_definitions(
            inventory_definition_id
        ),

    CONSTRAINT fk_inventory_versions_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT fk_inventory_versions_created_by
        FOREIGN KEY (created_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT uq_inventory_versions_number
        UNIQUE (
            inventory_definition_id,
            semantic_version
        ),

    CONSTRAINT ck_inventory_versions_number
        CHECK (semantic_version > 0),

    CONSTRAINT ck_inventory_versions_external_version
        CHECK (
            source_external_version IS NULL
            OR source_external_version > 0
        ),

    CONSTRAINT ck_inventory_versions_seen
        CHECK (
            last_seen_at >= first_seen_at
        ),

    CONSTRAINT ck_inventory_versions_admin_creator
        CHECK (
            NOT is_admin_correction
            OR created_by_user_id IS NOT NULL
        ),

    CONSTRAINT ck_inventory_versions_finalized
        CHECK (
            status <> 'FINALIZED'
            OR (
                semantic_hash IS NOT NULL
                AND finalized_at IS NOT NULL
            )
        )
);

CREATE UNIQUE INDEX uq_inventory_versions_hash
    ON definition.inventory_versions(
        inventory_definition_id,
        semantic_hash
    )
    WHERE semantic_hash IS NOT NULL;

CREATE INDEX ix_inventory_versions_definition
    ON definition.inventory_versions(
        inventory_definition_id,
        semantic_version DESC
    );

CREATE INDEX ix_inventory_versions_source_identity
    ON definition.inventory_versions(
        source_id,
        source_external_id,
        source_external_version
    );

SELECT app.assert_table_exists(
    'definition',
    'inventory_versions'
);

\echo '[PASS] 0401_inventory_versions.sql'
SELECT pg_temp.bt_mark_completed('0400_definitions/0401_inventory_versions.sql');

-- BEGIN BRICKTRACKR REBRICKABLE PHASE 5 CANONICAL: definition.inventory_versions indexes
CREATE UNIQUE INDEX IF NOT EXISTS uq_inventory_versions_source_identity
    ON definition.inventory_versions (
        source_id,
        source_external_id,
        source_external_version
    )
    WHERE source_id IS NOT NULL
      AND source_external_id IS NOT NULL
      AND source_external_version IS NOT NULL
      AND NOT is_admin_correction;
-- END BRICKTRACKR REBRICKABLE PHASE 5 CANONICAL: definition.inventory_versions indexes
