/*
===============================================================================
 File:           1000_reporting/1000_reporting_views.sql
 Project:        LEGO Collection Platform
 Schema Version: 1.1.0
 PostgreSQL:     16+
 Purpose:        Publish stable read-only reporting projections.
 Depends On:     catalog.items
                 collection.entries
                 collection.instances
                 wanted.wishlist_entries
                 moc.mocs
                 moc.revisions
                 import.jobs
                 marketplace.listings
                 marketplace.orders
                 finance.transactions
                 operations.notifications
 Creates:        reporting.catalog_items
                 reporting.collection_summary
                 reporting.moc_summary
                 reporting.import_runs
                 reporting.marketplace_summary
                 reporting.financial_transactions
                 reporting.notification_summary
===============================================================================
*/
\set ON_ERROR_STOP on
SELECT pg_temp.bt_preflight('1000_reporting/1000_reporting_views.sql', ARRAY['catalog.items', 'collection.entries', 'collection.instances', 'wanted.wishlist_entries', 'moc.mocs', 'moc.revisions', 'import.jobs', 'marketplace.listings', 'marketplace.orders', 'finance.transactions', 'operations.notifications']::text[]);



CREATE VIEW reporting.catalog_items AS
SELECT i.catalog_item_id, i.item_kind, i.canonical_name, i.status,
       i.created_at, i.archived_at
FROM catalog.items i
WHERE i.status <> 'UNRESOLVED_CUSTOM';

CREATE VIEW reporting.collection_summary AS
SELECT e.owner_id,
       count(*) FILTER (WHERE e.status = 'ACTIVE') AS active_entries,
       COALESCE(sum(e.quantity) FILTER (WHERE e.status = 'ACTIVE'), 0) AS active_quantity,
       count(i.collection_instance_id) FILTER (WHERE i.archived_at IS NULL) AS active_instances
FROM collection.entries e
LEFT JOIN collection.instances i
  ON i.collection_entry_id = e.collection_entry_id
GROUP BY e.owner_id;

CREATE VIEW reporting.moc_summary AS
SELECT m.moc_id, m.catalog_item_id, m.owner_id, m.title, m.visibility,
       count(r.moc_revision_id) AS revision_count,
       max(r.revision_number) FILTER (WHERE r.status = 'PUBLISHED') AS latest_published_revision
FROM moc.mocs m
LEFT JOIN moc.revisions r ON r.moc_id = m.moc_id
GROUP BY m.moc_id, m.catalog_item_id, m.owner_id, m.title, m.visibility;

CREATE VIEW reporting.import_runs AS
SELECT j.import_job_id, j.owner_id, j.status, j.created_at,
       j.completed_at, j.failed_at
FROM import.jobs j;

CREATE VIEW reporting.marketplace_summary AS
SELECT l.seller_owner_id,
       count(*) FILTER (WHERE l.status = 'ACTIVE') AS active_listings,
       count(o.order_id) AS order_count,
       COALESCE(sum(o.subtotal), 0) AS order_subtotal
FROM marketplace.listings l
LEFT JOIN marketplace.orders o ON o.listing_id = l.listing_id
GROUP BY l.seller_owner_id;

CREATE VIEW reporting.financial_transactions AS
SELECT t.financial_transaction_id, t.idempotency_key, t.order_id,
       t.description, t.currency, t.posted_by_user_id, t.posted_at,
       sum(le.debit_amount) AS total_debits,
       sum(le.credit_amount) AS total_credits
FROM finance.transactions t
JOIN finance.ledger_entries le USING (financial_transaction_id)
GROUP BY t.financial_transaction_id;

CREATE VIEW reporting.notification_summary AS
SELECT user_id,
       count(*) FILTER (WHERE NOT is_read) AS unread_count,
       max(created_at) AS latest_notification_at
FROM operations.notifications
GROUP BY user_id;
SELECT pg_temp.bt_mark_completed('1000_reporting/1000_reporting_views.sql');
