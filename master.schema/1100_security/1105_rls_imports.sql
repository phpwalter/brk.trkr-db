/*
===============================================================================
 File:           1100_security/1105_rls_imports.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Isolate every user-facing import table by import owner while
                 keeping authoritative source-run tables on the importer role.
 Depends On:     Complete 0800_imports domain
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1105_rls_imports.sql', ARRAY['Complete 0800_imports domain', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]);



ALTER TABLE import.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE import.raw_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE import.normalized_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE import.matches ENABLE ROW LEVEL SECURITY;
ALTER TABLE import.user_mapping_suggestions ENABLE ROW LEVEL SECURITY;
ALTER TABLE import.applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE import.application_changes ENABLE ROW LEVEL SECURITY;


/* Import jobs */
CREATE POLICY pol_import_jobs_select
ON import.jobs
FOR SELECT
USING (
    identity.can_view_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
);

CREATE POLICY pol_import_jobs_modify
ON import.jobs
FOR ALL
USING (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
)
WITH CHECK (
    identity.can_manage_owner(
        identity.current_user_id(),
        owner_id,
        'COLLECTION'
    )
);


/* Raw records */
CREATE POLICY pol_raw_records_select
ON import.raw_records
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.raw_records.import_job_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_raw_records_modify
ON import.raw_records
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.raw_records.import_job_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.raw_records.import_job_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);


/* Normalized records */
CREATE POLICY pol_normalized_records_select
ON import.normalized_records
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.normalized_records.import_job_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_normalized_records_modify
ON import.normalized_records
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.normalized_records.import_job_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.normalized_records.import_job_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);


/* Candidate matches */
CREATE POLICY pol_matches_select
ON import.matches
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM import.normalized_records n
        JOIN import.jobs j
          ON j.import_job_id = n.import_job_id
        WHERE n.normalized_record_id = import.matches.normalized_record_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_matches_modify
ON import.matches
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM import.normalized_records n
        JOIN import.jobs j
          ON j.import_job_id = n.import_job_id
        WHERE n.normalized_record_id = import.matches.normalized_record_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM import.normalized_records n
        JOIN import.jobs j
          ON j.import_job_id = n.import_job_id
        WHERE n.normalized_record_id = import.matches.normalized_record_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);


/* Mapping suggestions are private to the originating user. */
CREATE POLICY pol_user_mapping_suggestions_self
ON import.user_mapping_suggestions
FOR ALL
USING (
    user_id = identity.current_user_id()
)
WITH CHECK (
    user_id = identity.current_user_id()
);


/* Applications inherit the import job owner. */
CREATE POLICY pol_import_applications_select
ON import.applications
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.applications.import_job_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_import_applications_modify
ON import.applications
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.applications.import_job_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM import.jobs j
        WHERE j.import_job_id = import.applications.import_job_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);


/* Before/after change snapshots inherit the application/job owner. */
CREATE POLICY pol_application_changes_select
ON import.application_changes
FOR SELECT
USING (
    EXISTS (
        SELECT 1
        FROM import.applications a
        JOIN import.jobs j
          ON j.import_job_id = a.import_job_id
        WHERE a.import_application_id =
              import.application_changes.import_application_id
          AND identity.can_view_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);

CREATE POLICY pol_application_changes_modify
ON import.application_changes
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM import.applications a
        JOIN import.jobs j
          ON j.import_job_id = a.import_job_id
        WHERE a.import_application_id =
              import.application_changes.import_application_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM import.applications a
        JOIN import.jobs j
          ON j.import_job_id = a.import_job_id
        WHERE a.import_application_id =
              import.application_changes.import_application_id
          AND identity.can_manage_owner(
              identity.current_user_id(),
              j.owner_id,
              'COLLECTION'
          )
    )
);

\echo '[PASS] 1105_rls_imports.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1105_rls_imports.sql');
