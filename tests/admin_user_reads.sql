\set ON_ERROR_STOP on
\pset pager off
\pset tuples_only off

\echo '=============================================================================='
\echo ' BrickTrackr Admin User Read Procedure Verification'
\echo '=============================================================================='

\set test_user_id '01a05226-ded3-7703-9107-5026a034a4ea'
\set test_username 'test.user2'
\set test_email 'test.user2@example.com'
\set test_display_name 'Test User Two'
\set test_status 'ACTIVE'
\set test_management_type 'MANAGED_CHILD'

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

\echo ''
\echo '[RUN ] 1/7 admin.get_user(UUID)'

CALL admin.get_user(
    p_user_id => :'test_user_id'::uuid,
    p_result  => NULL
)
\gset get_user_

SELECT pg_temp.bt_assert(
    (:'get_user_p_result'::jsonb ->> 'user_id') = :'test_user_id',
    'admin.get_user returned the wrong user_id'
);
SELECT pg_temp.bt_assert(
    (:'get_user_p_result'::jsonb ->> 'username') = :'test_username',
    'admin.get_user returned the wrong username'
);
SELECT pg_temp.bt_assert(
    (:'get_user_p_result'::jsonb ->> 'email') = :'test_email',
    'admin.get_user returned the wrong email'
);
SELECT pg_temp.bt_assert(
    (:'get_user_p_result'::jsonb ->> 'display_name') = :'test_display_name',
    'admin.get_user returned the wrong display_name'
);
SELECT pg_temp.bt_assert(
    (:'get_user_p_result'::jsonb ->> 'account_status') = :'test_status',
    'admin.get_user returned the wrong account_status'
);
SELECT pg_temp.bt_assert(
    (:'get_user_p_result'::jsonb ->> 'account_management_type') = :'test_management_type',
    'admin.get_user returned the wrong account_management_type'
);
SELECT pg_temp.bt_assert(
    (:'get_user_p_result'::jsonb -> 'archived_at') = 'null'::jsonb,
    'admin.get_user expected archived_at to be null'
);

\echo '[PASS] admin.get_user(UUID)'

\echo ''
\echo '[RUN ] 2/7 admin.get_user_by_username(TEXT)'

CALL admin.get_user_by_username(
    p_username => :'test_username',
    p_result   => NULL
)
\gset get_username_

SELECT pg_temp.bt_assert(
    (:'get_username_p_result'::jsonb ->> 'user_id') = :'test_user_id',
    'admin.get_user_by_username returned the wrong user_id'
);
SELECT pg_temp.bt_assert(
    (:'get_username_p_result'::jsonb ->> 'username') = :'test_username',
    'admin.get_user_by_username returned the wrong username'
);
SELECT pg_temp.bt_assert(
    (:'get_username_p_result'::jsonb ->> 'account_status') = :'test_status',
    'admin.get_user_by_username returned the wrong account_status'
);
SELECT pg_temp.bt_assert(
    (:'get_username_p_result'::jsonb ->> 'account_management_type') = :'test_management_type',
    'admin.get_user_by_username returned the wrong account_management_type'
);

\echo '[PASS] admin.get_user_by_username(TEXT)'

\echo ''
\echo '[RUN ] 3/7 admin.get_user_by_email(TEXT)'

CALL admin.get_user_by_email(
    p_email  => :'test_email',
    p_result => NULL
)
\gset get_email_

SELECT pg_temp.bt_assert(
    (:'get_email_p_result'::jsonb ->> 'user_id') = :'test_user_id',
    'admin.get_user_by_email returned the wrong user_id'
);
SELECT pg_temp.bt_assert(
    (:'get_email_p_result'::jsonb ->> 'email') = :'test_email',
    'admin.get_user_by_email returned the wrong email'
);
SELECT pg_temp.bt_assert(
    (:'get_email_p_result'::jsonb ->> 'display_name') = :'test_display_name',
    'admin.get_user_by_email returned the wrong display_name'
);

\echo '[PASS] admin.get_user_by_email(TEXT)'

\echo ''
\echo '[RUN ] 4/7 admin.list_users() default contract'

CALL admin.list_users(
    p_result => NULL
)
\gset list_default_

SELECT pg_temp.bt_assert(
    pg_catalog.jsonb_typeof(:'list_default_p_result'::jsonb) = 'object',
    'admin.list_users default result is not a JSON object'
);
SELECT pg_temp.bt_assert(
    pg_catalog.jsonb_typeof(:'list_default_p_result'::jsonb -> 'users') = 'array',
    'admin.list_users default result.users is not a JSON array'
);
SELECT pg_temp.bt_assert(
    (:'list_default_p_result'::jsonb ->> 'limit')::integer = 100,
    'admin.list_users default limit is not 100'
);
SELECT pg_temp.bt_assert(
    (:'list_default_p_result'::jsonb ->> 'offset')::integer = 0,
    'admin.list_users default offset is not 0'
);
SELECT pg_temp.bt_assert(
    (:'list_default_p_result'::jsonb ->> 'total')::bigint >=
    pg_catalog.jsonb_array_length(:'list_default_p_result'::jsonb -> 'users'),
    'admin.list_users total is smaller than the returned page'
);

