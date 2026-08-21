/*
===============================================================================
 File:           0500_collections/0505_transfers.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Preserve ownership-transfer history between user/family owners.
 Depends On:     collection.entries
                 identity.owners
                 identity.users
 Creates:        collection.transfers
 Key Rules:      Transfers preserve acquisition/provenance history.
                 Transfers must move between distinct owners.
                 Transfer mutation should occur through transactional application
                 procedures rather than ad-hoc direct ownership changes.
 Validation:     Enforces valid owners/actor/entry and prohibits same-owner
                 transfers.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0500_collections/0505_transfers.sql', ARRAY['collection.entries', 'identity.owners', 'identity.users']::text[]);



CREATE TABLE collection.transfers (
    transfer_id uuid NOT NULL DEFAULT app.uuid_v7(),

    collection_entry_id uuid NOT NULL,

    from_owner_id uuid NOT NULL,
    to_owner_id uuid NOT NULL,

    quantity app.quantity NOT NULL,

    actor_user_id uuid NOT NULL,
    reason text,

    transferred_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_collection_transfers
        PRIMARY KEY (transfer_id),

    CONSTRAINT fk_collection_transfers_entry
        FOREIGN KEY (collection_entry_id)
        REFERENCES collection.entries(collection_entry_id),

    CONSTRAINT fk_collection_transfers_from_owner
        FOREIGN KEY (from_owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT fk_collection_transfers_to_owner
        FOREIGN KEY (to_owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT fk_collection_transfers_actor
        FOREIGN KEY (actor_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_collection_transfers_owner
        CHECK (from_owner_id <> to_owner_id)
);

CREATE INDEX ix_collection_transfers_entry
    ON collection.transfers(
        collection_entry_id,
        transferred_at DESC
    );

SELECT app.assert_table_exists(
    'collection',
    'transfers'
);

\echo '[PASS] 0505_transfers.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0505_transfers.sql');
