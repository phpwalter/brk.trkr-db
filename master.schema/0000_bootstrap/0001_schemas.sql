/*
===============================================================================
 File:           0000_bootstrap/0001_schemas.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Create logical PostgreSQL namespaces for all application
                 domains.
 Depends On:     0000_bootstrap/0000_extensions.sql
 Creates:        app
                 identity
                 reference
                 catalog
                 definition
                 collection
                 wanted
                 moc
                 import
                 audit
                 api
                 admin
                 marketplace
                 finance
                 operations
                 reporting
 Key Rules:      Each major business domain owns an explicit PostgreSQL schema.
                 Shared infrastructure belongs in app.
                 Stable application-facing database APIs belong in api.
 Validation:     Verifies every required schema exists after creation.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0000_bootstrap/0001_schemas.sql', ARRAY['0000_bootstrap/0000_extensions.sql']::text[]);



CREATE SCHEMA app;
CREATE SCHEMA identity;
CREATE SCHEMA reference;
CREATE SCHEMA catalog;
CREATE SCHEMA definition;
CREATE SCHEMA collection;
CREATE SCHEMA wanted;
CREATE SCHEMA moc;
CREATE SCHEMA import;
CREATE SCHEMA audit;
CREATE SCHEMA api;
CREATE SCHEMA admin;
CREATE SCHEMA marketplace;
CREATE SCHEMA finance;
CREATE SCHEMA operations;
CREATE SCHEMA reporting;

COMMENT ON SCHEMA app IS
    'Shared infrastructure, scalar domains, UUID generation and validation helpers.';

COMMENT ON SCHEMA identity IS
    'Users, authentication, families, delegated permissions and owners.';

COMMENT ON SCHEMA reference IS
    'External sources, colors, themes, categories and semantic reference data.';

COMMENT ON SCHEMA catalog IS
    'Canonical collectible identities, subtype metadata and source mappings.';

COMMENT ON SCHEMA definition IS
    'Versioned inventory manifests, compositions and requirement graphs.';

COMMENT ON SCHEMA collection IS
    'Ownership, physical instances, storage, acquisitions, tags and transfers.';

COMMENT ON SCHEMA wanted IS
    'Wishlists, reservations, build goals and build allocations.';

COMMENT ON SCHEMA moc IS
    'MOC authorship, revisions, forks, subassemblies, licensing and assets.';

COMMENT ON SCHEMA import IS
    'Authoritative source synchronization and user collection imports.';

COMMENT ON SCHEMA audit IS
    'Append-only meaningful audit-event and field-change history.';

COMMENT ON SCHEMA api IS
    'Stable database-facing application API surface.';

COMMENT ON SCHEMA admin IS
    'Privileged administrative routines; ordinary runtime roles receive no direct table access.';

COMMENT ON SCHEMA marketplace IS
    'Market price observations, listings, listing contents and orders.';

COMMENT ON SCHEMA finance IS
    'Double-entry financial journal and account ledger.';

COMMENT ON SCHEMA operations IS
    'Background jobs, notifications and operational request metadata.';

COMMENT ON SCHEMA reporting IS
    'Read-only reporting projections over normalized operational domains.';

DO $$
DECLARE
    v_schema text;
BEGIN
    FOREACH v_schema IN ARRAY ARRAY[
        'app',
        'identity',
        'reference',
        'catalog',
        'definition',
        'collection',
        'wanted',
        'moc',
        'import',
        'audit',
        'api',
        'admin',
        'marketplace',
        'finance',
        'operations',
        'reporting'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_namespace
            WHERE nspname = v_schema
        ) THEN
            RAISE EXCEPTION 'Required schema "%" is missing', v_schema;
        END IF;
    END LOOP;
END;
$$;

\echo '[PASS] 0001_schemas.sql'
SELECT pg_temp.bt_mark_completed('0000_bootstrap/0001_schemas.sql');
