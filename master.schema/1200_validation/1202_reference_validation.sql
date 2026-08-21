/*
===============================================================================
 File:           1200_validation/1202_reference_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate external source configuration, canonical reference
                 data, source mappings, and hierarchy integrity.
 Depends On:     0200_reference/0200_external_sources.sql
                 0200_reference/0201_colors.sql
                 0200_reference/0202_themes.sql
                 0200_reference/0203_categories.sql
                 0200_reference/0204_minifig_roles.sql
 Creates:        No persistent database objects.
 Key Rules:      Required external systems must exist.
                 External reference mappings retain valid first/last-seen
                 chronology.
                 Theme and category trees may not contain cycles.
                 Baseline minifigure semantic roles must remain available.
 Validation:     Checks baseline seed data, source mapping chronology, hierarchy
                 cycles, and required minifigure role codes.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1202_reference_validation.sql', ARRAY['0200_reference/0200_external_sources.sql', '0200_reference/0201_colors.sql', '0200_reference/0202_themes.sql', '0200_reference/0203_categories.sql', '0200_reference/0204_minifig_roles.sql']::text[]);



\echo '[VALIDATE] 1202_reference_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required tables                                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_table_exists('reference', 'external_sources');
SELECT app.assert_table_exists('reference', 'colors');
SELECT app.assert_table_exists('reference', 'external_color_mappings');
SELECT app.assert_table_exists('reference', 'themes');
SELECT app.assert_table_exists('reference', 'external_theme_mappings');
SELECT app.assert_table_exists('reference', 'categories');
SELECT app.assert_table_exists('reference', 'external_category_mappings');
SELECT app.assert_table_exists('reference', 'minifig_roles');


/* -------------------------------------------------------------------------- */
/* Required external sources                                                  */
/* -------------------------------------------------------------------------- */

SELECT app.assert_true(
    (
        SELECT count(*)
        FROM reference.external_sources
        WHERE source_code IN (
            'LEGO',
            'REBRICKABLE',
            'BRICKLINK',
            'BRICKOWL',
            'STUDIO'
        )
    ) = 5,
    'One or more required external sources are missing'
);

SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM reference.external_sources
        WHERE source_code = 'REBRICKABLE'
          AND provides_catalog_data
    ),
    'Rebrickable is not configured as a catalog-data source'
);


/* -------------------------------------------------------------------------- */
/* External mapping chronology                                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM reference.external_color_mappings
    WHERE last_seen_at < first_seen_at
$$,
'External color mapping has invalid first/last-seen chronology'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM reference.external_theme_mappings
    WHERE last_seen_at < first_seen_at
$$,
'External theme mapping has invalid first/last-seen chronology'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM reference.external_category_mappings
    WHERE last_seen_at < first_seen_at
$$,
'External category mapping has invalid first/last-seen chronology'
);


/* -------------------------------------------------------------------------- */
/* Theme hierarchy cycles                                                     */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    WITH RECURSIVE theme_paths AS (
        SELECT
            t.theme_id AS origin_theme_id,
            t.parent_theme_id AS current_theme_id,
            ARRAY[t.theme_id] AS path,
            false AS cycle_found
        FROM reference.themes t
        WHERE t.parent_theme_id IS NOT NULL

        UNION ALL

        SELECT
            p.origin_theme_id,
            t.parent_theme_id,
            p.path || t.theme_id,
            t.theme_id = ANY(p.path)
        FROM theme_paths p
        JOIN reference.themes t
          ON t.theme_id = p.current_theme_id
        WHERE NOT p.cycle_found
          AND p.current_theme_id IS NOT NULL
    )
    SELECT 1
    FROM theme_paths
    WHERE cycle_found
$$,
'Theme hierarchy contains a recursive cycle'
);


/* -------------------------------------------------------------------------- */
/* Category hierarchy cycles                                                  */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    WITH RECURSIVE category_paths AS (
        SELECT
            c.category_id AS origin_category_id,
            c.parent_category_id AS current_category_id,
            ARRAY[c.category_id] AS path,
            false AS cycle_found
        FROM reference.categories c
        WHERE c.parent_category_id IS NOT NULL

        UNION ALL

        SELECT
            p.origin_category_id,
            c.parent_category_id,
            p.path || c.category_id,
            c.category_id = ANY(p.path)
        FROM category_paths p
        JOIN reference.categories c
          ON c.category_id = p.current_category_id
        WHERE NOT p.cycle_found
          AND p.current_category_id IS NOT NULL
    )
    SELECT 1
    FROM category_paths
    WHERE cycle_found
$$,
'Category hierarchy contains a recursive cycle'
);


/* -------------------------------------------------------------------------- */
/* Required minifigure roles                                                  */
/* -------------------------------------------------------------------------- */

SELECT app.assert_true(
    (
        SELECT count(*)
        FROM reference.minifig_roles
        WHERE role_code IN (
            'HEAD',
            'TORSO',
            'BODY',
            'ARM',
            'HAND',
            'LEG',
            'LOWER_BODY',
            'WING',
            'TAIL',
            'HORN',
            'SHELL',
            'BASE',
            'HAIR',
            'HEADGEAR',
            'CAPE',
            'ACCESSORY',
            'OTHER'
        )
    ) = 17,
    'Required minifigure semantic role seed is incomplete'
);


\echo '[VALIDATE PASS] 1202_reference_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1202_reference_validation.sql');
