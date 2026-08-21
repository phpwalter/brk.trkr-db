/*
===============================================================================
 File:           0200_reference/0201_colors.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Define canonical LEGO-compatible colors and source-specific
                 external color mappings.
 Depends On:     reference.external_sources
 Creates:        reference.colors
                 reference.external_color_mappings
 Key Rules:      Canonical colors use internal identifiers and never use an
                 external source identifier as a primary key.
                 External color identifiers remain source-specific.
                 Multiple external sources may map independently to the same
                 canonical color.
                 Historical mappings remain representable through validity
                 timestamps.
                 Unknown or unresolved colors must not be represented by
                 fabricated canonical mappings.
                 Canonical colors are retired rather than hard-deleted when
                 they cease to be applicable.
 Validation:     Verifies tables, named constraints, indexes, canonical color
                 properties, source mapping uniqueness, mapping chronology,
                 and foreign-key structure.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0200_reference/0201_colors.sql', ARRAY['reference.external_sources']::text[]);



\echo '[0201] Creating canonical colors and external color mappings...'


/* ==========================================================================
 * Canonical colors
 * ========================================================================== */

CREATE TABLE reference.colors (
    color_id bigint GENERATED ALWAYS AS IDENTITY,

    canonical_name text NOT NULL,

    /*
     * RGB is descriptive metadata only.
     *
     * It is intentionally not treated as identity because:
     *   - different LEGO colors may render similarly;
     *   - source RGB values may disagree;
     *   - transparent/material effects cannot be represented by RGB alone.
     */
    rgb_hex text,

    is_transparent boolean NOT NULL DEFAULT false,

    /*
     * Metallic, pearlescent, chrome, glitter, satin, rubber and similar
     * characteristics are intentionally not encoded into a rigid enum here.
     * They can evolve independently of canonical color identity.
     */
    material_description text,

    is_retired boolean NOT NULL DEFAULT false,

    retired_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_colors
        PRIMARY KEY (color_id),

    CONSTRAINT uq_colors_canonical_name
        UNIQUE (canonical_name),

    CONSTRAINT ck_colors_canonical_name
        CHECK (
            btrim(canonical_name) <> ''
            AND canonical_name = btrim(canonical_name)
        ),

    CONSTRAINT ck_colors_rgb_hex
        CHECK (
            rgb_hex IS NULL
            OR rgb_hex ~ '^[0-9A-F]{6}$'
        ),

    CONSTRAINT ck_colors_material_description
        CHECK (
            material_description IS NULL
            OR (
                btrim(material_description) <> ''
                AND material_description = btrim(material_description)
            )
        ),

    CONSTRAINT ck_colors_retirement
        CHECK (
            (
                is_retired = false
                AND retired_at IS NULL
            )
            OR
            (
                is_retired = true
                AND retired_at IS NOT NULL
                AND retired_at >= created_at
            )
        ),

    CONSTRAINT ck_colors_timestamps
        CHECK (
            updated_at >= created_at
        )
);


COMMENT ON TABLE reference.colors IS
    'Canonical source-neutral colors used throughout the BrickTrackr catalog. '
    'External LEGO, Rebrickable, BrickLink, BrickOwl, and other color IDs are '
    'mapped separately and are never canonical primary keys.';

COMMENT ON COLUMN reference.colors.color_id IS
    'Internal canonical color identifier. This value has no external-source semantics.';

COMMENT ON COLUMN reference.colors.canonical_name IS
    'Canonical BrickTrackr display name for the color.';

COMMENT ON COLUMN reference.colors.rgb_hex IS
    'Optional normalized six-character uppercase RGB representation without a leading #. '
    'RGB is descriptive metadata and does not define canonical color identity.';

COMMENT ON COLUMN reference.colors.is_transparent IS
    'Whether the canonical color is generally considered transparent or translucent.';

COMMENT ON COLUMN reference.colors.material_description IS
    'Optional human-readable material or finish description such as metallic, '
    'pearlescent, chrome, glitter, satin, or rubber.';

COMMENT ON COLUMN reference.colors.is_retired IS
    'True when the canonical color is retained for history/search but no longer considered active.';

COMMENT ON COLUMN reference.colors.retired_at IS
    'Timestamp when the canonical color was retired. NULL while active.';

COMMENT ON COLUMN reference.colors.created_at IS
    'Timestamp when the canonical color record was created.';

COMMENT ON COLUMN reference.colors.updated_at IS
    'Timestamp of the most recent canonical color metadata change.';


/* --------------------------------------------------------------------------
 * Canonical color indexes
 * -------------------------------------------------------------------------- */

CREATE INDEX ix_colors_active_name
    ON reference.colors(canonical_name)
    WHERE is_retired = false;

CREATE INDEX ix_colors_rgb_hex
    ON reference.colors(rgb_hex)
    WHERE rgb_hex IS NOT NULL;


