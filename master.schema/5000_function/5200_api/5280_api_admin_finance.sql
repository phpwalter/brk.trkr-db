/*
===============================================================================
 File:           5000_function/5200_api/5280_api_admin_finance.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.3.0
 PostgreSQL:     16+
 Purpose:        Implement privileged import, catalog-administration, audit and
                 append-only finance endpoints through a database-admin-only API
                 routine.
 Depends On:     admin.assert_system_admin()
                 admin.set_catalog_item_image()
                 admin.remove_catalog_item_image()
                 admin.set_instruction_asset()
                 admin.remove_instruction_asset()
                 admin.post_financial_transaction()
                 identity.current_user_id_optional()
                 reference.external_sources
                 catalog.items
                 catalog.sets
                 catalog.parts
                 catalog.minifigures
                 catalog.mocs
                 catalog.admin_overrides
                 import.jobs
                 import.source_runs
                 audit.events
                 audit.changes
                 finance.transactions
                 finance.ledger_entries
                 finance.source_events
 Creates:        api.admin_finance_operation()
 Key Rules:      This function requires brktrkr_admin/brktrkr_owner database-role
                 authority in addition to HTTP-layer administrator authorization.
                 The normal brktrkr_api login cannot execute privileged mutations.
                 Financial posting delegates to the existing balanced,
                 idempotent, immutable ledger routine.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight(
    '5000_function/5200_api/5280_api_admin_finance.sql',
    ARRAY[
        'admin.assert_system_admin()',
        'admin.set_catalog_item_image()',
        'admin.remove_catalog_item_image()',
        'admin.set_instruction_asset()',
        'admin.remove_instruction_asset()',
        'admin.post_financial_transaction()',
        'identity.current_user_id_optional()',
        'reference.external_sources',
        'catalog.items',
        'catalog.sets',
        'catalog.parts',
        'catalog.minifigures',
        'catalog.mocs',
        'catalog.admin_overrides',
        'import.jobs',
        'import.source_runs',
        'audit.events',
        'audit.changes',
        'finance.transactions',
        'finance.ledger_entries',
        'finance.source_events'
    ]::text[]
);

CREATE OR REPLACE FUNCTION api.admin_finance_operation(
    p_operation text,
    p_params jsonb DEFAULT '{}'::jsonb,
    p_body jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, api, admin, identity, reference, catalog, import, audit, finance
AS $$
DECLARE
    v_item_num text := NULLIF(p_params->>'item_num','');
    v_catalog_id uuid;
    v_source_id smallint;
    v_job_id uuid;
    v_transaction_id uuid;
    v_override_id uuid;
    v_asset_id uuid;
    v_user uuid := identity.current_user_id_optional();
    v_limit integer := LEAST(GREATEST(COALESCE((p_params->>'limit')::integer,50),1),200);
    v_result jsonb;
    v_kind catalog.item_kind;
BEGIN
    PERFORM admin.assert_system_admin();

    CASE p_operation
    WHEN 'list_import_jobs' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(j) ORDER BY j.created_at DESC),'[]'::jsonb) INTO v_result
        FROM (SELECT * FROM import.jobs ORDER BY created_at DESC LIMIT v_limit) j;

    WHEN 'create_import_job' THEN
        SELECT source_id INTO v_source_id FROM reference.external_sources WHERE source_code=upper(p_body->>'source') OR source_name=p_body->>'source' LIMIT 1;
        IF v_source_id IS NULL THEN RAISE EXCEPTION 'External source not found' USING ERRCODE='P0404'; END IF;
        IF v_user IS NULL THEN RAISE EXCEPTION 'Administrative import-job creation requires an application user context' USING ERRCODE='P0403'; END IF;
        INSERT INTO import.jobs(source_id,owner_id,initiated_by_user_id,apply_mode,status,source_filename)
        VALUES(v_source_id,(SELECT owner_id FROM identity.owners WHERE owner_type='USER' AND user_id=v_user),v_user,
            CASE lower(COALESCE(p_body->>'mode','merge')) WHEN 'replace' THEN 'REPLACE'::import.apply_mode ELSE 'MERGE'::import.apply_mode END,
            'CREATED',p_body->>'source_filename') RETURNING import_job_id INTO v_job_id;
        SELECT to_jsonb(j) INTO v_result FROM import.jobs j WHERE j.import_job_id=v_job_id;

    WHEN 'get_import_job' THEN
        SELECT to_jsonb(j) INTO v_result FROM import.jobs j WHERE j.import_job_id=(p_params->>'import_job_id')::uuid;
        IF v_result IS NULL THEN RAISE EXCEPTION 'Import job not found' USING ERRCODE='P0404'; END IF;

    WHEN 'get_source_run' THEN
        SELECT to_jsonb(r) INTO v_result FROM import.source_runs r WHERE r.source_run_id=(p_params->>'source_run_id')::uuid;
        IF v_result IS NULL THEN RAISE EXCEPTION 'Source run not found' USING ERRCODE='P0404'; END IF;

    WHEN 'admin_create_catalog_item' THEN
        v_kind:=upper(p_body->>'item_kind')::catalog.item_kind;
        INSERT INTO catalog.items(item_kind,item_num,canonical_name,status)
        VALUES(v_kind,NULLIF(p_body->>'item_num',''),p_body->>'canonical_name',COALESCE(upper(NULLIF(p_body->>'status',''))::catalog.item_status,'ACTIVE'))
        RETURNING catalog_item_id,item_num INTO v_catalog_id,v_item_num;
        CASE v_kind
            WHEN 'SET' THEN
                INSERT INTO catalog.sets(catalog_item_id,lego_set_id,theme_id,release_year)
                VALUES(v_catalog_id,NULLIF(p_body#>>'{metadata,lego_set_id}','')::integer,NULLIF(p_body#>>'{metadata,theme_id}','')::integer,NULLIF(p_body#>>'{metadata,release_year}','')::smallint);
            WHEN 'PART' THEN
                INSERT INTO catalog.parts(catalog_item_id,lego_design_id,design_name,category_id)
                VALUES(v_catalog_id,NULLIF(p_body#>>'{metadata,lego_design_id}','')::bigint,p_body#>>'{metadata,design_name}',NULLIF(p_body#>>'{metadata,category_id}','')::integer);
            WHEN 'MINIFIGURE' THEN
                INSERT INTO catalog.minifigures(catalog_item_id,lego_minifig_id,theme_id)
                VALUES(v_catalog_id,NULLIF(p_body#>>'{metadata,lego_minifig_id}','')::integer,NULLIF(p_body#>>'{metadata,theme_id}','')::integer);
            WHEN 'MOC' THEN
                INSERT INTO catalog.mocs(catalog_item_id,discovery_summary) VALUES(v_catalog_id,p_body#>>'{metadata,discovery_summary}');
            ELSE
                RAISE EXCEPTION 'Generic admin creation currently requires a typed SET, PART, MINIFIGURE, or MOC resource' USING ERRCODE='22023';
        END CASE;
        v_result:=jsonb_build_object('item_num',v_item_num,'catalog_item_id',v_catalog_id,'item_kind',v_kind::text,'name',p_body->>'canonical_name');

    WHEN 'list_catalog_overrides' THEN
        SELECT catalog_item_id INTO v_catalog_id FROM catalog.items WHERE item_num=v_item_num;
        IF v_catalog_id IS NULL THEN RAISE EXCEPTION 'Catalog item not found' USING ERRCODE='P0404'; END IF;
        SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.created_at DESC),'[]'::jsonb) INTO v_result FROM catalog.admin_overrides o WHERE o.catalog_item_id=v_catalog_id;

    WHEN 'set_catalog_override' THEN
        SELECT catalog_item_id INTO v_catalog_id FROM catalog.items WHERE item_num=v_item_num;
        IF v_catalog_id IS NULL THEN RAISE EXCEPTION 'Catalog item not found' USING ERRCODE='P0404'; END IF;
        IF COALESCE((p_body->>'clear')::boolean,false) THEN
            UPDATE catalog.admin_overrides SET cleared_at=now(),cleared_by_user_id=v_user
            WHERE catalog_item_id=v_catalog_id AND field_name=p_body->>'field' AND cleared_at IS NULL;
            IF NOT FOUND THEN RAISE EXCEPTION 'Active override not found' USING ERRCODE='P0404'; END IF;
            v_result:=jsonb_build_object('cleared',true,'field',p_body->>'field');
        ELSE
            IF v_user IS NULL THEN RAISE EXCEPTION 'Administrator override requires application user context for attribution' USING ERRCODE='P0403'; END IF;
            UPDATE catalog.admin_overrides SET cleared_at=now(),cleared_by_user_id=v_user WHERE catalog_item_id=v_catalog_id AND field_name=p_body->>'field' AND cleared_at IS NULL;
            INSERT INTO catalog.admin_overrides(catalog_item_id,field_name,override_value,reason,created_by_user_id)
            VALUES(v_catalog_id,p_body->>'field',p_body->'value',COALESCE(NULLIF(p_body->>'reason',''),'API administrator override'),v_user)
            RETURNING admin_override_id INTO v_override_id;
            SELECT to_jsonb(o) INTO v_result FROM catalog.admin_overrides o WHERE o.admin_override_id=v_override_id;
        END IF;

    WHEN 'set_catalog_image' THEN
        SELECT catalog_item_id INTO v_catalog_id FROM catalog.items WHERE item_num=v_item_num;
        IF v_catalog_id IS NULL THEN RAISE EXCEPTION 'Catalog item not found' USING ERRCODE='P0404'; END IF;
        v_asset_id:=admin.set_catalog_item_image(v_catalog_id,p_body->>'storage_key',p_body->>'alt_text',COALESCE((p_body->>'is_primary')::boolean,false),CASE WHEN NULLIF(p_body->>'sha256','') IS NULL THEN NULL ELSE decode(p_body->>'sha256','hex') END);
        v_result:=jsonb_build_object('catalog_item_image_id',v_asset_id);

    WHEN 'remove_catalog_image' THEN
        IF NOT admin.remove_catalog_item_image((p_params->>'catalog_item_image_id')::uuid) THEN RAISE EXCEPTION 'Catalog image not found' USING ERRCODE='P0404'; END IF;
        v_result:=jsonb_build_object('removed',true,'catalog_item_image_id',p_params->>'catalog_item_image_id');

    WHEN 'set_instruction_asset' THEN
        SELECT catalog_item_id INTO v_catalog_id FROM catalog.items WHERE item_num=v_item_num AND item_kind='INSTRUCTIONS';
        IF v_catalog_id IS NULL THEN RAISE EXCEPTION 'Instruction catalog item not found' USING ERRCODE='P0404'; END IF;
        v_asset_id:=admin.set_instruction_asset(v_catalog_id,p_body->>'storage_key',p_body->>'language_code',NULLIF(p_body->>'booklet_number','')::smallint,CASE WHEN NULLIF(p_body->>'sha256','') IS NULL THEN NULL ELSE decode(p_body->>'sha256','hex') END,NULLIF(p_body->>'page_count','')::integer);
        v_result:=jsonb_build_object('instruction_asset_id',v_asset_id);

    WHEN 'remove_instruction_asset' THEN
        IF NOT admin.remove_instruction_asset((p_params->>'instruction_asset_id')::uuid) THEN RAISE EXCEPTION 'Instruction asset not found' USING ERRCODE='P0404'; END IF;
        v_result:=jsonb_build_object('removed',true,'instruction_asset_id',p_params->>'instruction_asset_id');

    WHEN 'list_audit_events' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'event_id',e.audit_event_id,'event_type',e.event_type,'actor_user_id',e.actor_user_id,'subject_user_id',e.subject_user_id,'owner_id',e.owner_id,
            'entity_schema',e.entity_schema,'entity_table',e.entity_table,'entity_id',e.entity_id,'import_job_id',e.import_job_id,'source_run_id',e.source_run_id,
            'metadata',e.metadata,'occurred_at',e.occurred_at,
            'changes',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.audit_change_id) FROM audit.changes c WHERE c.audit_event_id=e.audit_event_id),'[]'::jsonb)
        ) ORDER BY e.occurred_at DESC),'[]'::jsonb) INTO v_result
        FROM (SELECT * FROM audit.events x
              WHERE (NULLIF(p_params->>'event_type','') IS NULL OR x.event_type=p_params->>'event_type')
                AND (NULLIF(p_params->>'actor_user_id','') IS NULL OR x.actor_user_id=(p_params->>'actor_user_id')::uuid)
                AND (NULLIF(p_params->>'from','') IS NULL OR x.occurred_at>=(p_params->>'from')::timestamptz)
                AND (NULLIF(p_params->>'to','') IS NULL OR x.occurred_at<=(p_params->>'to')::timestamptz)
              ORDER BY x.occurred_at DESC LIMIT v_limit) e;

    WHEN 'list_ledger_entries' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'ledger_entry_id',le.financial_ledger_entry_id,'transaction_id',t.financial_transaction_id,'idempotency_key',t.idempotency_key,
            'description',t.description,'currency',t.currency,'posted_by_user_id',t.posted_by_user_id,'posted_at',t.posted_at,
            'account_id',le.financial_account_id,'debit_amount',le.debit_amount,'credit_amount',le.credit_amount,'created_at',le.created_at
        ) ORDER BY t.posted_at DESC,le.financial_ledger_entry_id),'[]'::jsonb) INTO v_result
        FROM (SELECT * FROM finance.transactions ORDER BY posted_at DESC LIMIT v_limit) t JOIN finance.ledger_entries le USING(financial_transaction_id);

    WHEN 'append_ledger_entry' THEN
        v_transaction_id:=admin.post_financial_transaction(
            p_body->>'idempotency_key',
            (p_body->>'currency')::app.currency_code,
            p_body->>'description',
            p_body->'entries',
            NULLIF(p_body->>'order_id','')::uuid
        );
        SELECT jsonb_build_object('transaction',to_jsonb(t),'entries',COALESCE((SELECT jsonb_agg(to_jsonb(le) ORDER BY le.financial_ledger_entry_id) FROM finance.ledger_entries le WHERE le.financial_transaction_id=t.financial_transaction_id),'[]'::jsonb))
        INTO v_result FROM finance.transactions t WHERE t.financial_transaction_id=v_transaction_id;

    WHEN 'verify_ledger' THEN
        WITH balances AS (
            SELECT t.financial_transaction_id,
                   COALESCE(sum(le.debit_amount),0) debits,
                   COALESCE(sum(le.credit_amount),0) credits
            FROM finance.transactions t LEFT JOIN finance.ledger_entries le USING(financial_transaction_id)
            GROUP BY t.financial_transaction_id
        ), source_hashes AS (
            SELECT count(*) FILTER(WHERE payload_sha256 IS DISTINCT FROM public.digest(pg_catalog.convert_to(payload::text,'UTF8'),'sha256')) bad_hashes
            FROM finance.source_events
        )
        SELECT jsonb_build_object(
            'valid',NOT EXISTS(SELECT 1 FROM balances WHERE debits<=0 OR debits<>credits) AND (SELECT bad_hashes=0 FROM source_hashes),
            'checked_transactions',(SELECT count(*) FROM balances),
            'unbalanced_transactions',(SELECT count(*) FROM balances WHERE debits<=0 OR debits<>credits),
            'invalid_source_hashes',(SELECT bad_hashes FROM source_hashes)
        ) INTO v_result;

    ELSE
        RAISE EXCEPTION 'Unknown administrator API operation: %',p_operation USING ERRCODE='22023';
    END CASE;

    RETURN COALESCE(v_result,'null'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION api.admin_finance_operation(text,jsonb,jsonb) FROM PUBLIC;

\echo '[PASS] 5280_api_admin_finance.sql'
SELECT pg_temp.bt_mark_completed('5000_function/5200_api/5280_api_admin_finance.sql');
