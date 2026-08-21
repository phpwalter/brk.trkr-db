/*
===============================================================================
 File:           1200_validation/1209_audit_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate audit event and field-change structure.
 Depends On:     0900_audit/0900_audit_events.sql
                 0900_audit/0901_audit_changes.sql
 Creates:        No persistent database objects.
 Key Rules:      Audit events use UUIDv7 identities.
                 Field-level audit changes belong to one event.
                 Unchanged old/new values are never persisted as audit changes.
                 Actor and subject identities remain separately representable.
 Validation:     Verifies required tables/indexes, rejects unchanged field
                 records, and validates basic event targeting metadata.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1209_audit_validation.sql', ARRAY['0900_audit/0900_audit_events.sql', '0900_audit/0901_audit_changes.sql']::text[]);



\echo '[VALIDATE] 1209_audit_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required audit objects                                                     */
/* -------------------------------------------------------------------------- */

SELECT app.assert_table_exists('audit', 'events');
SELECT app.assert_table_exists('audit', 'changes');

SELECT app.assert_index_exists(
    'audit',
    'ix_audit_events_entity'
);

SELECT app.assert_index_exists(
    'audit',
    'ix_audit_events_actor'
);

SELECT app.assert_index_exists(
    'audit',
    'ix_audit_changes_event'
);


/* -------------------------------------------------------------------------- */
/* Audit changes must represent actual changes                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM audit.changes
    WHERE old_value IS NOT DISTINCT FROM new_value
$$,
'Audit field-change record contains identical old and new values'
);


/* -------------------------------------------------------------------------- */
/* Field names must remain meaningful                                         */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM audit.changes
    WHERE field_name IS NULL
       OR btrim(field_name) = ''
$$,
'Audit field-change record has an empty field name'
);


/* -------------------------------------------------------------------------- */
/* Event types must remain meaningful                                         */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM audit.events
    WHERE event_type IS NULL
       OR btrim(event_type) = ''
$$,
'Audit event has an empty event_type'
);


/* -------------------------------------------------------------------------- */
/* Entity target metadata consistency                                         */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM audit.events
    WHERE num_nonnulls(
        entity_schema,
        entity_table,
        entity_id
    ) NOT IN (0, 3)
$$,
'Audit event contains only a partial entity target'
);


\echo '[VALIDATE PASS] 1209_audit_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1209_audit_validation.sql');
