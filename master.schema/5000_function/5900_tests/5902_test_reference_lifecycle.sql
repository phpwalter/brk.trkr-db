/*
===============================================================================
 File:           5000_function/5900_tests/5902_test_reference_lifecycle.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Behavioral tests for reference-schema hierarchy cycle
                 prevention on themes and categories.
 Depends On:     5000_function/5700_system/5701_system_hierarchy.sql
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('5000_function/5900_tests/5902_test_reference_lifecycle.sql', ARRAY['5000_function/5700_system/5701_system_hierarchy.sql']::text[]);

\echo '[TEST] 5902_test_reference_lifecycle.sql'

BEGIN;

DO $$
DECLARE
    v_theme_a integer;
    v_theme_b integer;
    v_theme_c integer;
    v_theme_d integer;

    v_cat_a integer;
    v_cat_b integer;
    v_cat_c integer;
    v_cat_d integer;

    v_failed boolean;
BEGIN
    /* -----------------------------------------------------------------
     * reference.validate_theme_cycle()
     *
     * Build a three-level chain A -> B -> C plus an unrelated root D.
     * ----------------------------------------------------------------- */
    INSERT INTO reference.themes (theme_name)
    VALUES ('BT Test Theme A 5902')
    RETURNING theme_id INTO v_theme_a;

    INSERT INTO reference.themes (theme_name, parent_theme_id)
    VALUES ('BT Test Theme B 5902', v_theme_a)
    RETURNING theme_id INTO v_theme_b;

    INSERT INTO reference.themes (theme_name, parent_theme_id)
    VALUES ('BT Test Theme C 5902', v_theme_b)
    RETURNING theme_id INTO v_theme_c;

    INSERT INTO reference.themes (theme_name)
    VALUES ('BT Test Theme D 5902')
    RETURNING theme_id INTO v_theme_d;

    /* A cannot become a descendant of its own descendant C. */
    v_failed := false;
    BEGIN
        UPDATE reference.themes
           SET parent_theme_id = v_theme_c
         WHERE theme_id = v_theme_a;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'validate_theme_cycle() allowed a theme to become an ancestor of its own ancestor'
    );

    /* B cannot be reparented under its own descendant C. */
    v_failed := false;
    BEGIN
        UPDATE reference.themes
           SET parent_theme_id = v_theme_c
         WHERE theme_id = v_theme_b;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'validate_theme_cycle() allowed a theme to be reparented under its own descendant'
    );

    /* The chain must be unchanged after both rejected attempts. */
    PERFORM app.assert_true(
        (SELECT parent_theme_id FROM reference.themes WHERE theme_id = v_theme_a) IS NULL,
        'Rejected cycle attempt altered theme A''s parent'
    );
    PERFORM app.assert_true(
        (SELECT parent_theme_id FROM reference.themes WHERE theme_id = v_theme_b) = v_theme_a,
        'Rejected cycle attempt altered theme B''s parent'
    );

    /* A legitimate, non-cyclic reparent is still permitted. */
    UPDATE reference.themes
       SET parent_theme_id = v_theme_a
     WHERE theme_id = v_theme_d;

    PERFORM app.assert_true(
        (SELECT parent_theme_id FROM reference.themes WHERE theme_id = v_theme_d) = v_theme_a,
        'validate_theme_cycle() incorrectly blocked a legitimate reparent'
    );

    /* -----------------------------------------------------------------
     * reference.validate_category_cycle()
     *
     * Build a three-level chain A -> B -> C plus an unrelated root D.
     * ----------------------------------------------------------------- */
    INSERT INTO reference.categories (category_namespace, category_name)
    VALUES ('TEST', 'BT Test Category A 5902')
    RETURNING category_id INTO v_cat_a;

    INSERT INTO reference.categories (category_namespace, category_name, parent_category_id)
    VALUES ('TEST', 'BT Test Category B 5902', v_cat_a)
    RETURNING category_id INTO v_cat_b;

    INSERT INTO reference.categories (category_namespace, category_name, parent_category_id)
    VALUES ('TEST', 'BT Test Category C 5902', v_cat_b)
    RETURNING category_id INTO v_cat_c;

    INSERT INTO reference.categories (category_namespace, category_name)
    VALUES ('TEST', 'BT Test Category D 5902')
    RETURNING category_id INTO v_cat_d;

    /* A cannot become a descendant of its own descendant C. */
    v_failed := false;
    BEGIN
        UPDATE reference.categories
           SET parent_category_id = v_cat_c
         WHERE category_id = v_cat_a;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'validate_category_cycle() allowed a category to become an ancestor of its own ancestor'
    );

    /* B cannot be reparented under its own descendant C. */
    v_failed := false;
    BEGIN
        UPDATE reference.categories
           SET parent_category_id = v_cat_c
         WHERE category_id = v_cat_b;
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLSTATE = 'P0001' THEN
                v_failed := true;
            ELSE
                RAISE;
            END IF;
    END;
    PERFORM app.assert_true(
        v_failed,
        'validate_category_cycle() allowed a category to be reparented under its own descendant'
    );

    /* The chain must be unchanged after both rejected attempts. */
    PERFORM app.assert_true(
        (SELECT parent_category_id FROM reference.categories WHERE category_id = v_cat_a) IS NULL,
        'Rejected cycle attempt altered category A''s parent'
    );
    PERFORM app.assert_true(
        (SELECT parent_category_id FROM reference.categories WHERE category_id = v_cat_b) = v_cat_a,
        'Rejected cycle attempt altered category B''s parent'
    );

    /* A legitimate, non-cyclic reparent is still permitted. */
    UPDATE reference.categories
       SET parent_category_id = v_cat_a
     WHERE category_id = v_cat_d;

    PERFORM app.assert_true(
        (SELECT parent_category_id FROM reference.categories WHERE category_id = v_cat_d) = v_cat_a,
        'validate_category_cycle() incorrectly blocked a legitimate reparent'
    );
END;
$$;

ROLLBACK;

SELECT pg_temp.bt_mark_completed('5000_function/5900_tests/5902_test_reference_lifecycle.sql');
