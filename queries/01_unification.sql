-- ============================================================
-- Unification Layer
-- ------------------------------------------------------------
-- Interview framing: "unification" doesn't mean merging schemas —
-- it means answering ONE question ("was this customer active in
-- month X?") using signals that live in 5 structurally different
-- tables. We deliberately don't try to force transactions, web
-- sessions, and social likes into one row shape. We UNION them
-- down to the lowest common denominator: (customer_id, activity_date).
-- Same instinct as Supplier Risk's entity resolution — normalize
-- BEFORE you try to reason across sources, not after.
-- ============================================================

DROP VIEW IF EXISTS customer_activity_unified;

CREATE VIEW customer_activity_unified AS
SELECT customer_id, transaction_date AS activity_date, 'transaction' AS source FROM transactions
UNION ALL
SELECT customer_id, DATE(event_timestamp) AS activity_date, 'event' AS source FROM events
UNION ALL
SELECT customer_id, session_date AS activity_date, 'web_session' AS source FROM web_sessions
UNION ALL
SELECT customer_id, engagement_date AS activity_date, 'social' AS source FROM social_engagement
UNION ALL
SELECT customer_id, interaction_date AS activity_date, 'support' AS source FROM support_interactions;

-- Collapse to one row per customer per active month (any source counts).
-- strftime('%Y-%m-01',...) is the SQLite equivalent of BigQuery's
-- DATE_TRUNC(activity_date, MONTH) — same normalization trick used
-- in the fraud API's daily aggregation windows.
DROP VIEW IF EXISTS customer_monthly_activity;

CREATE VIEW customer_monthly_activity AS
SELECT DISTINCT
    customer_id,
    DATE(strftime('%Y-%m-01', activity_date)) AS activity_month
FROM customer_activity_unified;