/* ==========================================================================
 * External source color mappings
 * ========================================================================== */

CREATE TABLE reference.external_color_mappings (
    external_color_mapping_id bigint GENERATED ALWAYS AS IDENTITY,

    source_id smallint NOT NULL,

    external_color_id text NOT NULL,

    color_id bigint NOT NULL,

    /*
     * External names are retained as source evidence. They are not used as
     * canonical identity and may differ between source versions.
     */
    external_color_name text,

    /*
     * Source-provided RGB is preserved independently from canonical RGB.
     */
    external_rgb_hex text,

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),

    valid_from timestamptz NOT NULL DEFAULT now(),
    valid_to timestamptz,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_external_color_mappings
        PRIMARY KEY (external_color_mapping_id),

    CONSTRAINT fk_external_color_mappings_source
        FOREIGN KEY (source_id)
        REFERENCES reference.external_sources(source_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,

    CONSTRAINT fk_external_color_mappings_color
        FOREIGN KEY (color_id)
        REFERENCES reference.colors(color_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,

    CONSTRAINT ck_external_color_mappings_external_id
        CHECK (
            btrim(external_color_id) <> ''
            AND external_color_id = btrim(external_color_id)
        ),

    CONSTRAINT ck_external_color_mappings_external_name
        CHECK (
            external_color_name IS NULL
            OR (
                btrim(external_color_name) <> ''
                AND external_color_name = btrim(external_color_name)
            )
        ),

    CONSTRAINT ck_external_color_mappings_rgb_hex
        CHECK (
            external_rgb_hex IS NULL
            OR external_rgb_hex ~ '^[0-9A-F]{6}$'
        ),

    CONSTRAINT ck_external_color_mappings_seen
        CHECK (
            last_seen_at >= first_seen_at
        ),

    CONSTRAINT ck_external_color_mappings_validity
        CHECK (
            valid_to IS NULL
            OR valid_to > valid_from
        ),

    CONSTRAINT ck_external_color_mappings_created
        CHECK (
            created_at <= last_seen_at
        )
);


COMMENT ON TABLE reference.external_color_mappings IS
    'Historical source-specific color identifiers mapped to canonical BrickTrackr colors. '
    'A source color ID is evidence/mapping data and never the canonical color identity.';

COMMENT ON COLUMN reference.external_color_mappings.external_color_mapping_id IS
    'Internal identifier for one historical external-source color mapping.';

COMMENT ON COLUMN reference.external_color_mappings.source_id IS
    'External source that owns the external color identifier.';

COMMENT ON COLUMN reference.external_color_mappings.external_color_id IS
    'Color identifier exactly as represented by the external source.';

COMMENT ON COLUMN reference.external_color_mappings.color_id IS
    'Canonical BrickTrackr color to which this source identifier maps during the validity interval.';

COMMENT ON COLUMN reference.external_color_mappings.external_color_name IS
    'Most recently observed source-provided color name for this mapping record.';

COMMENT ON COLUMN reference.external_color_mappings.external_rgb_hex IS
    'Optional source-provided six-character uppercase RGB value.';

COMMENT ON COLUMN reference.external_color_mappings.first_seen_at IS
    'First time this mapping was observed from the external source.';

COMMENT ON COLUMN reference.external_color_mappings.last_seen_at IS
    'Most recent time this mapping was observed from the external source.';

COMMENT ON COLUMN reference.external_color_mappings.valid_from IS
    'Beginning of the interval in which this source identifier mapped to this canonical color.';

COMMENT ON COLUMN reference.external_color_mappings.valid_to IS
    'End of the mapping validity interval. NULL means the mapping is currently active.';

COMMENT ON COLUMN reference.external_color_mappings.created_at IS
    'Timestamp when this historical mapping record was created in BrickTrackr.';


/* --------------------------------------------------------------------------
 * External mapping uniqueness
 *
 * A source identifier can only have one active canonical mapping at a time.
 * Historical mappings remain available by closing valid_to.
 * -------------------------------------------------------------------------- */

CREATE UNIQUE INDEX uq_external_color_mappings_active_source_color
    ON reference.external_color_mappings(
        source_id,
        external_color_id
    )
    WHERE valid_to IS NULL;


/* --------------------------------------------------------------------------
 * Supporting foreign-key and lookup indexes
 * -------------------------------------------------------------------------- */

CREATE INDEX ix_external_color_mappings_source
    ON reference.external_color_mappings(source_id);

CREATE INDEX ix_external_color_mappings_color
    ON reference.external_color_mappings(color_id);

CREATE INDEX ix_external_color_mappings_source_color_history
    ON reference.external_color_mappings(
        source_id,
        external_color_id,
        valid_from DESC
    );


/* ==========================================================================
 * File-local validation
 * ========================================================================== */

DO $$
DECLARE
    v_constraint text;
BEGIN
    /* ----------------------------------------------------------------------
     * Required tables.
     * ---------------------------------------------------------------------- */

    IF to_regclass('reference.colors') IS NULL THEN
        RAISE EXCEPTION
            'Required table reference.colors was not created';
    END IF;

    IF to_regclass('reference.external_color_mappings') IS NULL THEN
        RAISE EXCEPTION
            'Required table reference.external_color_mappings was not created';
    END IF;


    /* ----------------------------------------------------------------------
     * reference.colors constraints.
     * ---------------------------------------------------------------------- */

    FOREACH v_constraint IN ARRAY ARRAY[
        'pk_colors',
        'uq_colors_canonical_name',
        'ck_colors_canonical_name',
        'ck_colors_rgb_hex',
        'ck_colors_material_description',
        'ck_colors_retirement',
        'ck_colors_timestamps'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class t
              ON t.oid = c.conrelid
            JOIN pg_namespace n
              ON n.oid = t.relnamespace
            WHERE n.nspname = 'reference'
              AND t.relname = 'colors'
              AND c.conname = v_constraint
        ) THEN
            RAISE EXCEPTION
                'Required constraint "%" is missing from reference.colors',
                v_constraint;
        END IF;
    END LOOP;


    /* ----------------------------------------------------------------------
     * reference.external_color_mappings constraints.
     * ---------------------------------------------------------------------- */

    FOREACH v_constraint IN ARRAY ARRAY[
        'pk_external_color_mappings',
        'fk_external_color_mappings_source',
        'fk_external_color_mappings_color',
        'ck_external_color_mappings_external_id',
        'ck_external_color_mappings_external_name',
        'ck_external_color_mappings_rgb_hex',
        'ck_external_color_mappings_seen',
        'ck_external_color_mappings_validity',
        'ck_external_color_mappings_created'
    ]
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class t
              ON t.oid = c.conrelid
            JOIN pg_namespace n
              ON n.oid = t.relnamespace
            WHERE n.nspname = 'reference'
              AND t.relname = 'external_color_mappings'
              AND c.conname = v_constraint
        ) THEN
            RAISE EXCEPTION
                'Required constraint "%" is missing from '
                'reference.external_color_mappings',
                v_constraint;
        END IF;
    END LOOP;
