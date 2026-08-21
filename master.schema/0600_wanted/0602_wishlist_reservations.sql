/*
===============================================================================
 File:           0600_wanted/0602_wishlist_reservations.sql
 Project:        LEGO Collection Platform
 Schema Version: 0.1.0
 PostgreSQL:     16+
 Purpose:        Support gift reservations against wishlist entries.
 Depends On:     wanted.wishlist_entries
                 identity.users
 Creates:        wanted.wishlist_reservations
 Key Rules:      Gift reservations may be hidden from the wishlist owner.
                 Reservations preserve quantity and lifecycle history.
                 Released reservations are retained rather than deleted.
 Validation:     Enforces valid reservation expiry/release chronology.
===============================================================================
*/

\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('0600_wanted/0602_wishlist_reservations.sql', ARRAY['wanted.wishlist_entries', 'identity.users']::text[]);



CREATE TABLE wanted.wishlist_reservations (
    wishlist_reservation_id uuid NOT NULL DEFAULT app.uuid_v7(),

    wishlist_entry_id uuid NOT NULL,
    reserved_by_user_id uuid NOT NULL,

    quantity app.quantity NOT NULL,

    hidden_from_owner boolean NOT NULL DEFAULT true,

    reserved_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    released_at timestamptz,

    CONSTRAINT pk_wishlist_reservations
        PRIMARY KEY (wishlist_reservation_id),

    CONSTRAINT fk_wishlist_reservations_entry
        FOREIGN KEY (wishlist_entry_id)
        REFERENCES wanted.wishlist_entries(
            wishlist_entry_id
        ),

    CONSTRAINT fk_wishlist_reservations_user
        FOREIGN KEY (reserved_by_user_id)
        REFERENCES identity.users(user_id),

    CONSTRAINT ck_wishlist_reservations_dates
        CHECK (
            (
                expires_at IS NULL
                OR expires_at > reserved_at
            )
            AND
            (
                released_at IS NULL
                OR released_at >= reserved_at
            )
        )
);

CREATE INDEX ix_wishlist_reservations_active
    ON wanted.wishlist_reservations(wishlist_entry_id)
    WHERE released_at IS NULL;

SELECT app.assert_table_exists(
    'wanted',
    'wishlist_reservations'
);

\echo '[PASS] 0602_wishlist_reservations.sql'
SELECT pg_temp.bt_mark_completed('0600_wanted/0602_wishlist_reservations.sql');
