\set ON_ERROR_STOP on

BEGIN;

GRANT EXECUTE ON FUNCTION app.set_import_context(uuid) TO lego_owner;

COMMIT;

\echo '[PASS] lego_owner can execute app.set_import_context(uuid).'