\echo '[PASS] admin.list_users() default contract'

\echo ''
\echo '[RUN ] 5/7 admin.list_users() search by username and email'

CALL admin.list_users(
    p_search           => :'test_username',
    p_include_archived => false,
    p_limit            => 100,
    p_offset           => 0,
    p_result           => NULL
)
\gset list_username_

SELECT pg_temp.bt_assert(
    EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_array_elements(
            :'list_username_p_result'::jsonb -> 'users'
        ) AS x(user_json)
        WHERE x.user_json ->> 'user_id' = :'test_user_id'
    ),
    'admin.list_users username search did not return the known user'
);

CALL admin.list_users(
    p_search           => :'test_email',
    p_include_archived => false,
    p_limit            => 100,
    p_offset           => 0,
    p_result           => NULL
)
\gset list_email_

SELECT pg_temp.bt_assert(
    EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_array_elements(
            :'list_email_p_result'::jsonb -> 'users'
        ) AS x(user_json)
        WHERE x.user_json ->> 'user_id' = :'test_user_id'
    ),
    'admin.list_users email search did not return the known user'
);

\echo '[PASS] admin.list_users() search by username and email'

\echo ''
\echo '[RUN ] 6/7 admin.list_users() status and management-type filters'

CALL admin.list_users(
    p_management_type  => :'test_management_type'::identity.account_management_type,
    p_status           => :'test_status'::identity.account_status,
    p_search           => :'test_username',
    p_include_archived => false,
    p_limit            => 100,
    p_offset           => 0,
    p_result           => NULL
)
\gset list_filtered_

SELECT pg_temp.bt_assert(
    (:'list_filtered_p_result'::jsonb ->> 'total')::bigint = 1,
    'admin.list_users combined filters expected exactly one matching test user'
);
SELECT pg_temp.bt_assert(
    pg_catalog.jsonb_array_length(:'list_filtered_p_result'::jsonb -> 'users') = 1,
    'admin.list_users combined filters expected exactly one returned user'
);
SELECT pg_temp.bt_assert(
    :'list_filtered_p_result'::jsonb -> 'users' -> 0 ->> 'user_id' = :'test_user_id',
    'admin.list_users combined filters returned the wrong user'
);
SELECT pg_temp.bt_assert(
    :'list_filtered_p_result'::jsonb -> 'users' -> 0 ->> 'account_status' = :'test_status',
    'admin.list_users status filter returned the wrong account_status'
);
SELECT pg_temp.bt_assert(
    :'list_filtered_p_result'::jsonb -> 'users' -> 0 ->> 'account_management_type' = :'test_management_type',
    'admin.list_users management-type filter returned the wrong account_management_type'
);

\echo '[PASS] admin.list_users() status and management-type filters'

\echo ''
\echo '[RUN ] 7/7 admin.list_users() pagination'

CALL admin.list_users(
    p_search           => :'test_username',
    p_include_archived => false,
    p_limit            => 1,
    p_offset           => 0,
    p_result           => NULL
)
\gset page_zero_

SELECT pg_temp.bt_assert(
    (:'page_zero_p_result'::jsonb ->> 'total')::bigint = 1,
    'admin.list_users pagination expected total=1 for the unique username search'
);
SELECT pg_temp.bt_assert(
    (:'page_zero_p_result'::jsonb ->> 'limit')::integer = 1,
    'admin.list_users pagination did not preserve limit=1'
);
SELECT pg_temp.bt_assert(
    (:'page_zero_p_result'::jsonb ->> 'offset')::integer = 0,
    'admin.list_users pagination did not preserve offset=0'
);
SELECT pg_temp.bt_assert(
    pg_catalog.jsonb_array_length(:'page_zero_p_result'::jsonb -> 'users') = 1,
    'admin.list_users first page expected one user'
);

CALL admin.list_users(
    p_search           => :'test_username',
    p_include_archived => false,
    p_limit            => 1,
    p_offset           => 1,
    p_result           => NULL
)
\gset page_one_

SELECT pg_temp.bt_assert(
    (:'page_one_p_result'::jsonb ->> 'total')::bigint = 1,
    'admin.list_users pagination total changed across pages'
);
SELECT pg_temp.bt_assert(
    (:'page_one_p_result'::jsonb ->> 'offset')::integer = 1,
    'admin.list_users pagination did not preserve offset=1'
);
SELECT pg_temp.bt_assert(
    pg_catalog.jsonb_array_length(:'page_one_p_result'::jsonb -> 'users') = 0,
    'admin.list_users second page expected an empty users array'
);

\echo '[PASS] admin.list_users() pagination'

DROP FUNCTION pg_temp.bt_assert(boolean, text);

\echo ''
\echo '=============================================================================='
\echo '[PASS] Admin user read procedure verification completed successfully.'
\echo '=============================================================================='
