\set ON_ERROR_STOP on
\pset pager off
\pset tuples_only off

\echo '==============================================================================='
\echo ' BrickTrackr Admin User Write / Lifecycle Regression Verification'
\echo '==============================================================================='
\echo ''
\echo '[INFO] All mutations execute inside one transaction and are rolled back.'
\echo '[INFO] No persistent test user or audit records should remain after PASS.'

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.bt_assert(
    p_condition boolean,
    p_message text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT COALESCE(p_condition, false) THEN
        RAISE EXCEPTION '[FAIL] %', p_message;
    END IF;
END;
$$;

-- Generate a transaction-unique identity for the disposable test user.
SELECT
    'bt.write.' || pg_catalog.txid_current()::text AS test_username,
    'bt.write.' || pg_catalog.txid_current()::text || '@example.invalid' AS test_email
\gset

\set test_display_name 'BrickTrackr Write Test'
\set test_display_name_updated 'BrickTrackr Write Test Updated'

\echo ''
\echo '[RUN ] 1/7 admin.create_user + INSERT audit'

CALL admin.create_user(
    p_username     => :'test_username',
    p_display_name => :'test_display_name',
    p_email        => :'test_email',
    p_result       => NULL
)
\gset create_

SELECT
    :'create_p_result'::jsonb ->> 'user_id' AS test_user_id
\gset

SELECT pg_temp.bt_assert(
    NULLIF(:'test_user_id', '') IS NOT NULL,
    'admin.create_user did not return user_id'
);

SELECT pg_temp.bt_assert(
    :'create_p_result'::jsonb ->> 'username' = :'test_username',
    'admin.create_user returned the wrong username'
);

SELECT pg_temp.bt_assert(
    :'create_p_result'::jsonb ->> 'display_name' = :'test_display_name',
    'admin.create_user returned the wrong display_name'
);

SELECT pg_temp.bt_assert(
    :'create_p_result'::jsonb ->> 'email' = :'test_email',
    'admin.create_user returned the wrong email'
);

SELECT pg_temp.bt_assert(
    :'create_p_result'::jsonb ->> 'account_status' = 'ACTIVE',
    'admin.create_user expected account_status ACTIVE'
);

SELECT pg_temp.bt_assert(
    :'create_p_result'::jsonb ->> 'account_management_type' = 'INDEPENDENT',
    'admin.create_user expected account_management_type INDEPENDENT'
);

CALL admin.list_audit_events(
    p_entity_schema => 'identity',
    p_entity_table  => 'users',
    p_entity_id     => :'test_user_id',
    p_limit         => 100,
    p_offset        => 0,
    p_result        => NULL
)
\gset audit_create_

SELECT pg_temp.bt_assert(
    (:'audit_create_p_result'::jsonb ->> 'total')::bigint = 1,
    'CREATE expected exactly one audit event'
);

SELECT pg_temp.bt_assert(
    :'audit_create_p_result'::jsonb -> 'events' -> 0 ->> 'event_type' = 'INSERT',
    'CREATE audit event_type is not INSERT'
);

SELECT pg_temp.bt_assert(
    :'audit_create_p_result'::jsonb -> 'events' -> 0 -> 'metadata' ->> 'operation' = 'admin.create_user',
    'CREATE audit metadata.operation is incorrect'
);

SELECT pg_temp.bt_assert(
    :'audit_create_p_result'::jsonb -> 'events' -> 0 ->> 'actor_class' = 'ADMIN',
    'CREATE audit actor_class is not ADMIN'
);

SELECT pg_temp.bt_assert(
    NOT EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_array_elements(
            :'audit_create_p_result'::jsonb -> 'events' -> 0 -> 'changes'
        ) AS c(change_json)
        WHERE c.change_json ->> 'field_name' IN (
            'archived_at',
            'date_of_birth',
            'locale',
            'timezone_name'
        )
    ),
    'CREATE audit contains null-only change noise'
);

\echo '[PASS] admin.create_user + INSERT audit'

\echo ''
\echo '[RUN ] 2/7 admin.update_user + single-field UPDATE audit'

