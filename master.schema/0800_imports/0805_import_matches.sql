/*
===============================================================================
 File:           0800_imports/0805_import_matches.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store candidate and selected canonical matches for normalized
                 import records.
 Depends On:     import.normalized_records
                 catalog.items
                 catalog.part_variants
                 identity.users
 Creates:        import.matches
 Key Rules:      A match targets exactly one catalog item or part variant.
                 At most one selected match may exist per normalized record.
                 Fuzzy name-only matching may produce candidates but must not be
                 auto-applied as authoritative ownership.
 Validation:     Enforces target exclusivity, confidence range, one selected match
                 and complete manual-resolution metadata.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0800_imports/0805_import_matches.sql', ARRAY['import.normalized_records', 'catalog.items', 'catalog.part_variants', 'identity.users']::text[]);



CREATE TABLE import.matches (
    import_match_id bigint GENERATED ALWAYS AS IDENTITY,

    normalized_record_id bigint NOT NULL,

    catalog_item_id uuid,
    part_variant_id uuid,

    confidence numeric(5,4),
    match_method text NOT NULL,

    is_selected boolean NOT NULL DEFAULT false,

    resolved_by_user_id uuid,
    resolved_at timestamptz,

    CONSTRAINT pk_import_matches
        PRIMARY KEY (import_match_id),

    CONSTRAINT fk_import_matches_record
        FOREIGN KEY (normalized_record_id)
        REFERENCES import.normalized_records(
            normalized_record_id
        )
        ON DELETE CASCADE,

    CONSTRAINT fk_import_matches_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_import_matches_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT fk_import_matches_resolved_by
        FOREIGN KEY (resolved_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_import_matches_target
        CHECK (
            num_nonnulls(
                catalog_item_id,
                part_variant_id
            ) = 1
        ),

    CONSTRAINT ck_import_matches_confidence
        CHECK (
            confidence IS NULL
            OR confidence BETWEEN 0 AND 1
        ),

    CONSTRAINT ck_import_matches_method
        CHECK (btrim(match_method) <> ''),

    CONSTRAINT ck_import_matches_resolution
        CHECK (
            (
                resolved_by_user_id IS NULL
                AND resolved_at IS NULL
            )
            OR
            (
                resolved_by_user_id IS NOT NULL
                AND resolved_at IS NOT NULL
            )
        )
);

CREATE UNIQUE INDEX uq_selected_import_match
    ON import.matches(normalized_record_id)
    WHERE is_selected;

CREATE INDEX ix_import_matches_record
    ON import.matches(normalized_record_id);

SELECT app.assert_table_exists(
    'import',
    'matches'
);

\echo '[PASS] 0805_import_matches.sql'
SELECT pg_temp.bt_mark_completed('0800_imports/0805_import_matches.sql');
