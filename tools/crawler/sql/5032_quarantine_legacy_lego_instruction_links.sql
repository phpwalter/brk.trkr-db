\set ON_ERROR_STOP on

/*
 One-time soft quarantine of LEGO instruction manifest links created before
 parser v2. No rows are deleted and catalog lifecycle state is not mutated.
 Parser v2 reasserts valid links as sets are recrawled.
*/

BEGIN;

UPDATE definition.set_manifest_components smc
   SET source_present = false,
       last_seen_at = clock_timestamp(),
       source_payload =
           COALESCE(smc.source_payload, '{}'::jsonb)
           || jsonb_build_object(
                'retired_reason',
                'LEGACY_PARSER_V1_QUARANTINE',
                'retired_at',
                clock_timestamp()
              )
 WHERE smc.component_kind = 'INSTRUCTIONS'::catalog.item_kind
   AND smc.source_code = 'LEGO'
   AND smc.source_present = true;

\echo '[PASS] legacy LEGO instruction manifest links quarantined'

COMMIT;
