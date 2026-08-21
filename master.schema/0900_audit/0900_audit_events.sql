/*
===============================================================================
 File:           0900_audit/0900_audit_events.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store top-level meaningful audit events.
 Depends On:     identity.users
                 identity.owners
                 import.jobs
                 import.source_runs
 Creates:        audit.events
 Key Rules:      Actor and subject are separate concepts.
                 Parent/delegate activity can record both actor and subject.
                 Source/import provenance may be attached directly to an event.
                 Unchanged nightly observations should not generate audit events.
 Validation:     Enforces valid referenced principals/import runs and non-empty
                 event type.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0900_audit/0900_audit_events.sql', ARRAY['identity.users', 'identity.owners', 'import.jobs', 'import.source_runs']::text[]);



CREATE TABLE audit.events (
    audit_event_id uuid NOT NULL DEFAULT app.uuid_v7(),

    event_type text NOT NULL,

    actor_user_id uuid,
    subject_user_id uuid,
    owner_id uuid,

    entity_schema text,
    entity_table text,
    entity_id text,

    import_job_id uuid,
    source_run_id uuid,

    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,

    occurred_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_audit_events
        PRIMARY KEY (audit_event_id),

    CONSTRAINT fk_audit_events_actor
        FOREIGN KEY (actor_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_audit_events_subject
        FOREIGN KEY (subject_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT fk_audit_events_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT fk_audit_events_import_job
        FOREIGN KEY (import_job_id)
        REFERENCES import.jobs(import_job_id),

    CONSTRAINT fk_audit_events_source_run
        FOREIGN KEY (source_run_id)
        REFERENCES import.source_runs(source_run_id),

    CONSTRAINT ck_audit_events_type
        CHECK (btrim(event_type) <> '')
);

CREATE INDEX ix_audit_events_entity
    ON audit.events(
        entity_schema,
        entity_table,
        entity_id
    );

CREATE INDEX ix_audit_events_actor
    ON audit.events(
        actor_user_id,
        occurred_at DESC
    );

CREATE INDEX ix_audit_events_subject
    ON audit.events(
        subject_user_id,
        occurred_at DESC
    );

SELECT app.assert_table_exists(
    'audit',
    'events'
);

\echo '[PASS] 0900_audit_events.sql'
SELECT pg_temp.bt_mark_completed('0900_audit/0900_audit_events.sql');
