\set ON_ERROR_STOP on

DO $$
BEGIN
    IF to_regprocedure(
        'import.begin_lego_instruction_sync(jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION 'missing import.begin_lego_instruction_sync(jsonb)';
    END IF;

    IF to_regprocedure(
        'import.reconcile_lego_instruction_batch(uuid,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'missing import.reconcile_lego_instruction_batch(uuid,jsonb)';
    END IF;

    IF to_regprocedure(
        'import.complete_lego_instruction_sync(uuid,jsonb)'
    ) IS NULL THEN
        RAISE EXCEPTION
            'missing import.complete_lego_instruction_sync(uuid,jsonb)';
    END IF;
END;
$$;

SELECT
    p.oid::regprocedure::text AS function_name,
    p.prosecdef AS security_definer
FROM pg_proc p
WHERE p.oid =
    'import.reconcile_lego_instruction_batch(uuid,jsonb)'::regprocedure;

\echo '[PASS] LEGO instruction importer contract verified'