CALL admin.update_user(
    p_user_id => :'test_user_id'::uuid,
    p_patch   => pg_catalog.jsonb_build_object(
        'display_name',
        :'test_display_name_updated'
    ),
    p_result  => NULL
)
\gset update_

SELECT pg_temp.bt_assert(
    :'update_p_result'::jsonb ->> 'display_name' = :'test_display_name_updated',
    'admin.update_user did not update display_name'
);

CALL admin.list_audit_events(
    p_entity_schema => 'identity',
    p_entity_table  => 'users',
    p_entity_id     => :'test_user_id',
    p_limit         => 100,
    p_offset        => 0,
    p_result        => NULL
)
\gset audit_update_

SELECT pg_temp.bt_assert(
    (:'audit_update_p_result'::jsonb ->> 'total')::bigint = 2,
    'UPDATE expected two total audit events'
);

SELECT pg_temp.bt_assert(
    :'audit_update_p_result'::jsonb -> 'events' -> 0 -> 'metadata' ->> 'operation' = 'admin.update_user',
    'UPDATE audit metadata.operation is incorrect'
);

SELECT pg_temp.bt_assert(
    pg_catalog.jsonb_array_length(
        :'audit_update_p_result'::jsonb -> 'events' -> 0 -> 'changes'
    ) = 1,
    'UPDATE expected exactly one audit change'
);

SELECT pg_temp.bt_assert(
    :'audit_update_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'field_name' = 'display_name',
    'UPDATE audit changed unexpected field'
);

SELECT pg_temp.bt_assert(
    :'audit_update_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'old_value' = :'test_display_name',
    'UPDATE audit old display_name is incorrect'
);

SELECT pg_temp.bt_assert(
    :'audit_update_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'new_value' = :'test_display_name_updated',
    'UPDATE audit new display_name is incorrect'
);

\echo '[PASS] admin.update_user + single-field UPDATE audit'

\echo ''
\echo '[RUN ] 3/7 admin.set_user_status ACTIVE -> LOCKED -> ACTIVE'

CALL admin.set_user_status(
    p_user_id => :'test_user_id'::uuid,
    p_status  => 'LOCKED'::identity.account_status,
    p_result  => NULL
)
\gset status_locked_

SELECT pg_temp.bt_assert(
    :'status_locked_p_result'::jsonb ->> 'account_status' = 'LOCKED',
    'admin.set_user_status did not set LOCKED'
);

CALL admin.list_audit_events(
    p_entity_schema => 'identity',
    p_entity_table  => 'users',
    p_entity_id     => :'test_user_id',
    p_limit         => 1,
    p_offset        => 0,
    p_result        => NULL
)
\gset audit_locked_

SELECT pg_temp.bt_assert(
    :'audit_locked_p_result'::jsonb -> 'events' -> 0 -> 'metadata' ->> 'operation' = 'admin.set_user_status',
    'LOCKED audit metadata.operation is incorrect'
);

SELECT pg_temp.bt_assert(
    pg_catalog.jsonb_array_length(
        :'audit_locked_p_result'::jsonb -> 'events' -> 0 -> 'changes'
    ) = 1,
    'LOCKED expected exactly one audit change'
);

SELECT pg_temp.bt_assert(
    :'audit_locked_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'field_name' = 'account_status'
    AND :'audit_locked_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'old_value' = 'ACTIVE'
    AND :'audit_locked_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'new_value' = 'LOCKED',
    'LOCKED audit delta is incorrect'
);

CALL admin.set_user_status(
    p_user_id => :'test_user_id'::uuid,
    p_status  => 'ACTIVE'::identity.account_status,
    p_result  => NULL
)
\gset status_active_

SELECT pg_temp.bt_assert(
    :'status_active_p_result'::jsonb ->> 'account_status' = 'ACTIVE',
    'admin.set_user_status did not restore ACTIVE'
);

CALL admin.list_audit_events(
    p_entity_schema => 'identity',
    p_entity_table  => 'users',
    p_entity_id     => :'test_user_id',
    p_limit         => 1,
    p_offset        => 0,
    p_result        => NULL
)
\gset audit_active_

