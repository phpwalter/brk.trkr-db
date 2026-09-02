/*
===============================================================================
 File:           5000_function/5200_api/5281_api_admin_finance_actor.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Preserve ADMIN database request-context separation while
                 accepting an explicitly authenticated BrickTrackr administrator
                 actor for operations that require durable user attribution.
 Depends On:     5000_function/5200_api/5280_api_admin_finance.sql
                 5000_function/5100_admin/5131_admin_finance_actor.sql
                 admin.assert_system_admin()
                 identity.users
                 identity.owners
                 reference.external_sources
                 catalog.items
                 catalog.admin_overrides
                 import.jobs
                 finance.transactions
                 finance.ledger_entries
 Creates:        api.admin_finance_actor_operation()
 Key Rules:      HTTP administrator authorization and brktrkr_admin database
                 capability are both required. ADMIN actor_class remains free of
                 app.current_user_id; p_actor_user_id is explicit attribution,
                 not request-context authentication. All unaffected operations
                 delegate to the existing administrator dispatcher.
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5281_api_admin_finance_actor.sql',
    ARRAY[
        '5000_function/5200_api/5280_api_admin_finance.sql',
        '5000_function/5100_admin/5131_admin_finance_actor.sql',
        'admin.assert_system_admin()',
        'identity.users',
        'identity.owners',
        'reference.external_sources',
        'catalog.items',
        'catalog.admin_overrides',
        'import.jobs',
        'finance.transactions',
        'finance.ledger_entries'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.admin_finance_actor_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb,
    p_body jsonb DEFAULT '{}'::jsonb,
    p_actor_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, admin, identity, reference, catalog, import, finance
AS $$
DECLARE
    v_source_id smallint;
    v_job_id uuid;
    v_catalog_id uuid;
    v_override_id uuid;
    v_transaction_id uuid;
    v_result jsonb;
BEGIN
    PERFORM admin.assert_system_admin();

    IF p_actor_user_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM identity.users u
        WHERE u.user_id = p_actor_user_id
          AND u.account_status <> 'ARCHIVED'
    ) THEN
        RAISE EXCEPTION 'A valid BrickTrackr administrator actor is required'
            USING ERRCODE='42501';
    END IF;

    CASE p_operation
    WHEN 'create_import_job' THEN
        SELECT source_id
          INTO v_source_id
          FROM reference.external_sources
         WHERE source_code = upper(p_body->>'source')
            OR source_name = p_body->>'source'
         LIMIT 1;

        IF v_source_id IS NULL THEN
            RAISE EXCEPTION 'External source not found' USING ERRCODE='P0404';
        END IF;

        INSERT INTO import.jobs(
            source_id,
            owner_id,
            initiated_by_user_id,
            apply_mode,
            status,
            source_filename
        )
        VALUES(
            v_source_id,
            (SELECT owner_id
               FROM identity.owners
              WHERE owner_type='USER'
                AND user_id=p_actor_user_id),
            p_actor_user_id,
            CASE lower(COALESCE(p_body->>'mode','merge'))
                WHEN 'replace' THEN 'REPLACE'::import.apply_mode
                ELSE 'MERGE'::import.apply_mode
            END,
            'CREATED',
            p_body->>'source_filename'
        )
        RETURNING import_job_id INTO v_job_id;

        SELECT to_jsonb(j)
          INTO v_result
          FROM import.jobs j
         WHERE j.import_job_id=v_job_id;

    WHEN 'set_catalog_override' THEN
        SELECT catalog_item_id
          INTO v_catalog_id
          FROM catalog.items
         WHERE item_num=NULLIF(p_params->>'item_num','');

        IF v_catalog_id IS NULL THEN
            RAISE EXCEPTION 'Catalog item not found' USING ERRCODE='P0404';
        END IF;

        IF COALESCE((p_body->>'clear')::boolean,false) THEN
            UPDATE catalog.admin_overrides
               SET cleared_at=now(),
                   cleared_by_user_id=p_actor_user_id
             WHERE catalog_item_id=v_catalog_id
               AND field_name=p_body->>'field'
               AND cleared_at IS NULL;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Active override not found' USING ERRCODE='P0404';
            END IF;

            v_result:=jsonb_build_object(
                'cleared',true,
                'field',p_body->>'field'
            );
        ELSE
            UPDATE catalog.admin_overrides
               SET cleared_at=now(),
                   cleared_by_user_id=p_actor_user_id
             WHERE catalog_item_id=v_catalog_id
               AND field_name=p_body->>'field'
               AND cleared_at IS NULL;

            INSERT INTO catalog.admin_overrides(
                catalog_item_id,
                field_name,
                override_value,
                reason,
                created_by_user_id
            )
            VALUES(
                v_catalog_id,
                p_body->>'field',
                p_body->'value',
                COALESCE(NULLIF(p_body->>'reason',''),'API administrator override'),
                p_actor_user_id
            )
            RETURNING admin_override_id INTO v_override_id;

            SELECT to_jsonb(o)
              INTO v_result
              FROM catalog.admin_overrides o
             WHERE o.admin_override_id=v_override_id;
        END IF;

    WHEN 'append_ledger_entry' THEN
        v_transaction_id:=admin.post_financial_transaction(
            p_body->>'idempotency_key',
            (p_body->>'currency')::app.currency_code,
            p_body->>'description',
            p_body->'entries',
            NULLIF(p_body->>'order_id','')::uuid,
            p_actor_user_id
        );

        SELECT jsonb_build_object(
            'transaction',to_jsonb(t),
            'entries',COALESCE((
                SELECT jsonb_agg(to_jsonb(le) ORDER BY le.financial_ledger_entry_id)
                  FROM finance.ledger_entries le
                 WHERE le.financial_transaction_id=t.financial_transaction_id
            ),'[]'::jsonb)
        )
        INTO v_result
        FROM finance.transactions t
        WHERE t.financial_transaction_id=v_transaction_id;

    ELSE
        v_result:=api.admin_finance_operation(
            p_operation,
            p_params,
            p_body
        );
    END CASE;

    RETURN COALESCE(v_result,'null'::jsonb);
END;
$$;

ALTER FUNCTION api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)
OWNER TO brktrkr_owner;

REVOKE ALL ON FUNCTION api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)
FROM PUBLIC;

COMMENT ON FUNCTION api.admin_finance_actor_operation(text,jsonb,jsonb,uuid)
IS
'Actor-aware administrator API dispatcher. Preserves ADMIN request context without app.current_user_id while explicitly attributing user-sensitive privileged operations to the authenticated BrickTrackr administrator.';

SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5281_api_admin_finance_actor.sql');
\echo '[PASS] 5281_api_admin_finance_actor.sql'
