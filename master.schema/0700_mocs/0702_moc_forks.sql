/*
===============================================================================
 File:           0700_mocs/0702_moc_forks.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Preserve exact MOC fork ancestry.
 Depends On:     moc.mocs
                 moc.revisions
                 identity.users
 Creates:        moc.forks
 Key Rules:      A fork references the exact published source revision.
                 Forked designs become independent MOC identities afterward.
                 Forking must respect source MOC fork permission.
 Validation:     Prevents self-forks and duplicate ancestry for the forked MOC;
                 runtime trigger validates source revision and permission.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0700_mocs/0702_moc_forks.sql', ARRAY['moc.mocs', 'moc.revisions', 'identity.users']::text[]);



CREATE TABLE moc.forks (
    moc_fork_id uuid NOT NULL DEFAULT app.uuid_v7(),

    source_moc_id uuid NOT NULL,
    source_revision_id uuid NOT NULL,

    forked_moc_id uuid NOT NULL,
    forked_by_user_id uuid NOT NULL,

    forked_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_moc_forks
        PRIMARY KEY (moc_fork_id),

    CONSTRAINT fk_moc_forks_source_moc
        FOREIGN KEY (source_moc_id)
        REFERENCES moc.mocs(moc_id),

    CONSTRAINT fk_moc_forks_source_revision
        FOREIGN KEY (source_revision_id)
        REFERENCES moc.revisions(moc_revision_id),

    CONSTRAINT fk_moc_forks_forked_moc
        FOREIGN KEY (forked_moc_id)
        REFERENCES moc.mocs(moc_id),

    CONSTRAINT fk_moc_forks_user
        FOREIGN KEY (forked_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT uq_moc_forks_forked_moc
        UNIQUE (forked_moc_id),

    CONSTRAINT ck_moc_forks_not_self
        CHECK (
            source_moc_id <> forked_moc_id
        )
);

CREATE INDEX ix_moc_forks_source
    ON moc.forks(
        source_moc_id,
        source_revision_id
    );

SELECT app.assert_table_exists('moc', 'forks');

\echo '[PASS] 0702_moc_forks.sql'
SELECT pg_temp.bt_mark_completed('0700_mocs/0702_moc_forks.sql');
