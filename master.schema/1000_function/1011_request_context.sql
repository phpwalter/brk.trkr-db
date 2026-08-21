/*
===============================================================================
 File:           1000_function/1011_request_context.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Provide request/trace/audit correlation context for routines
                 and triggers.
 Depends On:     app schema
                 identity.current_user_id()
                 audit.events
 Creates:        app.current_request_id()
                 app.current_trace_id()
                 app.current_actor_class()
                 app.set_request_context(...)
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1000_function/1011_request_context.sql', ARRAY['app schema', 'identity.current_user_id()', 'audit.events']::text[]);



CREATE OR REPLACE FUNCTION app.current_request_id()
RETURNS uuid LANGUAGE sql STABLE
AS $$ SELECT NULLIF(current_setting('app.request_id', true), '')::uuid $$;

CREATE OR REPLACE FUNCTION app.current_trace_id()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT NULLIF(current_setting('app.trace_id', true), '') $$;

CREATE OR REPLACE FUNCTION app.current_actor_class()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT COALESCE(NULLIF(current_setting('app.actor_class', true), ''), 'USER') $$;

CREATE OR REPLACE FUNCTION app.set_request_context(
    p_request_id uuid,
    p_trace_id text DEFAULT NULL,
    p_actor_class text DEFAULT 'USER'
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
BEGIN
    IF p_actor_class NOT IN ('USER','ADMIN','IMPORTER','SYSTEM') THEN
        RAISE EXCEPTION 'Invalid actor class: %', p_actor_class USING ERRCODE='22023';
    END IF;
    PERFORM set_config('app.request_id', COALESCE(p_request_id::text, ''), true);
    PERFORM set_config('app.trace_id', COALESCE(p_trace_id, ''), true);
    PERFORM set_config('app.actor_class', p_actor_class, true);
END;
$$;

ALTER TABLE audit.events
    ADD COLUMN request_id uuid DEFAULT app.current_request_id(),
    ADD COLUMN trace_id text DEFAULT app.current_trace_id(),
    ADD COLUMN actor_class text DEFAULT app.current_actor_class();

ALTER TABLE audit.events
    ADD CONSTRAINT ck_audit_events_actor_class
    CHECK (actor_class IS NULL OR actor_class IN ('USER','ADMIN','IMPORTER','SYSTEM'));

CREATE INDEX ix_audit_events_request
    ON audit.events(request_id)
    WHERE request_id IS NOT NULL;

CREATE INDEX ix_audit_events_trace
    ON audit.events(trace_id)
    WHERE trace_id IS NOT NULL;
SELECT pg_temp.bt_mark_completed('1000_function/1011_request_context.sql');
