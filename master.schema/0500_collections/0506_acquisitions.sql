/*
===============================================================================
 File:           0500_collections/0506_acquisitions.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store optional acquisition/purchase provenance separately from
                 ownership state.
 Depends On:     identity.owners
                 collection.entries
                 collection.instances
                 app.currency_code
                 app.money_amount
 Creates:        collection.acquisitions
                 collection.acquisition_items
 Key Rules:      Acquisition history is not embedded directly into catalog data.
                 Monetary values use NUMERIC domains and explicit ISO currency.
                 One acquisition may contain multiple owned entries/instances.
 Validation:     Monetary values require a currency; FK constraints preserve
                 acquisition-to-owned-item relationships.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0500_collections/0506_acquisitions.sql', ARRAY['identity.owners', 'collection.entries', 'collection.instances', 'app.currency_code', 'app.money_amount']::text[]);



CREATE TABLE collection.acquisitions (
    acquisition_id uuid NOT NULL DEFAULT app.uuid_v7(),

    owner_id uuid NOT NULL,

    seller_name text,
    source_description text,

    acquired_on date,

    currency app.currency_code,

    item_amount app.money_amount,
    shipping_amount app.money_amount,
    tax_amount app.money_amount,
    fee_amount app.money_amount,

    notes text,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_acquisitions
        PRIMARY KEY (acquisition_id),

    CONSTRAINT fk_acquisitions_owner
        FOREIGN KEY (owner_id)
        REFERENCES identity.owners(owner_id),

    CONSTRAINT ck_acquisitions_currency
        CHECK (
            currency IS NOT NULL
            OR num_nonnulls(
                item_amount,
                shipping_amount,
                tax_amount,
                fee_amount
            ) = 0
        )
);

CREATE TABLE collection.acquisition_items (
    acquisition_item_id bigint GENERATED ALWAYS AS IDENTITY,

    acquisition_id uuid NOT NULL,

    collection_entry_id uuid NOT NULL,
    collection_instance_id uuid,

    quantity app.quantity NOT NULL,

    allocated_item_amount app.money_amount,

    CONSTRAINT pk_acquisition_items
        PRIMARY KEY (acquisition_item_id),

    CONSTRAINT fk_acquisition_items_acquisition
        FOREIGN KEY (acquisition_id)
        REFERENCES collection.acquisitions(acquisition_id)
        ON DELETE CASCADE,

    CONSTRAINT fk_acquisition_items_entry
        FOREIGN KEY (collection_entry_id)
        REFERENCES collection.entries(collection_entry_id),

    CONSTRAINT fk_acquisition_items_instance
        FOREIGN KEY (collection_instance_id)
        REFERENCES collection.instances(collection_instance_id)
);

CREATE INDEX ix_acquisition_items_acquisition
    ON collection.acquisition_items(acquisition_id);

CREATE INDEX ix_acquisition_items_entry
    ON collection.acquisition_items(collection_entry_id);

SELECT app.assert_table_exists(
    'collection',
    'acquisitions'
);

SELECT app.assert_table_exists(
    'collection',
    'acquisition_items'
);

\echo '[PASS] 0506_acquisitions.sql'
SELECT pg_temp.bt_mark_completed('0500_collections/0506_acquisitions.sql');
