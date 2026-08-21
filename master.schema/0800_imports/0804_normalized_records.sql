/*
===============================================================================
 File:           0800_imports/0804_normalized_records.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store source-neutral normalized user collection import records.
 Depends On:     import.jobs
                 import.raw_records
 Creates:        import.match_status
                 import.normalized_records
 Key Rules:      Source-specific raw formats are normalized before matching.
                 Fuzzy candidates never directly become canonical ownership.
                 Every normalized record retains its import-job provenance.
 Validation:     Enforces valid entity namespace format and valid job/raw-record
                 references.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0800_imports/0804_normalized_records.sql', ARRAY['import.jobs', 'import.raw_records']::text[]);



CREATE TYPE import.match_status AS ENUM (
    'UNMATCHED',
    'AUTO_MATCHED',
    'USER_MATCHED',
    'AMBIGUOUS',
    'IGNORED',
    'INVALID'
);

CREATE TABLE import.normalized_records (
    normalized_record_id bigint GENERATED ALWAYS AS IDENTITY,

    import_job_id uuid NOT NULL,
    raw_record_id bigint,

    entity_namespace text NOT NULL,

    normalized_payload jsonb NOT NULL,

    match_status import.match_status
        NOT NULL DEFAULT 'UNMATCHED',

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_normalized_records
        PRIMARY KEY (normalized_record_id),

    CONSTRAINT fk_normalized_records_job
        FOREIGN KEY (import_job_id)
        REFERENCES import.jobs(import_job_id)
        ON DELETE CASCADE,

    CONSTRAINT fk_normalized_records_raw
        FOREIGN KEY (raw_record_id)
        REFERENCES import.raw_records(raw_record_id),

    CONSTRAINT ck_normalized_records_namespace
        CHECK (
            entity_namespace ~ '^[A-Z0-9_]+$'
        )
);

CREATE INDEX ix_normalized_records_job_status
    ON import.normalized_records(
        import_job_id,
        match_status
    );

SELECT app.assert_table_exists(
    'import',
    'normalized_records'
);

\echo '[PASS] 0804_normalized_records.sql'
SELECT pg_temp.bt_mark_completed('0800_imports/0804_normalized_records.sql');
