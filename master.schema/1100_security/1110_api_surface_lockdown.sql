/*
===============================================================================
 File:           1100_security/1110_api_surface_lockdown.sql
 Project:        BrickTrackr
 Schema Version: 1.2.0
 PostgreSQL:     16+
 Purpose:        Make the runtime stored-procedure/API surface explicit,
                 deny-by-default, mechanically reviewable, and safe to rerun.
 Depends On:     1100_security/1107_grants.sql
                 5000_function/5700_system/5700_system_identity.sql
                 5000_function/5700_system/5701_system_hierarchy.sql
                 5000_function/5700_system/5702_system_catalog.sql
                 5000_function/5700_system/5703_system_definition.sql
                 5000_function/5700_system/5704_system_collection.sql
                 5000_function/5700_system/5705_system_wanted.sql
                 5000_function/5700_system/5706_system_moc.sql
                 5000_function/5000_importer/5000_importer_common.sql
                 5000_function/5700_system/5707_system_audit.sql
                 5000_function/5700_system/5708_system_integrity_hardening.sql
                 5000_function/5200_api/5200_api_moc_access.sql
                 5000_function/5700_system/5709_system_request_context.sql
                 5000_function/5100_admin/5120_admin_definition_graph.sql
                 5000_function/5200_api/5210_api_operational.sql
                 5000_function/5100_admin/5130_admin_finance.sql
                 5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql
                 5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql
                 5000_function/5000_importer/5012_importer_fail_source_run.sql
                 5000_function/5100_admin/5100_admin_common.sql
                 5000_function/5100_admin/5110_admin_catalog_lifecycle.sql
 Creates:        app.runtime_api_allowlist
 Key Rules:      PUBLIC receives no api.* EXECUTE.
                 brktrkr_api receives EXECUTE only for allowlisted routines.
                 New api.* routines receive no PUBLIC/runtime EXECUTE by default.
                 The allowlist is reconciled idempotently on every run.
===============================================================================
*/

\set ON_ERROR_STOP on

SELECT pg_temp.bt_preflight('1100_security/1110_api_surface_lockdown.sql', ARRAY['1100_security/1107_grants.sql', '5000_function/5700_system/5700_system_identity.sql', '5000_function/5700_system/5701_system_hierarchy.sql', '5000_function/5700_system/5702_system_catalog.sql', '5000_function/5700_system/5703_system_definition.sql', '5000_function/5700_system/5704_system_collection.sql', '5000_function/5700_system/5705_system_wanted.sql', '5000_function/5700_system/5706_system_moc.sql', '5000_function/5000_importer/5000_importer_common.sql', '5000_function/5700_system/5707_system_audit.sql', '5000_function/5700_system/5708_system_integrity_hardening.sql', '5000_function/5200_api/5200_api_moc_access.sql', '5000_function/5700_system/5709_system_request_context.sql', '5000_function/5100_admin/5120_admin_definition_graph.sql', '5000_function/5200_api/5210_api_operational.sql', '5000_function/5100_admin/5130_admin_finance.sql', '5000_function/5000_importer/5010_importer_rebrickable_reference_reconcile.sql', '5000_function/5000_importer/5011_importer_rebrickable_catalog_reconcile.sql', '5000_function/5000_importer/5012_importer_fail_source_run.sql', '5000_function/5100_admin/5100_admin_common.sql', '5000_function/5100_admin/5110_admin_catalog_lifecycle.sql']::text[]);


/*
===============================================================================
 1. Canonical Runtime API Allowlist

 This relation is persistent because it is the mechanically reviewable runtime
 API contract. CREATE IF NOT EXISTS makes this module safe to rerun against a
 live database without replacing the table object or breaking dependencies.
===============================================================================
*/

CREATE TABLE IF NOT EXISTS app.runtime_api_allowlist (
    routine_signature text PRIMARY KEY,
    purpose text NOT NULL,
    anonymous_safe boolean NOT NULL DEFAULT false,
    CONSTRAINT ck_runtime_api_signature_schema
        CHECK (routine_signature LIKE 'api.%')
);

COMMENT ON TABLE app.runtime_api_allowlist IS
    'Canonical reviewed allowlist of api.* routines executable by brktrkr_api.';


/*
===============================================================================
 2. Reconcile Allowlist Contents

 The seed below is authoritative. Existing matching rows are updated, new rows
 are inserted, and stale rows no longer present in source control are removed.
===============================================================================
*/

WITH authoritative_allowlist(
    routine_signature,
    purpose,
    anonymous_safe
) AS (
    VALUES
        ('api.get_moc_by_id(uuid)',
         'Read one MOC subject to PUBLIC/UNLISTED/owner visibility rules.', true),
        ('api.get_moc_revisions(uuid)',
         'Read MOC revision metadata subject to MOC visibility rules.', true),
        ('api.get_moc_assets(uuid,uuid)',
         'Read MOC assets subject to MOC visibility rules.', true),
        ('api.get_moc_licenses(uuid,uuid)',
         'Read MOC license data subject to MOC visibility rules.', true),
        ('api.get_moc_subassemblies(uuid,uuid)',
         'Read MOC subassemblies subject to MOC visibility rules.', true),
        ('api.search_catalog(text,integer)',
         'Search the catalog through the reviewed API boundary.', false),
        ('api.mark_notification_read(uuid)',
         'Mark an authenticated caller-owned notification as read.', false),
        ('api.transfer_collection_quantity(uuid,uuid,app.quantity,text)',
         'Transfer collection quantity after database authorization checks.', false)
)
INSERT INTO app.runtime_api_allowlist(
    routine_signature,
    purpose,
    anonymous_safe
)
SELECT
    a.routine_signature,
    a.purpose,
    a.anonymous_safe
