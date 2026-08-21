/*
===============================================================================
 File:           0700_mocs/0704_moc_licenses.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store MOC design/instruction licensing metadata.
 Depends On:     moc.revisions
 Creates:        moc.license_type
                 moc.licenses
 Key Rules:      Design license and instruction/file license scope are explicit.
                 CUSTOM licenses require supplied license text.
                 Machine-readable permission flags are stored where known.
 Validation:     Requires at least one license scope and custom license text when
                 CUSTOM is selected.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0700_mocs/0704_moc_licenses.sql', ARRAY['moc.revisions']::text[]);



CREATE TYPE moc.license_type AS ENUM (
    'ALL_RIGHTS_RESERVED',
    'CC_BY',
    'CC_BY_SA',
    'CC_BY_NC',
    'CC0',
    'CUSTOM'
);

CREATE TABLE moc.licenses (
    moc_license_id uuid NOT NULL DEFAULT app.uuid_v7(),

    moc_revision_id uuid NOT NULL,

    applies_to_design boolean NOT NULL DEFAULT true,
    applies_to_instructions boolean NOT NULL DEFAULT false,

    license_type moc.license_type NOT NULL,

    license_url text,
    license_text text,

    commercial_use_allowed boolean,
    redistribution_allowed boolean,
    modification_allowed boolean,
    attribution_required boolean,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_moc_licenses
        PRIMARY KEY (moc_license_id),

    CONSTRAINT fk_moc_licenses_revision
        FOREIGN KEY (moc_revision_id)
        REFERENCES moc.revisions(moc_revision_id),

    CONSTRAINT ck_moc_licenses_scope
        CHECK (
            applies_to_design
            OR applies_to_instructions
        ),

    CONSTRAINT ck_moc_licenses_custom
        CHECK (
            license_type <> 'CUSTOM'
            OR (
                license_text IS NOT NULL
                AND btrim(license_text) <> ''
            )
        )
);

CREATE INDEX ix_moc_licenses_revision
    ON moc.licenses(moc_revision_id);

SELECT app.assert_table_exists(
    'moc',
    'licenses'
);

\echo '[PASS] 0704_moc_licenses.sql'
SELECT pg_temp.bt_mark_completed('0700_mocs/0704_moc_licenses.sql');
