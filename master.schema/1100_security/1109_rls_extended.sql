/*
===============================================================================
 File:           1100_security/1109_rls_extended.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Add defense-in-depth RLS to new owner/user-facing domains.
 Depends On:     marketplace.listings
                 marketplace.orders
                 operations.notifications
                 identity.current_user_id()
                 identity.can_view_owner()
                 identity.can_manage_owner()
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1100_security/1109_rls_extended.sql', ARRAY['marketplace.listings', 'marketplace.orders', 'operations.notifications', 'identity.current_user_id()', 'identity.can_view_owner()', 'identity.can_manage_owner()']::text[]);



ALTER TABLE marketplace.listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketplace.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketplace.listing_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketplace.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE operations.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY pol_marketplace_listings_select
ON marketplace.listings FOR SELECT
USING (
    status = 'ACTIVE'
    OR identity.can_view_owner(identity.current_user_id(), seller_owner_id, 'COLLECTION')
);

CREATE POLICY pol_marketplace_listings_manage
ON marketplace.listings FOR ALL
USING (
    identity.can_manage_owner(identity.current_user_id(), seller_owner_id, 'COLLECTION')
)
WITH CHECK (
    identity.can_manage_owner(identity.current_user_id(), seller_owner_id, 'COLLECTION')
);

CREATE POLICY pol_marketplace_orders_select
ON marketplace.orders FOR SELECT
USING (
    identity.can_view_owner(identity.current_user_id(), buyer_owner_id, 'PURCHASES')
    OR EXISTS (
        SELECT 1 FROM marketplace.listings l
        WHERE l.listing_id = marketplace.orders.listing_id
          AND identity.can_view_owner(identity.current_user_id(), l.seller_owner_id, 'PURCHASES')
    )
);

CREATE POLICY pol_marketplace_orders_manage
ON marketplace.orders FOR ALL
USING (
    identity.can_manage_owner(identity.current_user_id(), buyer_owner_id, 'PURCHASES')
)
WITH CHECK (
    identity.can_manage_owner(identity.current_user_id(), buyer_owner_id, 'PURCHASES')
);

CREATE POLICY pol_notifications_self
ON operations.notifications FOR SELECT
USING (user_id = identity.current_user_id());
SELECT pg_temp.bt_mark_completed('1100_security/1109_rls_extended.sql');

CREATE POLICY pol_marketplace_listing_items_select
ON marketplace.listing_items FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM marketplace.listings l
        WHERE l.listing_id = marketplace.listing_items.listing_id
    )
);

CREATE POLICY pol_marketplace_listing_items_manage
ON marketplace.listing_items FOR ALL
USING (
    identity.can_manage_owner(
        identity.current_user_id(), seller_owner_id, 'COLLECTION'
    )
)
WITH CHECK (
    identity.can_manage_owner(
        identity.current_user_id(), seller_owner_id, 'COLLECTION'
    )
);

CREATE POLICY pol_marketplace_order_items_select
ON marketplace.order_items FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM marketplace.orders o
        WHERE o.order_id = marketplace.order_items.order_id
    )
);