END;
$$;


/* --------------------------------------------------------------------------
 * Index validation
 * -------------------------------------------------------------------------- */

DO $$
DECLARE
    v_index text;
BEGIN
    FOREACH v_index IN ARRAY ARRAY[
        'ix_colors_active_name',
        'ix_colors_rgb_hex',
        'uq_external_color_mappings_active_source_color',
        'ix_external_color_mappings_source',
        'ix_external_color_mappings_color',
        'ix_external_color_mappings_source_color_history'
    ]
    LOOP
        IF to_regclass('reference.' || v_index) IS NULL THEN
            RAISE EXCEPTION
                'Required index reference.% was not created',
                v_index;
        END IF;
    END LOOP;
END;
$$;


/* --------------------------------------------------------------------------
 * Column/type validation
 * -------------------------------------------------------------------------- */

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'reference'
          AND table_name = 'colors'
          AND column_name = 'color_id'
          AND data_type = 'bigint'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'reference.colors.color_id must be NOT NULL bigint';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'reference'
          AND table_name = 'colors'
          AND column_name = 'canonical_name'
          AND data_type = 'text'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'reference.colors.canonical_name must be NOT NULL text';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'reference'
          AND table_name = 'external_color_mappings'
          AND column_name = 'external_color_id'
          AND data_type = 'text'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION
            'reference.external_color_mappings.external_color_id '
            'must be NOT NULL text';
    END IF;
END;
$$;


/* --------------------------------------------------------------------------
 * Cross-table sanity validation
 *
 * These queries should return no rows on a valid database. They are useful
 * both for bootstrap-time validation and later manual diagnosis.
 * -------------------------------------------------------------------------- */

DO $$
BEGIN
    /*
     * There must never be more than one active mapping for the same
     * source-specific color ID.
     *
     * The partial unique index already prevents this at runtime; this is an
     * explicit semantic bootstrap assertion.
     */
    IF EXISTS (
        SELECT 1
        FROM reference.external_color_mappings
        WHERE valid_to IS NULL
        GROUP BY
            source_id,
            external_color_id
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION
            'Multiple active canonical mappings exist for the same '
            'external source color identifier';
    END IF;


    /*
     * Retired canonical colors require a retirement timestamp.
     */
    IF EXISTS (
        SELECT 1
        FROM reference.colors
        WHERE is_retired
          AND retired_at IS NULL
    ) THEN
        RAISE EXCEPTION
            'A retired canonical color exists without retired_at';
    END IF;
END;
$$;


\echo '[PASS] 0201_colors.sql'
SELECT pg_temp.bt_mark_completed('0200_reference/0201_colors.sql');
