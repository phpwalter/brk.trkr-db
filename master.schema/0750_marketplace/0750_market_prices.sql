/*
===============================================================================
 File:           0750_marketplace/0750_market_prices.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Store source-attributed market price observations.
 Depends On:     catalog.items
                 catalog.part_variants
                 reference.external_sources
                 app.money_amount
 Creates:        marketplace.price_condition
                 marketplace.market_price_observations
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0750_marketplace/0750_market_prices.sql', ARRAY['catalog.items', 'catalog.part_variants', 'reference.external_sources', 'app.money_amount']::text[]);



CREATE TYPE marketplace.price_condition AS ENUM ('NEW', 'USED', 'SEALED', 'OPEN_BOX', 'UNKNOWN');

CREATE TABLE marketplace.market_price_observations (
    market_price_observation_id uuid PRIMARY KEY DEFAULT app.uuid_v7(),
    source_id smallint NOT NULL REFERENCES reference.external_sources(source_id) ON DELETE RESTRICT,
    catalog_item_id uuid REFERENCES catalog.items(catalog_item_id) ON DELETE CASCADE,
    part_variant_id uuid REFERENCES catalog.part_variants(part_variant_id) ON DELETE CASCADE,
    condition marketplace.price_condition NOT NULL DEFAULT 'UNKNOWN',
    currency app.currency_code NOT NULL,
    low_price app.money_amount,
    median_price app.money_amount,
    high_price app.money_amount,
    sample_size integer,
    observed_at timestamptz NOT NULL,
    imported_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_market_price_target CHECK (num_nonnulls(catalog_item_id, part_variant_id) = 1),
    CONSTRAINT ck_market_price_order CHECK (
        (low_price IS NULL OR median_price IS NULL OR low_price <= median_price)
        AND (median_price IS NULL OR high_price IS NULL OR median_price <= high_price)
    ),
    CONSTRAINT ck_market_price_sample CHECK (sample_size IS NULL OR sample_size >= 0),
    CONSTRAINT uq_market_price_observation UNIQUE NULLS NOT DISTINCT
        (source_id, catalog_item_id, part_variant_id, condition, currency, observed_at)
);
CREATE INDEX ix_market_prices_item_time
    ON marketplace.market_price_observations(catalog_item_id, observed_at DESC)
    WHERE catalog_item_id IS NOT NULL;
CREATE INDEX ix_market_prices_variant_time
    ON marketplace.market_price_observations(part_variant_id, observed_at DESC)
    WHERE part_variant_id IS NOT NULL;
SELECT pg_temp.bt_mark_completed('0750_marketplace/0750_market_prices.sql');
