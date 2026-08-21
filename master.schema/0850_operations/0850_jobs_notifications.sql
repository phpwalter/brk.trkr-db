/*
===============================================================================
 File:           0850_operations/0850_jobs_notifications.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Add generic background jobs and owner/user notifications.
 Depends On:     identity.users
                 identity.owners
 Creates:        operations.job_status
                 operations.job_priority
                 operations.jobs
                 operations.notifications
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0850_operations/0850_jobs_notifications.sql', ARRAY['identity.users', 'identity.owners']::text[]);



CREATE TYPE operations.job_status AS ENUM ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED');
CREATE TYPE operations.job_priority AS ENUM ('LOW','NORMAL','HIGH','URGENT');

CREATE TABLE operations.jobs (
    operations_job_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    job_type text NOT NULL,
    status operations.job_status NOT NULL DEFAULT 'QUEUED',
    priority operations.job_priority NOT NULL DEFAULT 'NORMAL',
    idempotency_key text UNIQUE,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    attempts integer NOT NULL DEFAULT 0,
    max_attempts integer NOT NULL DEFAULT 5,
    available_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_operations_job_type CHECK (btrim(job_type) <> ''),
    CONSTRAINT ck_operations_job_attempts CHECK (attempts >= 0 AND max_attempts > 0 AND attempts <= max_attempts),
    CONSTRAINT ck_operations_job_payload CHECK (jsonb_typeof(payload) = 'object')
);
CREATE INDEX ix_operations_jobs_dispatch
    ON operations.jobs(priority DESC, available_at, created_at)
    WHERE status = 'QUEUED';

CREATE TABLE operations.notifications (
    notification_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    user_id uuid NOT NULL REFERENCES identity.users(user_id) ON DELETE CASCADE,
    owner_id uuid REFERENCES identity.owners(owner_id) ON DELETE CASCADE,
    notification_type text NOT NULL,
    priority operations.job_priority NOT NULL DEFAULT 'NORMAL',
    title text NOT NULL,
    body text,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_read boolean NOT NULL DEFAULT false,
    read_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_notifications_type CHECK (btrim(notification_type) <> ''),
    CONSTRAINT ck_notifications_title CHECK (btrim(title) <> ''),
    CONSTRAINT ck_notifications_data CHECK (jsonb_typeof(data) = 'object'),
    CONSTRAINT ck_notifications_read_state CHECK (
        (is_read = false AND read_at IS NULL)
        OR (is_read = true AND read_at IS NOT NULL)
    )
);
CREATE INDEX ix_notifications_user_unread
    ON operations.notifications(user_id, is_read, created_at DESC);
SELECT pg_temp.bt_mark_completed('0850_operations/0850_jobs_notifications.sql');
