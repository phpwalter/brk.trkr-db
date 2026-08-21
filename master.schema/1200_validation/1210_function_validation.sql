/*
===============================================================================
 File:           1200_validation/1210_function_validation.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.0.0
 PostgreSQL:     16+
 Purpose:        Validate runtime functions and invariant triggers.
 Depends On:     Complete 1000_function domain
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1200_validation/1210_function_validation.sql', ARRAY['Complete 1000_function domain']::text[]);



\echo '[VALIDATE] 1210_function_validation.sql'

/* Identity */
SELECT app.assert_function_exists('identity.current_user_id()');
SELECT app.assert_function_exists('identity.ensure_owner_for_user(uuid)');
SELECT app.assert_function_exists('identity.ensure_owner_for_family(uuid)');
SELECT app.assert_function_exists('identity.has_family_capability(uuid,uuid,text,text)');
SELECT app.assert_function_exists('identity.can_manage_user(uuid,uuid,text)');
SELECT app.assert_function_exists('identity.can_view_owner(uuid,uuid,text)');
SELECT app.assert_function_exists('identity.can_manage_owner(uuid,uuid,text)');
SELECT app.assert_function_exists('identity.can_view_family_shared_owner(uuid,uuid,text)');
SELECT app.assert_function_exists('identity.can_transfer_between(uuid,uuid,uuid)');
SELECT app.assert_function_exists('identity.validate_guardianship()');

/* Hierarchies */
SELECT app.assert_function_exists('reference.validate_theme_cycle()');
SELECT app.assert_function_exists('reference.validate_category_cycle()');
SELECT app.assert_function_exists('collection.validate_storage_cycle()');
SELECT app.assert_function_exists('moc.validate_subassembly_cycle()');

/* Catalog */
SELECT app.assert_function_exists('catalog.assert_item_kind(uuid,catalog.item_kind)');
SELECT app.assert_function_exists('catalog.validate_subtype_kind()');

/* Definition */
SELECT app.assert_function_exists('definition.effective_inventory_version(uuid)');
SELECT app.assert_function_exists('definition.prevent_finalized_version_mutation()');
SELECT app.assert_function_exists('definition.prevent_finalized_graph_mutation()');
SELECT app.assert_function_exists('definition.validate_authority()');
SELECT app.assert_function_exists('definition.validate_inventory_version_source_identity()');
SELECT app.assert_function_exists('definition.validate_inventory_finalization()');

/* Collection */
SELECT app.assert_function_exists('collection.validate_storage_allocation()');
SELECT app.assert_function_exists('collection.explicit_part_balance(uuid,uuid)');
SELECT app.assert_function_exists('collection.validate_instance_definition()');
SELECT app.assert_function_exists('collection.validate_instance_adjustment()');
SELECT app.assert_function_exists('collection.validate_acquisition_item()');
SELECT app.assert_function_exists('collection.validate_entry_tag()');
SELECT app.assert_function_exists('collection.validate_transfer()');
SELECT app.assert_function_exists('collection.prevent_transfer_mutation()');

/* Wanted */
SELECT app.assert_function_exists('wanted.build_goal_requirements(uuid)');
SELECT app.assert_function_exists('wanted.build_goal_summary(uuid)');
SELECT app.assert_function_exists('wanted.validate_wishlist_entry_version()');
SELECT app.assert_function_exists('wanted.validate_reservation_capacity()');
SELECT app.assert_function_exists('wanted.validate_build_goal()');
SELECT app.assert_function_exists('wanted.validate_build_allocation()');

/* MOC */
SELECT app.assert_function_exists('moc.prevent_published_revision_mutation()');
SELECT app.assert_function_exists('moc.validate_fork()');
SELECT app.assert_function_exists('moc.validate_revision_integrity()');

