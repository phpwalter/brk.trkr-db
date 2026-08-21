/*
===============================================================================
 File:           0100_identity/0101_authentication.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store password/passkey credentials, login sessions and one-time
                 authentication tokens.
 Depends On:     identity.users
                 app.sha256_digest
 Creates:        identity.credential_type
                 identity.one_time_token_purpose
                 identity.user_credentials
                 identity.user_sessions
                 identity.one_time_tokens
 Key Rules:      Plaintext passwords and bearer tokens are never stored.
                 A user has at most one active PASSWORD credential.
                 Passkey identifiers are unique while active.
 Validation:     Enforces credential-shape exclusivity, token uniqueness,
                 non-negative passkey counters and valid lifecycle chronology.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0100_identity/0101_authentication.sql', ARRAY['identity.users', 'app.sha256_digest']::text[]);



CREATE TYPE identity.credential_type AS ENUM (
    'PASSWORD',
    'PASSKEY'
);

CREATE TYPE identity.one_time_token_purpose AS ENUM (
    'EMAIL_VERIFICATION',
    'PASSWORD_RESET',
    'ACCOUNT_ACTIVATION'
);

CREATE TABLE identity.user_credentials (
    user_credential_id uuid NOT NULL DEFAULT app.uuid_v7(),
    user_id uuid NOT NULL,

    credential_type identity.credential_type NOT NULL,

    credential_identifier text,
    password_hash text,

    passkey_public_key bytea,
    passkey_sign_count bigint,

    created_at timestamptz NOT NULL DEFAULT now(),
    last_used_at timestamptz,
    revoked_at timestamptz,

    CONSTRAINT pk_user_credentials
        PRIMARY KEY (user_credential_id),

    CONSTRAINT fk_user_credentials_user
        FOREIGN KEY (user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_user_credentials_content
        CHECK (
            (
                credential_type = 'PASSWORD'
                AND password_hash IS NOT NULL
                AND btrim(password_hash) <> ''
                AND credential_identifier IS NULL
                AND passkey_public_key IS NULL
                AND passkey_sign_count IS NULL
            )
            OR
            (
                credential_type = 'PASSKEY'
                AND credential_identifier IS NOT NULL
                AND btrim(credential_identifier) <> ''
                AND password_hash IS NULL
                AND passkey_public_key IS NOT NULL
            )
        ),

    CONSTRAINT ck_user_credentials_sign_count
        CHECK (
            passkey_sign_count IS NULL
            OR passkey_sign_count >= 0
        )
);

CREATE UNIQUE INDEX uq_active_password_per_user
    ON identity.user_credentials(user_id)
    WHERE credential_type = 'PASSWORD'
      AND revoked_at IS NULL;

CREATE UNIQUE INDEX uq_active_passkey_identifier
    ON identity.user_credentials(credential_identifier)
    WHERE credential_type = 'PASSKEY'
      AND revoked_at IS NULL;

CREATE INDEX ix_user_credentials_user
    ON identity.user_credentials(user_id);


CREATE TABLE identity.user_sessions (
    user_session_id uuid NOT NULL DEFAULT app.uuid_v7(),
    user_id uuid NOT NULL,

    session_token_hash app.sha256_digest NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,

    ip_address inet,
    user_agent text,

    CONSTRAINT pk_user_sessions
        PRIMARY KEY (user_session_id),

    CONSTRAINT fk_user_sessions_user
        FOREIGN KEY (user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT uq_user_sessions_hash
        UNIQUE (session_token_hash),

    CONSTRAINT ck_user_sessions_dates
        CHECK (
            expires_at > created_at
            AND last_seen_at >= created_at
            AND (
                revoked_at IS NULL
                OR revoked_at >= created_at
            )
        )
);

CREATE INDEX ix_user_sessions_active
    ON identity.user_sessions(user_id, expires_at)
    WHERE revoked_at IS NULL;


CREATE TABLE identity.one_time_tokens (
    one_time_token_id uuid NOT NULL DEFAULT app.uuid_v7(),
    user_id uuid NOT NULL,

    purpose identity.one_time_token_purpose NOT NULL,
    token_hash app.sha256_digest NOT NULL,

    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,

    CONSTRAINT pk_one_time_tokens
        PRIMARY KEY (one_time_token_id),

    CONSTRAINT fk_one_time_tokens_user
        FOREIGN KEY (user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT uq_one_time_tokens_hash
        UNIQUE (token_hash),

    CONSTRAINT ck_one_time_tokens_dates
        CHECK (
            expires_at > created_at
            AND (
                consumed_at IS NULL
                OR consumed_at >= created_at
            )
        )
);

CREATE INDEX ix_one_time_tokens_active
    ON identity.one_time_tokens(
        user_id,
        purpose,
        expires_at
    )
    WHERE consumed_at IS NULL;

SELECT app.assert_table_exists('identity', 'user_credentials');
SELECT app.assert_table_exists('identity', 'user_sessions');
SELECT app.assert_table_exists('identity', 'one_time_tokens');

\echo '[PASS] 0101_authentication.sql'
SELECT pg_temp.bt_mark_completed('0100_identity/0101_authentication.sql');
