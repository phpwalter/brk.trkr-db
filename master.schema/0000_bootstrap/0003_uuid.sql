/*
===============================================================================
 File:           0000_bootstrap/0003_uuid.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Provide portable UUIDv7 generation for major entity keys.
 Depends On:     app schema
                 pgcrypto
 Creates:        app.uuid_v7()
 Key Rules:      Major application entities use time-ordered UUIDv7 identifiers.
                 External business/source IDs are never substituted for internal
                 primary keys.
                 Dense child/detail tables may use BIGINT identity keys.
 Validation:     Generates 100 UUID samples and verifies version 7 plus the RFC
                 variant nibble.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0000_bootstrap/0003_uuid.sql', ARRAY['app schema', 'pgcrypto']::text[]);



CREATE FUNCTION app.uuid_v7()
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
PARALLEL UNSAFE
AS $$
DECLARE
    v_unix_ms bigint;
    v_timestamp_hex text;
    v_random_hex text;
    v_variant_nibble text;
    v_uuid_hex text;
BEGIN
    v_unix_ms :=
        floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;

    v_timestamp_hex :=
        right(lpad(to_hex(v_unix_ms), 12, '0'), 12);

    v_random_hex :=
        encode(gen_random_bytes(10), 'hex');

    v_variant_nibble :=
        substr(
            '89ab',
            (
                (
                    get_byte(
                        decode(substr(v_random_hex, 4, 2), 'hex'),
                        0
                    ) >> 6
                ) & 3
            ) + 1,
            1
        );

    v_uuid_hex :=
          v_timestamp_hex
        || '7'
        || substr(v_random_hex, 1, 3)
        || v_variant_nibble
        || substr(v_random_hex, 5, 15);

    RETURN (
          substr(v_uuid_hex, 1, 8)
        || '-'
        || substr(v_uuid_hex, 9, 4)
        || '-'
        || substr(v_uuid_hex, 13, 4)
        || '-'
        || substr(v_uuid_hex, 17, 4)
        || '-'
        || substr(v_uuid_hex, 21, 12)
    )::uuid;
END;
$$;

COMMENT ON FUNCTION app.uuid_v7() IS
    'Generates time-ordered RFC-compatible UUID version 7 values.';

DO $$
DECLARE
    v_uuid uuid;
    v_uuid_text text;
BEGIN
    FOR i IN 1..100 LOOP
        v_uuid := app.uuid_v7();
        v_uuid_text := v_uuid::text;

        IF substr(v_uuid_text, 15, 1) <> '7' THEN
            RAISE EXCEPTION
                'Generated UUID "%" is not UUIDv7',
                v_uuid;
        END IF;

        IF substr(v_uuid_text, 20, 1) NOT IN ('8', '9', 'a', 'b') THEN
            RAISE EXCEPTION
                'Generated UUID "%" has an invalid RFC variant',
                v_uuid;
        END IF;
    END LOOP;
END;
$$;

\echo '[PASS] 0003_uuid.sql'
SELECT pg_temp.bt_mark_completed('0000_bootstrap/0003_uuid.sql');
