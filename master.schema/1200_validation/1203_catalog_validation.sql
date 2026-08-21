/*
===============================================================================
 File:           1200_validation/1203_catalog_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Validate canonical catalog roots, subtype tables, part
                 relationships, external identifiers, and source/admin state.
 Depends On:     Complete 0300_catalog domain
 Creates:        No persistent database objects.
 Key Rules:      Every catalog item belongs to exactly one declared item kind.
                 Every catalog item must have the matching subtype row.
                 Every subtype row must reference an item with the matching kind.
                 PART design, variant, and LEGO element identities remain
                 structurally distinct.
                 External source identities are evidence/mappings, not PKs.
                 User-only unresolved catalog items must remain owner-scoped.
 Validation:     Validates all fourteen catalog subtypes in both directions,
                 unresolved-owner rules, external-ID target exclusivity and
                 chronology, part supersession integrity, and source/admin state.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1203_catalog_validation.sql', ARRAY['Complete 0300_catalog domain']::text[]);



\echo '[VALIDATE] 1203_catalog_validation.sql'


/* -------------------------------------------------------------------------- */
/* Required root and subtype tables                                           */
/* -------------------------------------------------------------------------- */

SELECT app.assert_table_exists('catalog', 'items');

SELECT app.assert_table_exists('catalog', 'sets');
SELECT app.assert_table_exists('catalog', 'parts');
SELECT app.assert_table_exists('catalog', 'minifigures');
SELECT app.assert_table_exists('catalog', 'books');
SELECT app.assert_table_exists('catalog', 'mocs');
SELECT app.assert_table_exists('catalog', 'sticker_sheets');
SELECT app.assert_table_exists('catalog', 'instructions');
SELECT app.assert_table_exists('catalog', 'packaging');
SELECT app.assert_table_exists('catalog', 'gear');
SELECT app.assert_table_exists('catalog', 'accessories');
SELECT app.assert_table_exists('catalog', 'polybags');
SELECT app.assert_table_exists('catalog', 'promotional_items');
SELECT app.assert_table_exists('catalog', 'publications');
SELECT app.assert_table_exists('catalog', 'other_items');

SELECT app.assert_table_exists('catalog', 'part_variants');
SELECT app.assert_table_exists('catalog', 'lego_elements');
SELECT app.assert_table_exists('catalog', 'external_identifiers');
SELECT app.assert_table_exists('catalog', 'source_values');
SELECT app.assert_table_exists('catalog', 'source_value_history');
SELECT app.assert_table_exists('catalog', 'admin_overrides');


/* -------------------------------------------------------------------------- */
/* Root -> subtype completeness                                               */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT i.catalog_item_id
    FROM catalog.items i
    WHERE
        (i.item_kind = 'SET'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.sets x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'PART'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.parts x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'MINIFIGURE'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.minifigures x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'BOOK'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.books x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'MOC'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.mocs x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'STICKER_SHEET'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.sticker_sheets x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'INSTRUCTIONS'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.instructions x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'PACKAGING'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.packaging x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'GEAR'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.gear x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'ACCESSORY'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.accessories x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'POLYBAG'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.polybags x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'PROMOTIONAL_ITEM'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.promotional_items x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'PUBLICATION'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.publications x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))

        OR

        (i.item_kind = 'OTHER'
         AND NOT EXISTS (
             SELECT 1
             FROM catalog.other_items x
             WHERE x.catalog_item_id = i.catalog_item_id
         ))
$$,
'A catalog item is missing its required subtype row'
);


/* -------------------------------------------------------------------------- */
/* Subtype -> root kind integrity                                             */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.sets x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'SET'
$$,
'catalog.sets contains a non-SET catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.parts x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'PART'
$$,
'catalog.parts contains a non-PART catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.minifigures x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'MINIFIGURE'
$$,
'catalog.minifigures contains a non-MINIFIGURE catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.books x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'BOOK'
$$,
'catalog.books contains a non-BOOK catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.mocs x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'MOC'
$$,
'catalog.mocs contains a non-MOC catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.sticker_sheets x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'STICKER_SHEET'
$$,
'catalog.sticker_sheets contains a non-STICKER_SHEET catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.instructions x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'INSTRUCTIONS'
$$,
'catalog.instructions contains a non-INSTRUCTIONS catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.packaging x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'PACKAGING'
$$,
'catalog.packaging contains a non-PACKAGING catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.gear x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'GEAR'
$$,
'catalog.gear contains a non-GEAR catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.accessories x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'ACCESSORY'
$$,
'catalog.accessories contains a non-ACCESSORY catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.polybags x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'POLYBAG'
$$,
'catalog.polybags contains a non-POLYBAG catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.promotional_items x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'PROMOTIONAL_ITEM'
$$,
'catalog.promotional_items contains a non-PROMOTIONAL_ITEM catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.publications x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'PUBLICATION'
$$,
'catalog.publications contains a non-PUBLICATION catalog item'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.other_items x
    JOIN catalog.items i
      ON i.catalog_item_id = x.catalog_item_id
    WHERE i.item_kind <> 'OTHER'
$$,
'catalog.other_items contains a non-OTHER catalog item'
);


/* -------------------------------------------------------------------------- */
/* Unresolved custom item isolation                                           */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.items
    WHERE
        (
            status = 'UNRESOLVED_CUSTOM'
            AND unresolved_owner_id IS NULL
        )
        OR
        (
            status <> 'UNRESOLVED_CUSTOM'
            AND unresolved_owner_id IS NOT NULL
        )
$$,
'Catalog unresolved-owner state is inconsistent with item status'
);


/* -------------------------------------------------------------------------- */
/* Part supersession integrity                                                */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.parts p
    JOIN catalog.items replacement
      ON replacement.catalog_item_id = p.superseded_by_catalog_item_id
    WHERE p.superseded_by_catalog_item_id IS NOT NULL
      AND replacement.item_kind <> 'PART'
$$,
'A PART design is superseded by a non-PART catalog item'
);


/* -------------------------------------------------------------------------- */
/* External identifier integrity                                              */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.external_identifiers
    WHERE num_nonnulls(catalog_item_id, part_variant_id) <> 1
$$,
'External identifier does not target exactly one canonical object'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.external_identifiers
    WHERE last_seen_at < first_seen_at
$$,
'External identifier has invalid first/last-seen chronology'
);

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.external_identifiers
    WHERE valid_from IS NOT NULL
      AND valid_to IS NOT NULL
      AND valid_to < valid_from
$$,
'External identifier has invalid validity date range'
);


/* -------------------------------------------------------------------------- */
/* Source scalar history                                                      */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT 1
    FROM catalog.source_value_history
    WHERE old_value IS NOT DISTINCT FROM new_value
$$,
'Catalog source history contains an unchanged value'
);


/* -------------------------------------------------------------------------- */
/* Admin override uniqueness                                                  */
/* -------------------------------------------------------------------------- */

SELECT app.assert_no_rows(
$$
    SELECT catalog_item_id, field_name
    FROM catalog.admin_overrides
    WHERE cleared_at IS NULL
    GROUP BY catalog_item_id, field_name
    HAVING count(*) > 1
$$,
'A catalog field has more than one active admin override'
);


\echo '[VALIDATE PASS] 1203_catalog_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1203_catalog_validation.sql');
