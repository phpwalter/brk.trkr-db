/*
===============================================================================
 File:           0800_imports/0800_import_jobs.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define user collection import jobs and their apply lifecycle.
 Depends On:     reference.external_sources
                 identity.owners
                 identity.users
 Creates:        import.job_status
                 import.apply_mode
                 import.jobs
 Key Rules:      User imports always belong to an owner and initiating user.
                 Imports support MERGE and scoped REPLACE behavior.
                 Import staging/previews occur before canonical mutation.
 Validation:     Enforces valid source/owner/user references and completion/
                 failure lifecycle metadata.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0800_imports/0800_import_jobs.sql', ARRAY['reference.external_sources', 'identity.owners', 'identity.users']::text[]);



CREATE TYPE import.job_status AS ENUM (
    'CREATED',
    'STAGING',
    'READY_FOR_PREVIEW',
    'APPLYING',
    'COMPLETED',
    'FAILED',
    'REVERSED'
);

CREATE TYPE import.apply_mode AS ENUM (
    'MERGE',
    'REPLACE'
);

CREATE TABLE import.jobs (
    import_job_id uuid NOT NULL DEFAULT app.uuid_v7(),

    source_id smallint NOT NULL,

    owner_id uuid NOT NULL,
    initiated_by_user_id uuid NOT NULL,

    apply_mode import.apply_mode NOT NULL,

    status import.job_status
        NOT NULL DEFAULT 'CREATED',

    source_filename text,
    source_checksum_sha256 app.sha256_digest,

    created_at timestamptz NOT NULL DEFAULT now(),

    completed_at timestamptz,
    failed_at timestamptz,
    failure_message text,

    CONSTRAINT pk_import_jobs
        PRIMARY KEY (import_job_id),

    CONSTRAINT fk_import_jobs_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id),

    CONSTRAINT fk_import_jobs_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT fk_import_jobs_user
        FOREIGN KEY (initiated_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_import_jobs_completion
        CHECK (
            status <> 'COMPLETED'
            OR completed_at IS NOT NULL
        ),

    CONSTRAINT ck_import_jobs_failure
        CHECK (
            status <> 'FAILED'
            OR (
                failed_at IS NOT NULL
                AND failure_message IS NOT NULL
                AND btrim(failure_message) <> ''
            )
        )
);

CREATE INDEX ix_import_jobs_owner
    ON import.jobs(
        owner_id,
        created_at DESC
    );

CREATE INDEX ix_import_jobs_status
    ON import.jobs(
        status,
        created_at
    );

SELECT app.assert_table_exists(
    'import',
    'jobs'
);

\echo '[PASS] 0800_import_jobs.sql'
SELECT pg_temp.bt_mark_completed('0800_imports/0800_import_jobs.sql');
