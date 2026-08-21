/*
===============================================================================
 File:           1200_validation/1207_moc_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate MOC catalog linkage, revisions, publication state,
                 forks, subassemblies, licenses, and assets.
 Depends On:     Complete 0700_mocs domain
                 catalog.mocs
                 definition.inventory_versions
 Creates:        No persistent database objects.
 Key Rules:      Every authored MOC references a catalog MOC identity.
                 Published revisions are complete and immutable.
                 Forks reference exact published source revisions.
                 Subassemblies may not form recursive cycles.
                 Custom licenses require explicit license text.
 Validation:     Checks catalog linkage, publication completeness, fork lineage,
                 fork eligibility, hierarchy cycles, and licensing invariants.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1207_moc_validation.sql', ARRAY['Complete 0700_mocs domain', 'catalog.mocs', 'definition.inventory_versions']::text[]);



\echo '[VALIDATE] 1207_moc_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required tables                                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_table_exists('moc', 'mocs');
SELECT app.assert_table_exists('moc', 'revisions');
SELECT app.assert_table_exists('moc', 'forks');
SELECT app.assert_table_exists('moc', 'subassemblies');
SELECT app.assert_table_exists('moc', 'licenses');
SELECT app.assert_table_exists('moc', 'assets');


/* -------------------------------------------------------------------------- */
/* Catalog MOC linkage                                                        */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.mocs m
    LEFT JOIN catalog.mocs cm
      ON cm.catalog_item_id = m.catalog_item_id
    WHERE cm.catalog_item_id IS NULL
$$,
'MOC domain record does not reference a catalog MOC subtype'
);


/* -------------------------------------------------------------------------- */
/* Published revision completeness                                            */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.revisions
    WHERE status = 'PUBLISHED'
      AND (
          published_at IS NULL
          OR inventory_version_id IS NULL
          OR semantic_hash IS NULL
      )
$$,
'Published MOC revision lacks publication timestamp, inventory, or semantic hash'
);


/* -------------------------------------------------------------------------- */
/* Revision parent belongs to same MOC                                        */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.revisions child
    JOIN moc.revisions parent
      ON parent.moc_revision_id = child.parent_revision_id
    WHERE child.parent_revision_id IS NOT NULL
      AND child.moc_id <> parent.moc_id
$$,
'MOC revision parent belongs to another MOC'
);


/* -------------------------------------------------------------------------- */
/* Fork source lineage                                                        */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.forks f
    JOIN moc.revisions r
      ON r.moc_revision_id = f.source_revision_id
    WHERE r.moc_id <> f.source_moc_id
$$,
'MOC fork references a revision from another source MOC'
);


/* -------------------------------------------------------------------------- */
/* Fork source revision must be published                                     */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.forks f
    JOIN moc.revisions r
      ON r.moc_revision_id = f.source_revision_id
    WHERE r.status <> 'PUBLISHED'
$$,
'MOC fork references a source revision that is not published'
);


/* -------------------------------------------------------------------------- */
/* Fork policy                                                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.forks f
    JOIN moc.mocs m
      ON m.moc_id = f.source_moc_id
    WHERE NOT m.forks_allowed
$$,
'MOC fork exists for a source MOC that does not permit forks'
);


/* -------------------------------------------------------------------------- */
/* Subassembly revision consistency                                           */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.subassemblies child
    JOIN moc.subassemblies parent
      ON parent.subassembly_id = child.parent_subassembly_id
    WHERE child.parent_subassembly_id IS NOT NULL
      AND child.moc_revision_id <> parent.moc_revision_id
$$,
'MOC subassembly parent belongs to another revision'
);


/* -------------------------------------------------------------------------- */
/* Subassembly cycles                                                         */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    WITH RECURSIVE assembly_paths AS (
        SELECT
            s.subassembly_id AS origin_subassembly_id,
            s.parent_subassembly_id AS current_subassembly_id,
            ARRAY[s.subassembly_id] AS path,
            false AS cycle_found
        FROM moc.subassemblies s
        WHERE s.parent_subassembly_id IS NOT NULL

        UNION ALL

        SELECT
            p.origin_subassembly_id,
            s.parent_subassembly_id,
            p.path || s.subassembly_id,
            s.subassembly_id = ANY(p.path)
        FROM assembly_paths p
        JOIN moc.subassemblies s
          ON s.subassembly_id = p.current_subassembly_id
        WHERE NOT p.cycle_found
          AND p.current_subassembly_id IS NOT NULL
    )
    SELECT 1
    FROM assembly_paths
    WHERE cycle_found
$$,
'MOC subassembly hierarchy contains a recursive cycle'
);


/* -------------------------------------------------------------------------- */
/* Custom license requirements                                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM moc.licenses
    WHERE license_type = 'CUSTOM'
      AND (
          license_text IS NULL
          OR btrim(license_text) = ''
      )
$$,
'CUSTOM MOC license is missing license text'
);


\echo '[VALIDATE PASS] 1207_moc_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1207_moc_validation.sql');
