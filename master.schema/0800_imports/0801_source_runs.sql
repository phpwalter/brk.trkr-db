/*
===============================================================================
 File:           0800_imports/0801_source_runs.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Represent authoritative external-source synchronization runs.
 Depends On:     reference.external_sources
 Creates:        import.source_run_status
                 import.source_runs
 Key Rules:      A source run is provenance/observation, not a semantic catalog
                 version.
                 Failed/incomplete runs never authorize source absence.
                 Finalization occurs only after required dataset completion.
 Validation:     Enforces valid completion/failure lifecycle metadata and indexed
                 source-run history.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0800_imports/0801_source_runs.sql', ARRAY['reference.external_sources']::text[]);



CREATE TYPE import.source_run_status AS ENUM (
    'STARTED',
    'STAGING',
    'VALIDATING',
    'FINALIZING',
    'COMPLETED',
    'FAILED'
);

CREATE TABLE import.source_runs (
    source_run_id uuid NOT NULL DEFAULT app.uuid_v7(),

    source_id smallint NOT NULL,

    status import.source_run_status
        NOT NULL DEFAULT 'STARTED',

    started_at timestamptz NOT NULL DEFAULT now(),

    completed_at timestamptz,
    failed_at timestamptz,

    failure_message text,

    summary jsonb NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT pk_source_runs
        PRIMARY KEY (source_run_id),

    CONSTRAINT fk_source_runs_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT ck_source_runs_completed
        CHECK (
            status <> 'COMPLETED'
            OR completed_at IS NOT NULL
        ),

    CONSTRAINT ck_source_runs_failed
        CHECK (
            status <> 'FAILED'
            OR (
                failed_at IS NOT NULL
                AND failure_message IS NOT NULL
                AND btrim(failure_message) <> ''
            )
        )
);

CREATE INDEX ix_source_runs_source_started
    ON import.source_runs(
        source_id,
        started_at DESC
    );

SELECT app.assert_table_exists(
    'import',
    'source_runs'
);

\echo '[PASS] 0801_source_runs.sql'
SELECT pg_temp.bt_mark_completed('0800_imports/0801_source_runs.sql');