SELECT pg_temp.bt_assert(
    :'audit_active_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'field_name' = 'account_status'
    AND :'audit_active_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'old_value' = 'LOCKED'
    AND :'audit_active_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'new_value' = 'ACTIVE',
    'ACTIVE restore audit delta is incorrect'
);

\echo '[PASS] admin.set_user_status ACTIVE -> LOCKED -> ACTIVE'

\echo ''
\echo '[RUN ] 4/7 admin.set_user_management_type'

CALL admin.set_user_management_type(
    p_user_id         => :'test_user_id'::uuid,
    p_management_type => 'MANAGED_CHILD'::identity.account_management_type,
    p_result          => NULL
)
\gset management_

SELECT pg_temp.bt_assert(
    :'management_p_result'::jsonb ->> 'account_management_type' = 'MANAGED_CHILD',
    'admin.set_user_management_type did not set MANAGED_CHILD'
);

CALL admin.list_audit_events(
    p_entity_schema => 'identity',
    p_entity_table  => 'users',
    p_entity_id     => :'test_user_id',
    p_limit         => 1,
    p_offset        => 0,
    p_result        => NULL
)
\gset audit_management_

SELECT pg_temp.bt_assert(
    :'audit_management_p_result'::jsonb -> 'events' -> 0 -> 'metadata' ->> 'operation' = 'admin.set_user_management_type',
    'management-type audit metadata.operation is incorrect'
);

SELECT pg_temp.bt_assert(
    pg_catalog.jsonb_array_length(
        :'audit_management_p_result'::jsonb -> 'events' -> 0 -> 'changes'
    ) = 1,
    'management-type change expected exactly one audit delta'
);

SELECT pg_temp.bt_assert(
    :'audit_management_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'field_name' = 'account_management_type'
    AND :'audit_management_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'old_value' = 'INDEPENDENT'
    AND :'audit_management_p_result'::jsonb -> 'events' -> 0 -> 'changes' -> 0 ->> 'new_value' = 'MANAGED_CHILD',
    'management-type audit delta is incorrect'
);

\echo '[PASS] admin.set_user_management_type'

\echo ''
\echo '[RUN ] 5/7 admin.delete_user soft-delete lifecycle'

CALL admin.delete_user(
    p_user_id => :'test_user_id'::uuid,
    p_result  => NULL
)
\gset delete_

SELECT pg_temp.bt_assert(
    :'delete_p_result'::jsonb ->> 'account_status' = 'ARCHIVED',
    'admin.delete_user did not set account_status ARCHIVED'
);

SELECT pg_temp.bt_assert(
    :'delete_p_result'::jsonb -> 'archived_at' IS DISTINCT FROM 'null'::jsonb,
    'admin.delete_user did not populate archived_at'
);

CALL admin.list_audit_events(
    p_entity_schema => 'identity',
    p_entity_table  => 'users',
    p_entity_id     => :'test_user_id',
    p_limit         => 1,
    p_offset        => 0,
    p_result        => NULL
)
\gset audit_delete_

SELECT pg_temp.bt_assert(
    :'audit_delete_p_result'::jsonb -> 'events' -> 0 -> 'metadata' ->> 'operation' = 'admin.delete_user',
    'soft-delete audit metadata.operation is incorrect'
);

SELECT pg_temp.bt_assert(
    EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_array_elements(
            :'audit_delete_p_result'::jsonb -> 'events' -> 0 -> 'changes'
        ) AS c(change_json)
        WHERE c.change_json ->> 'field_name' = 'account_status'
          AND c.change_json ->> 'old_value' = 'ACTIVE'
          AND c.change_json ->> 'new_value' = 'ARCHIVED'
    ),
    'soft-delete audit missing ACTIVE -> ARCHIVED delta'
);

