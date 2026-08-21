/*
===============================================================================
 File:           0900_audit/0901_audit_changes.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store field-level old/new values belonging to audit events.
 Depends On:     audit.events
 Creates:        audit.changes
 Key Rules:      Audit detail rows represent actual changes only.
                 Dense audit details use BIGINT identity keys.
                 Audit history is append-only.
 Validation:     Rejects rows where old_value and new_value are not distinct and
                 indexes changes by parent audit event.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0900_audit/0901_audit_changes.sql', ARRAY['audit.events']::text[]);



CREATE TABLE audit.changes (
    audit_change_id bigint GENERATED ALWAYS AS IDENTITY,

    audit_event_id uuid NOT NULL,

    field_name text NOT NULL,

    old_value jsonb,
    new_value jsonb,

    CONSTRAINT pk_audit_changes
        PRIMARY KEY (audit_change_id),

    CONSTRAINT fk_audit_changes_event
        FOREIGN KEY (audit_event_id)
        REFERENCES audit.events(audit_event_id)
        ON DELETE CASCADE,

    CONSTRAINT ck_audit_changes_field
        CHECK (btrim(field_name) <> ''),

    CONSTRAINT ck_audit_changes_actual_change
        CHECK (
            old_value IS DISTINCT FROM new_value
        )
);

CREATE INDEX ix_audit_changes_event
    ON audit.changes(audit_event_id);

SELECT app.assert_table_exists(
    'audit',
    'changes'
);

\echo '[PASS] 0901_audit_changes.sql'
SELECT pg_temp.bt_mark_completed('0900_audit/0901_audit_changes.sql');