/* Import */
SELECT app.assert_function_exists('import.reject_rebrickable_moc_staging()');
SELECT app.assert_function_exists('import.complete_source_run(uuid,jsonb)');
SELECT app.assert_function_exists('import.validate_normalized_record_job()');
SELECT app.assert_function_exists('import.validate_application_actor()');

/* Audit */
SELECT app.assert_function_exists('audit.prevent_mutation()');
SELECT app.assert_function_exists('audit.capture_row_change()');

/* Exact-ID UNLISTED access */
SELECT app.assert_function_exists('api.get_moc_by_id(uuid)');
SELECT app.assert_function_exists('api.get_moc_revisions(uuid)');
SELECT app.assert_function_exists('api.get_moc_assets(uuid,uuid)');
SELECT app.assert_function_exists('api.get_moc_licenses(uuid,uuid)');
SELECT app.assert_function_exists('api.get_moc_subassemblies(uuid,uuid)');


/* Critical trigger inventory */
DO $$
DECLARE
    v_trigger text;
BEGIN
    FOREACH v_trigger IN ARRAY ARRAY[
        'trg_validate_guardianship',
        'trg_validate_theme_cycle',
        'trg_validate_category_cycle',
        'trg_validate_storage_cycle',
        'trg_validate_subassembly_cycle',
        'trg_inventory_version_immutable',
        'trg_requirement_groups_immutable',
        'trg_requirement_options_immutable',
        'trg_definition_authority_validate',
        'trg_validate_storage_allocation',
        'trg_moc_published_revision_immutable',
        'trg_validate_moc_fork',
        'trg_reject_rebrickable_mocs',
        'trg_audit_events_append_only',
        'trg_audit_changes_append_only',
        'trg_inventory_version_source_identity',
        'trg_inventory_version_finalize_graph',
        'trg_validate_collection_instance_definition',
        'trg_validate_instance_adjustment',
        'trg_validate_acquisition_item',
        'trg_validate_entry_tag',
        'trg_validate_transfer',
        'trg_transfers_immutable',
        'trg_validate_wishlist_entry_version',
        'trg_validate_wishlist_reservation_capacity',
        'trg_validate_build_goal',
        'trg_validate_build_allocation',
        'trg_validate_moc_revision_integrity',
        'trg_validate_normalized_record_job',
        'trg_validate_import_application_actor'
    ]
    LOOP
        PERFORM app.assert_true(
            EXISTS (
                SELECT 1
                FROM pg_trigger
                WHERE tgname = v_trigger
                  AND NOT tgisinternal
            ),
            format('Required trigger "%s" is missing', v_trigger)
        );
    END LOOP;
END;
$$;


/* All fourteen catalog subtype triggers. */
SELECT app.assert_true(
    (
        SELECT count(*)
        FROM pg_trigger
        WHERE tgname IN (
            'trg_catalog_sets_kind',
            'trg_catalog_parts_kind',
            'trg_catalog_minifigures_kind',
            'trg_catalog_books_kind',
            'trg_catalog_mocs_kind',
            'trg_catalog_sticker_sheets_kind',
            'trg_catalog_instructions_kind',
            'trg_catalog_packaging_kind',
            'trg_catalog_gear_kind',
            'trg_catalog_accessories_kind',
            'trg_catalog_polybags_kind',
            'trg_catalog_promotional_items_kind',
            'trg_catalog_publications_kind',
            'trg_catalog_other_kind'
        )
          AND NOT tgisinternal
    ) = 14,
    'One or more catalog subtype validation triggers are missing'
);


/* Audit trigger argument regression: family permissions use family_membership_id. */
SELECT app.assert_true(
    EXISTS (
        SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'identity'
          AND c.relname = 'family_member_permissions'
          AND t.tgname = 'trg_audit_family_permissions'
          AND NOT t.tgisinternal
    ),
    'Family-permission audit trigger is missing'
);

\echo '[VALIDATE PASS] 1210_function_validation.sql'
SELECT pg_temp.bt_mark_completed('1200_validation/1210_function_validation.sql');
