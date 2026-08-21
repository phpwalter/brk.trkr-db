/*
===============================================================================
 File:           0700_mocs/0703_moc_subassemblies.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Preserve hierarchical subassembly structure for MOC revisions.
 Depends On:     moc.revisions
 Creates:        moc.subassemblies
 Key Rules:      Subassemblies belong to one exact MOC revision.
                 Recursive hierarchy cycles are prohibited.
                 Parent subassemblies must belong to the same revision.
 Validation:     Prevents direct self-parenting and invalid sort values;
                 hierarchy runtime logic prevents recursive cycles.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0700_mocs/0703_moc_subassemblies.sql', ARRAY['moc.revisions']::text[]);



CREATE TABLE moc.subassemblies (
    subassembly_id uuid NOT NULL DEFAULT app.uuid_v7(),

    moc_revision_id uuid NOT NULL,

    parent_subassembly_id uuid,

    subassembly_name text NOT NULL,
    sort_order integer,

    CONSTRAINT pk_moc_subassemblies
        PRIMARY KEY (subassembly_id),

    CONSTRAINT fk_moc_subassemblies_revision
        FOREIGN KEY (moc_revision_id)
        REFERENCES moc.revisions(moc_revision_id),

    CONSTRAINT fk_moc_subassemblies_parent
        FOREIGN KEY (parent_subassembly_id)
        REFERENCES moc.subassemblies(subassembly_id),

    CONSTRAINT ck_moc_subassemblies_name
        CHECK (btrim(subassembly_name) <> ''),

    CONSTRAINT ck_moc_subassemblies_not_self
        CHECK (
            parent_subassembly_id IS NULL
            OR parent_subassembly_id <> subassembly_id
        ),

    CONSTRAINT ck_moc_subassemblies_sort
        CHECK (
            sort_order IS NULL
            OR sort_order >= 0
        )
);

CREATE INDEX ix_moc_subassemblies_revision
    ON moc.subassemblies(moc_revision_id);

CREATE INDEX ix_moc_subassemblies_parent
    ON moc.subassemblies(parent_subassembly_id);

SELECT app.assert_table_exists(
    'moc',
    'subassemblies'
);

\echo '[PASS] 0703_moc_subassemblies.sql'
SELECT pg_temp.bt_mark_completed('0700_mocs/0703_moc_subassemblies.sql');
