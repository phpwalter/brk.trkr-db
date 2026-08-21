/*
===============================================================================
 File:           0600_wanted/0601_wishlist_entries.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Store manual acquisition intent for catalog items/part variants.
 Depends On:     wanted.wishlists
                 catalog.items
                 catalog.part_variants
                 definition.inventory_versions
 Creates:        wanted.entry_status
                 wanted.wishlist_entries
 Key Rules:      An entry targets exactly one catalog item or part variant.
                 Exact preferred inventory version is optional.
                 Satisfaction state is preserved rather than deleting history.
                 Wishlist intent is distinct from derived build shortages.
 Validation:     Enforces target exclusivity, priority range, price/currency
                 pairing and satisfied timestamp consistency.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0600_wanted/0601_wishlist_entries.sql', ARRAY['wanted.wishlists', 'catalog.items', 'catalog.part_variants', 'definition.inventory_versions']::text[]);



CREATE TYPE wanted.entry_status AS ENUM (
    'ACTIVE',
    'PARTIALLY_SATISFIED',
    'SATISFIED',
    'ARCHIVED'
);

CREATE TABLE wanted.wishlist_entries (
    wishlist_entry_id uuid NOT NULL DEFAULT app.uuid_v7(),

    wishlist_id uuid NOT NULL,

    catalog_item_id uuid,
    part_variant_id uuid,

    preferred_inventory_version_id uuid,

    desired_quantity app.quantity NOT NULL DEFAULT 1,

    priority smallint NOT NULL DEFAULT 3,

    target_unit_price app.money_amount,
    currency app.currency_code,

    status wanted.entry_status
        NOT NULL DEFAULT 'ACTIVE',

    notes text,

    created_at timestamptz NOT NULL DEFAULT now(),
    satisfied_at timestamptz,

    CONSTRAINT pk_wishlist_entries
        PRIMARY KEY (wishlist_entry_id),

    CONSTRAINT fk_wishlist_entries_wishlist
        FOREIGN KEY (wishlist_id)
        REFERENCES wanted.wishlists(wishlist_id),

    CONSTRAINT fk_wishlist_entries_item
        FOREIGN KEY (catalog_item_id)
        REFERENCES catalog.items(catalog_item_id),

    CONSTRAINT fk_wishlist_entries_variant
        FOREIGN KEY (part_variant_id)
        REFERENCES catalog.part_variants(part_variant_id),

    CONSTRAINT fk_wishlist_entries_version
        FOREIGN KEY (preferred_inventory_version_id)
        REFERENCES definition.inventory_versions(
            inventory_version_id
        ),

    CONSTRAINT ck_wishlist_entries_target
        CHECK (
            num_nonnulls(
                catalog_item_id,
                part_variant_id
            ) = 1
        ),

    CONSTRAINT ck_wishlist_entries_priority
        CHECK (
            priority BETWEEN 1 AND 5
        ),

    CONSTRAINT ck_wishlist_entries_money
        CHECK (
            (
                target_unit_price IS NULL
                AND currency IS NULL
            )
            OR
            (
                target_unit_price IS NOT NULL
                AND currency IS NOT NULL
            )
        ),

    CONSTRAINT ck_wishlist_entries_satisfied
        CHECK (
            status <> 'SATISFIED'
            OR satisfied_at IS NOT NULL
        )
);

CREATE INDEX ix_wishlist_entries_wishlist
    ON wanted.wishlist_entries(
        wishlist_id,
        status
    );

SELECT app.assert_table_exists(
    'wanted',
    'wishlist_entries'
);

\echo '[PASS] 0601_wishlist_entries.sql'
SELECT pg_temp.bt_mark_completed('0600_wanted/0601_wishlist_entries.sql');
