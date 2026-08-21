/*
===============================================================================
 File:           1200_validation/1204_definition_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate versioned inventory definitions, semantic versions,
                 requirement groups/options, and effective authority state.
 Depends On:     0400_definitions/0400_inventory_definitions.sql
                 0400_definitions/0401_inventory_versions.sql
                 0400_definitions/0402_requirement_groups.sql
                 0400_definitions/0403_requirement_options.sql
                 0400_definitions/0404_definition_authority.sql
 Creates:        No persistent database objects.
 Key Rules:      Semantic inventory versions belong to exactly one definition.
                 Finalized versions require semantic fingerprints.
                 Requirement groups must contain valid fulfillment options.
                 Authority-selected versions must belong to the same definition.
                 Active admin authority must reference an admin correction.
 Validation:     Checks version numbering, finalization state, requirement
                 completeness, primary-option rules, AT_LEAST_N semantics, and
                 definition-authority consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1204_definition_validation.sql', ARRAY['0400_definitions/0400_inventory_definitions.sql', '0400_definitions/0401_inventory_versions.sql', '0400_definitions/0402_requirement_groups.sql', '0400_definitions/0403_requirement_options.sql', '0400_definitions/0404_definition_authority.sql']::text[]);



\echo '[VALIDATE] 1204_definition_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required objects                                                           */
/* -------------------------------------------------------------------------- */

SELECT app.assert_table_exists('definition', 'inventory_definitions');
SELECT app.assert_table_exists('definition', 'inventory_versions');
SELECT app.assert_table_exists('definition', 'requirement_groups');
SELECT app.assert_table_exists('definition', 'requirement_options');
SELECT app.assert_table_exists('definition', 'definition_authority');


/* -------------------------------------------------------------------------- */
/* Semantic version numbering                                                 */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT inventory_definition_id, semantic_version
    FROM definition.inventory_versions
    GROUP BY inventory_definition_id, semantic_version
    HAVING count(*) > 1
$$,
'Inventory definition contains duplicate semantic version numbers'
);


/* -------------------------------------------------------------------------- */
/* Finalized version completeness                                             */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.inventory_versions
    WHERE status = 'FINALIZED'
      AND (
          semantic_hash IS NULL
          OR finalized_at IS NULL
      )
$$,
'Finalized inventory version is missing semantic hash or finalized_at'
);


/* -------------------------------------------------------------------------- */
/* Semantic fingerprint uniqueness                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT inventory_definition_id, semantic_hash
    FROM definition.inventory_versions
    WHERE semantic_hash IS NOT NULL
    GROUP BY inventory_definition_id, semantic_hash
    HAVING count(*) > 1
$$,
'Inventory definition contains duplicate semantic fingerprints'
);


/* -------------------------------------------------------------------------- */
/* Requirement groups require options                                         */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.requirement_groups g
    WHERE NOT EXISTS (
        SELECT 1
        FROM definition.requirement_options o
        WHERE o.requirement_group_id = g.requirement_group_id
    )
$$,
'Requirement group has no fulfillment options'
);


/* -------------------------------------------------------------------------- */
/* Primary-option rules                                                       */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT requirement_group_id
    FROM definition.requirement_options
    WHERE is_primary
    GROUP BY requirement_group_id
    HAVING count(*) > 1
$$,
'Requirement group has more than one primary option'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.requirement_groups g
    WHERE NOT EXISTS (
        SELECT 1
        FROM definition.requirement_options o
        WHERE o.requirement_group_id = g.requirement_group_id
          AND o.is_primary
    )
$$,
'Requirement group has no primary/reference option'
);


/* -------------------------------------------------------------------------- */
/* AT_LEAST_N semantics                                                       */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.requirement_groups g
    WHERE g.fulfillment_rule = 'AT_LEAST_N'
      AND (
          g.minimum_options IS NULL
          OR g.minimum_options <= 0
          OR g.minimum_options > (
              SELECT count(*)
              FROM definition.requirement_options o
              WHERE o.requirement_group_id = g.requirement_group_id
          )
      )
$$,
'AT_LEAST_N requirement has invalid minimum_options'
);


/* -------------------------------------------------------------------------- */
/* Latest source authority                                                    */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.definition_authority a
    JOIN definition.inventory_versions v
      ON v.inventory_version_id = a.latest_source_version_id
    WHERE v.inventory_definition_id <> a.inventory_definition_id
$$,
'latest_source_version_id belongs to another inventory definition'
);


/* -------------------------------------------------------------------------- */
/* Admin authority                                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.definition_authority a
    JOIN definition.inventory_versions v
      ON v.inventory_version_id = a.active_admin_version_id
    WHERE v.inventory_definition_id <> a.inventory_definition_id
       OR NOT v.is_admin_correction
$$,
'active_admin_version_id is invalid for its inventory definition'
);


/* -------------------------------------------------------------------------- */
/* Authority must select finalized versions                                   */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.definition_authority a
    JOIN definition.inventory_versions v
      ON v.inventory_version_id = a.latest_source_version_id
    WHERE v.status <> 'FINALIZED'
$$,
'Definition authority selects a non-finalized source version'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM definition.definition_authority a
    JOIN definition.inventory_versions v
      ON v.inventory_version_id = a.active_admin_version_id
    WHERE v.status <> 'FINALIZED'
$$,
'Definition authority selects a non-finalized admin version'
);


\echo '[VALIDATE PASS] 1204_definition_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1204_definition_validation.sql');
