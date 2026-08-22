/*
===============================================================================
 File:           1100_security/1110_api_surface_lockdown.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Make the runtime stored-procedure/API surface explicit,
                 deny-by-default, and mechanically reviewable.
 Depends On:     1100_security/1107_grants.sql
                 Complete 1000_function domain
 Creates:        app.runtime_api_allowlist
 Key Rules:      PUBLIC receives no api.* EXECUTE.
                 lego_api/lego_app receive EXECUTE only for allowlisted routines.
                 New api.* routines receive no PUBLIC/runtime EXECUTE by default.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1110_api_surface_lockdown.sql', ARRAY['1100_security/1107_grants.sql', 'Complete 1000_function domain']::text[]);

/*
 * Canonical, version-controlled runtime API contract.
 *
 * This relation is intentionally not readable or writable by runtime roles.
 * Changing the callable API requires a reviewed schema change to this seed.
 */
CREATE TABLE app.runtime_api_allowlist (
    routine_signature text PRIMARY KEY,
    purpose text NOT NULL,
    anonymous_safe boolean NOT NULL DEFAULT false,
    CONSTRAINT ck_runtime_api_signature_schema
        CHECK (routine_signature LIKE 'api.%')
);

COMMENT ON TABLE app.runtime_api_allowlist IS
    'Canonical reviewed allowlist of api.* routines executable by runtime roles.';

INSERT INTO app.runtime_api_allowlist(
    routine_signature,
    purpose,
    anonymous_safe
)
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
     'Transfer collection quantity after database authorization checks.', false);

REVOKE ALL PRIVILEGES ON app.runtime_api_allowlist
FROM PUBLIC, lego_api, lego_app;

/*
 * Reconcile the installed database to deny-by-default before granting the
 * reviewed surface.  This also removes accidental grants made earlier in a
 * migration or inherited from historical grant scripts.
 */
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA api
FROM PUBLIC, lego_api, lego_app;

/*
 * PostgreSQL grants PUBLIC EXECUTE on newly-created routines by default.
 * That built-in grant is global, and PostgreSQL does not allow a per-schema
 * REVOKE to subtract a global default.  Therefore the owning/deployment role's
 * routine defaults are made private globally.  Any intentionally public
 * routine must be granted explicitly in the same reviewed migration.
 */
ALTER DEFAULT PRIVILEGES
    REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

ALTER DEFAULT PRIVILEGES
    REVOKE EXECUTE ON ROUTINES FROM lego_api, lego_app;

/* The runtime roles need schema lookup, but never CREATE. */
GRANT USAGE ON SCHEMA api TO lego_api, lego_app;
REVOKE CREATE ON SCHEMA api FROM PUBLIC, lego_api, lego_app;

/*
 * Resolve every allowlisted signature and grant only that exact overload.
 * to_regprocedure() makes signature drift (including argument-type changes)
 * fail installation rather than silently granting a different overload.
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
        v_oid := to_regprocedure(v_signature);

        IF v_oid IS NULL THEN
            RAISE EXCEPTION
                'Approved runtime API routine does not exist: %',
                v_signature;
        END IF;

        EXECUTE format(
            'GRANT EXECUTE ON ROUTINE %s TO lego_api, lego_app',
            v_oid::regprocedure
        );
    END LOOP;
END
$api_surface$;

SELECT pg_temp.bt_mark_completed('1100_security/1110_api_surface_lockdown.sql');
