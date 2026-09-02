-- File Version: 1.3.0
/*
 * BT TEST FIXTURE TRANSPORT v1.3.0
 *
 * psql variables are not substituted inside dollar-quoted PL/pgSQL bodies.
 * Materialize the fixture UUID before any SQL in this file is parsed.
 *
 * FALSE is intentional: bt.test_user_id is test-only session metadata and
 * must survive COMMIT/ROLLBACK while app.* transaction-local context is tested.
 */
SELECT pg_catalog.set_config(
    'bt.test_user_id',
    :'user_id',
    FALSE
);
\set ON_ERROR_STOP on

\if :{?user_id}
\else
    \echo '[FAIL] user_id psql variable is required'
    \quit 2
\endif

\echo '[RUN ] Direct-backend transaction-context behavioral suite'

SELECT pg_catalog.pg_backend_pid() AS initial_backend_pid \gset

/* -------------------------------------------------------------------------
 * 1. Autocommit wipe
 * ------------------------------------------------------------------------- */
SELECT app.set_request_context(
    pg_catalog.current_setting('bt.test_user_id')::uuid,
    '00000000-0000-7000-8000-00000000b001'::uuid,
    'direct-autocommit',
    'USER'
);

SELECT (
    identity.current_user_id_optional() IS NULL
    AND app.current_request_id() IS NULL
    AND app.current_trace_id() IS NULL
    AND app.current_actor_class() IS NULL
) AS bt_ok \gset

\if :bt_ok
\else
    \echo '[FAIL] Autocommit context survived its statement transaction'
    \quit 3
\endif

/* -------------------------------------------------------------------------
 * 2. Explicit transaction + savepoint restoration + clear idempotence
 * ------------------------------------------------------------------------- */
BEGIN;
SELECT app.set_request_context(
    pg_catalog.current_setting('bt.test_user_id')::uuid,
    '00000000-0000-7000-8000-00000000b002'::uuid,
    'direct-a',
    'USER'
);

SELECT (
    identity.current_user_id() = pg_catalog.current_setting('bt.test_user_id')::uuid
    AND identity.require_current_user_id() = pg_catalog.current_setting('bt.test_user_id')::uuid
    AND app.current_request_id() = '00000000-0000-7000-8000-00000000b002'::uuid
    AND app.current_trace_id() = 'direct-a'
    AND app.current_actor_class() = 'USER'
) AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] Context A was not established'
    ROLLBACK;
    \quit 3
\endif

SAVEPOINT s1;
SELECT app.set_request_context(
    pg_catalog.current_setting('bt.test_user_id')::uuid,
    '00000000-0000-7000-8000-00000000b003'::uuid,
    'direct-b',
    'USER'
);

SELECT app.current_request_id() = '00000000-0000-7000-8000-00000000b003'::uuid AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] Context B was not established'
    ROLLBACK;
    \quit 3
\endif

ROLLBACK TO SAVEPOINT s1;

SELECT (
    app.current_request_id() = '00000000-0000-7000-8000-00000000b002'::uuid
    AND app.current_trace_id() = 'direct-a'
) AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] SAVEPOINT rollback did not restore Context A'
    ROLLBACK;
    \quit 3
\endif

SELECT app.clear_request_context();
SELECT app.clear_request_context();

SELECT (
    identity.current_user_id_optional() IS NULL
    AND app.current_request_id() IS NULL
    AND app.current_trace_id() IS NULL
    AND app.current_actor_class() IS NULL
) AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] clear_request_context() is not idempotent'
    ROLLBACK;
    \quit 3
\endif

SELECT app.set_request_context(
    pg_catalog.current_setting('bt.test_user_id')::uuid,
    '00000000-0000-7000-8000-00000000b004'::uuid,
    NULL,
    'user'
);
COMMIT;

/* COMMIT cleanup */
SELECT (
    identity.current_user_id_optional() IS NULL
    AND app.current_request_id() IS NULL
    AND app.current_trace_id() IS NULL
    AND app.current_actor_class() IS NULL
) AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] Context leaked across COMMIT'
    \quit 3
\endif

/* -------------------------------------------------------------------------
 * 3. ROLLBACK cleanup
 * ------------------------------------------------------------------------- */
BEGIN;
SELECT app.set_request_context(
    pg_catalog.current_setting('bt.test_user_id')::uuid,
    '00000000-0000-7000-8000-00000000b005'::uuid,
    'direct-rollback',
    'USER'
);
ROLLBACK;

SELECT (
    identity.current_user_id_optional() IS NULL
    AND app.current_request_id() IS NULL
    AND app.current_trace_id() IS NULL
    AND app.current_actor_class() IS NULL
) AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] Context leaked across ROLLBACK'
    \quit 3
\endif

