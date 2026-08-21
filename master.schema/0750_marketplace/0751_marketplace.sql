/*
===============================================================================
 File:           0750_marketplace/0751_marketplace.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Model owner-scoped marketplace listings and orders.
 Depends On:     identity.owners
                 identity.users
                 collection.entries
                 marketplace.market_price_observations
 Creates:        marketplace.listing_status
                 marketplace.order_status
                 marketplace.listings
                 marketplace.listing_items
                 marketplace.orders
                 marketplace.order_items
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0750_marketplace/0751_marketplace.sql', ARRAY['identity.owners', 'identity.users', 'collection.entries', 'marketplace.market_price_observations']::text[]);



CREATE TYPE marketplace.listing_status AS ENUM ('DRAFT','ACTIVE','RESERVED','SOLD','CANCELLED','EXPIRED');
CREATE TYPE marketplace.order_status AS ENUM ('PENDING','CONFIRMED','PAID','FULFILLED','CANCELLED','REFUNDED');

ALTER TABLE collection.entries
    ADD CONSTRAINT uq_collection_entries_owner_pair
    UNIQUE (collection_entry_id, owner_id);

CREATE TABLE marketplace.listings (
    listing_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    seller_owner_id uuid NOT NULL REFERENCES identity.owners(owner_id) ON DELETE RESTRICT,
    title text NOT NULL,
    status marketplace.listing_status NOT NULL DEFAULT 'DRAFT',
    currency app.currency_code NOT NULL,
    asking_price app.money_amount NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES identity.users(user_id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    activated_at timestamptz,
    closed_at timestamptz,
    CONSTRAINT ck_marketplace_listing_title CHECK (btrim(title) <> ''),
    CONSTRAINT ck_marketplace_listing_active CHECK (status <> 'ACTIVE' OR activated_at IS NOT NULL),
    CONSTRAINT ck_marketplace_listing_closed CHECK (status NOT IN ('SOLD','CANCELLED','EXPIRED') OR closed_at IS NOT NULL),
    CONSTRAINT uq_marketplace_listing_owner_pair UNIQUE (listing_id, seller_owner_id)
);
CREATE INDEX ix_marketplace_listings_seller_status
    ON marketplace.listings(seller_owner_id, status, created_at DESC);

CREATE TABLE marketplace.listing_items (
    listing_item_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    listing_id uuid NOT NULL,
    seller_owner_id uuid NOT NULL,
    collection_entry_id uuid NOT NULL,
    quantity app.quantity NOT NULL,
    CONSTRAINT fk_marketplace_listing_item_listing
        FOREIGN KEY (listing_id, seller_owner_id)
        REFERENCES marketplace.listings(listing_id, seller_owner_id) ON DELETE CASCADE,
    CONSTRAINT fk_marketplace_listing_item_entry_owner
        FOREIGN KEY (collection_entry_id, seller_owner_id)
        REFERENCES collection.entries(collection_entry_id, owner_id) ON DELETE RESTRICT,
    CONSTRAINT uq_marketplace_listing_entry UNIQUE (listing_id, collection_entry_id)
);

CREATE TABLE marketplace.orders (
    order_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    listing_id uuid NOT NULL UNIQUE REFERENCES marketplace.listings(listing_id) ON DELETE RESTRICT,
    buyer_owner_id uuid NOT NULL REFERENCES identity.owners(owner_id) ON DELETE RESTRICT,
    status marketplace.order_status NOT NULL DEFAULT 'PENDING',
    currency app.currency_code NOT NULL,
    subtotal app.money_amount NOT NULL,
    created_by_user_id uuid NOT NULL REFERENCES identity.users(user_id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    paid_at timestamptz,
    fulfilled_at timestamptz,
    cancelled_at timestamptz,
    CONSTRAINT ck_marketplace_order_paid CHECK (status <> 'PAID' OR paid_at IS NOT NULL),
    CONSTRAINT ck_marketplace_order_fulfilled CHECK (status <> 'FULFILLED' OR fulfilled_at IS NOT NULL),
    CONSTRAINT ck_marketplace_order_cancelled CHECK (status <> 'CANCELLED' OR cancelled_at IS NOT NULL)
);

CREATE TABLE marketplace.order_items (
    order_item_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    order_id uuid NOT NULL REFERENCES marketplace.orders(order_id) ON DELETE CASCADE,
    listing_item_id uuid NOT NULL REFERENCES marketplace.listing_items(listing_item_id) ON DELETE RESTRICT,
    quantity app.quantity NOT NULL,
    unit_price app.money_amount NOT NULL,
    CONSTRAINT uq_marketplace_order_listing_item UNIQUE (order_id, listing_item_id)
);
CREATE INDEX ix_marketplace_orders_buyer
    ON marketplace.orders(buyer_owner_id, created_at DESC);
SELECT pg_temp.bt_mark_completed('0750_marketplace/0751_marketplace.sql');
