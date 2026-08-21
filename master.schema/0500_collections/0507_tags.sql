/*
===============================================================================
 File:           0500_collections/0507_tags.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Define owner-scoped tags and collection-entry tag assignments.
 Depends On:     identity.owners
                 collection.entries
                 citext
 Creates:        collection.tags
                 collection.entry_tags
 Key Rules:      Tag namespaces are owner-scoped.
                 Tag names compare case-insensitively.
                 Entry/tag assignments must not cross owners.
 Validation:     Enforces unique owner/tag names and unique assignments; domain
                 validation checks owner consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0500_collections/0507_tags.sql', ARRAY['identity.owners', 'collection.entries', 'citext']::text[]);



CREATE TABLE collection.tags (
    tag_id uuid NOT NULL DEFAULT app.uuid_v7(),

    owner_id uuid NOT NULL,
    tag_name citext NOT NULL,

    CONSTRAINT pk_collection_tags
        PRIMARY KEY (tag_id),

    CONSTRAINT fk_collection_tags_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT uq_collection_tag_owner_name
        UNIQUE (
            owner_id,
            tag_name
        ),

    CONSTRAINT ck_collection_tags_name
        CHECK (btrim(tag_name::text) <> '')
);

CREATE TABLE collection.entry_tags (
    entry_tag_id bigint GENERATED ALWAYS AS IDENTITY,

    collection_entry_id uuid NOT NULL,
    tag_id uuid NOT NULL,

    CONSTRAINT pk_collection_entry_tags
        PRIMARY KEY (entry_tag_id),

    CONSTRAINT fk_collection_entry_tags_entry
        FOREIGN KEY (collection_entry_id)
        REFERENCES collection.entries(collection_entry_id)
        ON DELETE CASCADE,

    CONSTRAINT fk_collection_entry_tags_tag
        FOREIGN KEY (tag_id)
        REFERENCES collection.tags(tag_id)
        ON DELETE CASCADE,

    CONSTRAINT uq_collection_entry_tag
        UNIQUE (
            collection_entry_id,
            tag_id
        )
);

CREATE INDEX ix_collection_entry_tags_tag
    ON collection.entry_tags(tag_id);

SELECT app.assert_table_exists('collection', 'tags');
SELECT app.assert_table_exists('collection', 'entry_tags');

\echo '[PASS] 0507_tags.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0507_tags.sql');