FROM authoritative_allowlist AS a
ON CONFLICT (routine_signature)
DO UPDATE
SET purpose = EXCLUDED.purpose,
    anonymous_safe = EXCLUDED.anonymous_safe;

DELETE FROM app.runtime_api_allowlist AS existing
WHERE existing.routine_signature NOT IN (
    'api.get_moc_by_id(uuid)',
    'api.get_moc_revisions(uuid)',
    'api.get_moc_assets(uuid,uuid)',
    'api.get_moc_licenses(uuid,uuid)',
    'api.get_moc_subassemblies(uuid,uuid)',
    'api.search_catalog(text,integer)',
    'api.mark_notification_read(uuid)',
    'api.transfer_collection_quantity(uuid,uuid,app.quantity,text)'
);


/*
===============================================================================
 3. Protect the Allowlist
===============================================================================
*/

REVOKE ALL PRIVILEGES ON TABLE app.runtime_api_allowlist
FROM PUBLIC, brktrkr_api;


/*
===============================================================================
 4. Deny-by-Default API Execution

 Revoke before granting the reviewed exact surface. This removes accidental or
 historical grants and makes repeated execution deterministic.
===============================================================================
*/

REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA api
FROM PUBLIC, brktrkr_api;


/*
===============================================================================
 5. Future Routine Defaults

 PostgreSQL grants PUBLIC EXECUTE on newly created routines unless the owner's
 default privileges are changed. API routines are owned by brktrkr_owner, so
 default privileges are set explicitly for that owner and schema.
===============================================================================
*/

ALTER DEFAULT PRIVILEGES
FOR ROLE brktrkr_owner
REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

ALTER DEFAULT PRIVILEGES
FOR ROLE brktrkr_owner
IN SCHEMA api
REVOKE EXECUTE ON ROUTINES FROM brktrkr_api;


/*
===============================================================================
 6. Runtime Schema Boundary
===============================================================================
*/

GRANT USAGE ON SCHEMA api TO brktrkr_api;
REVOKE CREATE ON SCHEMA api FROM PUBLIC, brktrkr_api;


/*
===============================================================================
 7. Grant Exact Allowlisted Routine Signatures

 to_regprocedure() makes signature drift fail installation rather than silently
 granting a different overload.
===============================================================================
*/

DO $api_surface$
DECLARE
    v_signature text;
    v_oid oid;
BEGIN
    FOR v_signature IN
        SELECT routine_signature
        FROM app.runtime_api_allowlist
        ORDER BY routine_signature
    LOOP
        v_oid := pg_catalog.to_regprocedure(v_signature);

        IF v_oid IS NULL THEN
            RAISE EXCEPTION
                'Approved runtime API routine does not exist: %',
                v_signature;
        END IF;

        EXECUTE pg_catalog.format(
            'GRANT EXECUTE ON ROUTINE %s TO brktrkr_api',
            v_oid::regprocedure
        );
    END LOOP;
END
$api_surface$;


/*
===============================================================================
 8. Verification
===============================================================================
*/

DO $verify_api_surface$
DECLARE
    v_signature text;
    v_oid oid;
    v_count integer;
BEGIN
    SELECT pg_catalog.count(*)
    INTO v_count
    FROM app.runtime_api_allowlist;

    IF v_count <> 8 THEN
        RAISE EXCEPTION
            'Runtime API allowlist cardinality mismatch: expected 8, found %.',
            v_count;
    END IF;

    FOR v_signature IN
        SELECT routine_signature
        FROM app.runtime_api_allowlist
        ORDER BY routine_signature
    LOOP
        v_oid := pg_catalog.to_regprocedure(v_signature);

        IF v_oid IS NULL THEN
            RAISE EXCEPTION
                'Allowlisted API routine cannot be resolved during verification: %',
                v_signature;
        END IF;

        IF NOT pg_catalog.has_function_privilege(
            'brktrkr_api',
            v_oid,
            'EXECUTE'
        ) THEN
            RAISE EXCEPTION
                'brktrkr_api does not have EXECUTE on allowlisted routine %.',
                v_signature;
        END IF;
    END LOOP;

    IF pg_catalog.has_table_privilege(
        'brktrkr_api',
        'app.runtime_api_allowlist',
        'SELECT'
    )
    OR pg_catalog.has_table_privilege(
        'brktrkr_api',
        'app.runtime_api_allowlist',
        'INSERT'
    )
    OR pg_catalog.has_table_privilege(
        'brktrkr_api',
        'app.runtime_api_allowlist',
        'UPDATE'
    )
    OR pg_catalog.has_table_privilege(
        'brktrkr_api',
        'app.runtime_api_allowlist',
        'DELETE'
    )
    THEN
        RAISE EXCEPTION
            'Security contract failure: brktrkr_api must not have direct table privileges on app.runtime_api_allowlist.';
    END IF;
END
$verify_api_surface$;

\echo '[PASS] 1110_api_surface_lockdown.sql'
SELECT pg_temp.bt_mark_completed('1100_security/1110_api_surface_lockdown.sql');