SELECT pg_temp.bt_assert(
    EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_array_elements(
            :'audit_delete_p_result'::jsonb -> 'events' -> 0 -> 'changes'
        ) AS c(change_json)
        WHERE c.change_json ->> 'field_name' = 'archived_at'
          AND c.change_json -> 'old_value' = 'null'::jsonb
          AND c.change_json -> 'new_value' IS DISTINCT FROM 'null'::jsonb
    ),
    'soft-delete audit missing archived_at delta'
);

\echo '[PASS] admin.delete_user soft-delete lifecycle'

\echo ''
\echo '[RUN ] 6/7 admin.restore_user lifecycle'

CALL admin.restore_user(
    p_user_id => :'test_user_id'::uuid,
    p_result  => NULL
)
\gset restore_

SELECT pg_temp.bt_assert(
    :'restore_p_result'::jsonb ->> 'account_status' = 'ACTIVE',
    'admin.restore_user did not restore account_status ACTIVE'
);

SELECT pg_temp.bt_assert(
    :'restore_p_result'::jsonb -> 'archived_at' = 'null'::jsonb,
    'admin.restore_user did not clear archived_at'
);

CALL admin.list_audit_events(
    p_entity_schema => 'identity',
    p_entity_table  => 'users',
    p_entity_id     => :'test_user_id',
    p_limit         => 1,
    p_offset        => 0,
    p_result        => NULL
)
\gset audit_restore_

SELECT pg_temp.bt_assert(
    :'audit_restore_p_result'::jsonb -> 'events' -> 0 -> 'metadata' ->> 'operation' = 'admin.restore_user',
    'restore audit metadata.operation is incorrect'
);

SELECT pg_temp.bt_assert(
    EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_array_elements(
            :'audit_restore_p_result'::jsonb -> 'events' -> 0 -> 'changes'
        ) AS c(change_json)
        WHERE c.change_json ->> 'field_name' = 'account_status'
          AND c.change_json ->> 'old_value' = 'ARCHIVED'
          AND c.change_json ->> 'new_value' = 'ACTIVE'
    ),
    'restore audit missing ARCHIVED -> ACTIVE delta'
);

SELECT pg_temp.bt_assert(
    EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_array_elements(
            :'audit_restore_p_result'::jsonb -> 'events' -> 0 -> 'changes'
        ) AS c(change_json)
        WHERE c.change_json ->> 'field_name' = 'archived_at'
          AND c.change_json -> 'old_value' IS DISTINCT FROM 'null'::jsonb
          AND c.change_json -> 'new_value' = 'null'::jsonb
    ),
    'restore audit missing archived_at clear delta'
);

\echo '[PASS] admin.restore_user lifecycle'

\echo ''
\echo '[RUN ] 7/7 complete lifecycle audit sequence'

CALL admin.list_audit_events(
    p_entity_schema => 'identity',
    p_entity_table  => 'users',
    p_entity_id     => :'test_user_id',
    p_limit         => 100,
    p_offset        => 0,
    p_result        => NULL
)
\gset audit_final_

SELECT pg_temp.bt_assert(
    (:'audit_final_p_result'::jsonb ->> 'total')::bigint = 7,
    'complete lifecycle expected exactly seven audit events'
);

SELECT pg_temp.bt_assert(
    (
        SELECT pg_catalog.jsonb_agg(e.event_json -> 'metadata' ->> 'operation' ORDER BY e.ordinality)
        FROM pg_catalog.jsonb_array_elements(
            :'audit_final_p_result'::jsonb -> 'events'
        ) WITH ORDINALITY AS e(event_json, ordinality)
    ) =
    '[
        "admin.restore_user",
        "admin.delete_user",
        "admin.set_user_management_type",
        "admin.set_user_status",
        "admin.set_user_status",
        "admin.update_user",
        "admin.create_user"
    ]'::jsonb,
    'audit event ordering or lifecycle operation sequence is incorrect'
);

\echo '[PASS] complete lifecycle audit sequence'

DROP FUNCTION pg_temp.bt_assert(boolean, text);

ROLLBACK;

\echo ''
\echo '==============================================================================='
\echo '[PASS] Admin user write/lifecycle regression verification completed successfully.'
\echo '[PASS] Transaction rolled back; no test data was persisted.'
\echo '==============================================================================='
