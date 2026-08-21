/*
===============================================================================
 File:           0800_imports/0807_import_applications.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Preserve reversible user-import application operations and
                 logical before/after mutation records.
 Depends On:     import.jobs
                 identity.users
 Creates:        import.applications
                 import.application_changes
 Key Rules:      Every user import is previewed before application.
                 Applied imports remain reversible as logical units.
                 REPLACE removals are represented by archive/restore semantics
                 rather than destructive hard deletes.
 Validation:     Enforces one active application per import job, valid reversal
                 metadata and a controlled application action set.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0800_imports/0807_import_applications.sql', ARRAY['import.jobs', 'identity.users']::text[]);



CREATE TABLE import.applications (
    import_application_id uuid NOT NULL DEFAULT app.uuid_v7(),

    import_job_id uuid NOT NULL,

    applied_by_user_id uuid NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT now(),

    reversed_at timestamptz,
    reversed_by_user_id uuid,

    CONSTRAINT pk_import_applications
        PRIMARY KEY (import_application_id),

    CONSTRAINT fk_import_applications_job
        FOREIGN KEY (import_job_id)
        REFERENCES import.jobs(import_job_id),

    CONSTRAINT fk_import_applications_applied_by
        FOREIGN KEY (applied_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_import_applications_reversed_by
        FOREIGN KEY (reversed_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_import_applications_reversal
        CHECK (
            (
                reversed_at IS NULL
                AND reversed_by_user_id IS NULL
            )
            OR
            (
                reversed_at IS NOT NULL
                AND reversed_by_user_id IS NOT NULL
                AND reversed_at >= applied_at
            )
        )
);

CREATE UNIQUE INDEX uq_active_import_application
    ON import.applications(import_job_id)
    WHERE reversed_at IS NULL;


CREATE TABLE import.application_changes (
    application_change_id bigint GENERATED ALWAYS AS IDENTITY,

    import_application_id uuid NOT NULL,

    entity_schema text NOT NULL,
    entity_table text NOT NULL,
    entity_id text NOT NULL,

    action text NOT NULL,

    before_state jsonb,
    after_state jsonb,

    CONSTRAINT pk_application_changes
        PRIMARY KEY (application_change_id),

    CONSTRAINT fk_application_changes_application
        FOREIGN KEY (import_application_id)
        REFERENCES import.applications(
            import_application_id
        )
        ON DELETE CASCADE,

    CONSTRAINT ck_application_changes_action
        CHECK (
            action IN (
                'INSERT',
                'UPDATE',
                'ARCHIVE',
                'RESTORE'
            )
        )
);

CREATE INDEX ix_application_changes_application
    ON import.application_changes(
        import_application_id
    );

SELECT app.assert_table_exists(
    'import',
    'applications'
);

SELECT app.assert_table_exists(
    'import',
    'application_changes'
);

\echo '[PASS] 0807_import_applications.sql'
SELECT pg_temp.bt_mark_completed('0800_imports/0807_import_applications.sql');