/* -------------------------------------------------------------------------
 * 4. Failure recovery: aborted transaction followed by clean transaction
 * ------------------------------------------------------------------------- */
BEGIN;
SELECT app.set_request_context(
    pg_catalog.current_setting('bt.test_user_id')::uuid,
    '00000000-0000-7000-8000-00000000b006'::uuid,
    'direct-error',
    'USER'
);

\set ON_ERROR_STOP off
SELECT 1 / 0;
\set ON_ERROR_STOP on
ROLLBACK;

SELECT (
    identity.current_user_id_optional() IS NULL
    AND app.current_request_id() IS NULL
    AND app.current_trace_id() IS NULL
    AND app.current_actor_class() IS NULL
) AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] Failed transaction leaked context after ROLLBACK'
    \quit 3
\endif

/* -------------------------------------------------------------------------
 * 5. Adversarial validation calls must fail and preserve outer context
 * ------------------------------------------------------------------------- */
BEGIN;
SELECT app.set_request_context(
    pg_catalog.current_setting('bt.test_user_id')::uuid,
    '00000000-0000-7000-8000-00000000b007'::uuid,
    'direct-valid',
    'USER'
);

DO $do$
BEGIN
    BEGIN
        PERFORM app.set_request_context(
            NULL,
            '00000000-0000-7000-8000-00000000c001'::uuid,
            'bad-null-user',
            'USER'
        );
        RAISE EXCEPTION 'NULL USER p_user_id was accepted' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE '22004' THEN NULL;
    END;

    BEGIN
        PERFORM app.set_request_context(
            '00000000-0000-7000-8000-ffffffffffff'::uuid,
            '00000000-0000-7000-8000-00000000c002'::uuid,
            'bad-missing-user',
            'USER'
        );
        RAISE EXCEPTION 'Nonexistent USER identity was accepted' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE '23503' THEN NULL;
    END;

    BEGIN
        PERFORM app.set_request_context(
            pg_catalog.current_setting('bt.test_user_id')::uuid,
            NULL,
            'bad-null-request',
            'USER'
        );
        RAISE EXCEPTION 'NULL request_id was accepted' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE '22004' THEN NULL;
    END;

    BEGIN
        PERFORM app.set_request_context(
            pg_catalog.current_setting('bt.test_user_id')::uuid,
            '00000000-0000-7000-8000-00000000c003'::uuid,
            '   ',
            'USER'
        );
        RAISE EXCEPTION 'Whitespace trace_id was accepted' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;

    BEGIN
        PERFORM app.set_request_context(
            pg_catalog.current_setting('bt.test_user_id')::uuid,
            '00000000-0000-7000-8000-00000000c004'::uuid,
            pg_catalog.repeat('x', 129),
            'USER'
        );
        RAISE EXCEPTION 'Oversized trace_id was accepted' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE '22001' THEN NULL;
    END;

    BEGIN
        PERFORM app.set_request_context(
            pg_catalog.current_setting('bt.test_user_id')::uuid,
            '00000000-0000-7000-8000-00000000c005'::uuid,
            E'bad\ntrace',
            'USER'
        );
        RAISE EXCEPTION 'Control-character trace_id was accepted' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;

    BEGIN
        PERFORM app.set_request_context(
            pg_catalog.current_setting('bt.test_user_id')::uuid,
            '00000000-0000-7000-8000-00000000c006'::uuid,
            'bad-actor',
            'NOT_A_REAL_ACTOR'
        );
        RAISE EXCEPTION 'Invalid actor_class was accepted' USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;
END;
$do$;

SELECT (
    identity.current_user_id() = pg_catalog.current_setting('bt.test_user_id')::uuid
    AND app.current_request_id() = '00000000-0000-7000-8000-00000000b007'::uuid
    AND app.current_trace_id() = 'direct-valid'
    AND app.current_actor_class() = 'USER'
) AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] Rejected setter call mutated outer valid context'
    ROLLBACK;
    \quit 3
\endif
ROLLBACK;

/* -------------------------------------------------------------------------
 * 6. Backend reuse proof
 * ------------------------------------------------------------------------- */
SELECT (
    pg_catalog.pg_backend_pid() = :initial_backend_pid::integer
) AS bt_ok \gset
\if :bt_ok
\else
    \echo '[FAIL] Direct-backend simulation did not reuse one PostgreSQL backend'
    \quit 3
\endif

/* Strict getter must fail when context is absent. */
DO $do$
BEGIN
    BEGIN
        PERFORM identity.require_current_user_id();
        RAISE EXCEPTION 'require_current_user_id accepted absent context'
            USING ERRCODE = 'P0001';
    EXCEPTION WHEN SQLSTATE '22004' THEN NULL;
    END;
END;
$do$;

\echo '[PASS] Direct-backend transaction-context behavioral suite.'


