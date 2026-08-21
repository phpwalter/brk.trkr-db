/*
===============================================================================
 File:           0800_imports/0803_source_run_datasets.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Make authoritative source dataset completeness database
                 verifiable before reconciliation/finalization.
 Depends On:     import.source_runs
 Creates:        import.dataset_status
                 import.source_run_datasets
 Key Rules:      ABSENT classification is allowed only after every required
                 authoritative dataset scope completes successfully.
                 Dataset completion/checksum/row counts are retained as source-run
                 provenance.
 Validation:     Enforces one dataset row per run/name, non-negative row counts
                 and completion timestamp consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0800_imports/0803_source_run_datasets.sql', ARRAY['import.source_runs']::text[]);



CREATE TYPE import.dataset_status AS ENUM (
    'PENDING',
    'DOWNLOADED',
    'STAGED',
    'VALIDATED',
    'COMPLETED',
    'FAILED'
);

CREATE TABLE import.source_run_datasets (
    source_run_dataset_id bigint GENERATED ALWAYS AS IDENTITY,

    source_run_id uuid NOT NULL,

    dataset_name text NOT NULL,

    status import.dataset_status
        NOT NULL DEFAULT 'PENDING',

    is_authoritative_scope boolean NOT NULL DEFAULT true,

    source_row_count bigint,
    staged_row_count bigint,

    checksum_sha256 app.sha256_digest,

    started_at timestamptz,
    completed_at timestamptz,

    CONSTRAINT pk_source_run_datasets
        PRIMARY KEY (source_run_dataset_id),

    CONSTRAINT fk_source_run_datasets_run
        FOREIGN KEY (source_run_id)
        REFERENCES import.source_runs(source_run_id)
        ON DELETE CASCADE,

    CONSTRAINT uq_source_run_dataset
        UNIQUE (
            source_run_id,
            dataset_name
        ),

    CONSTRAINT ck_source_run_datasets_name
        CHECK (btrim(dataset_name) <> ''),

    CONSTRAINT ck_source_run_datasets_counts
        CHECK (
            (
                source_row_count IS NULL
                OR source_row_count >= 0
            )
            AND
            (
                staged_row_count IS NULL
                OR staged_row_count >= 0
            )
        ),

    CONSTRAINT ck_source_run_datasets_completed
        CHECK (
            status <> 'COMPLETED'
            OR completed_at IS NOT NULL
        )
);

CREATE INDEX ix_source_run_datasets_status
    ON import.source_run_datasets(
        source_run_id,
        status
    );

SELECT app.assert_table_exists(
    'import',
    'source_run_datasets'
);

\echo '[PASS] 0803_source_run_datasets.sql'
SELECT pg_temp.bt_mark_completed('0800_imports/0803_source_run_datasets.sql');
