-- ============================================================
-- Churn Risk Score — rules-based, daily-computable
-- ------------------------------------------------------------
-- Interview framing: this is deliberately RULE-BASED, not the
-- XGBoost ensemble from Early Churn Detection. Two reasons to
-- say out loud:
--   1) Portfolio differentiation — reusing the ML model here
--      would make this project redundant, not additive.
--   2) Real-world reason — a rules engine is what you'd actually
--      ship on Day 1 of a new product, before you have enough
--      labeled churn outcomes to train anything. ML replaces
--      rules once you have the history; it doesn't replace the
--      need for a Day-1 fallback.
--
-- The -35% activity-drop threshold below is NOT arbitrary — it's
-- the same threshold your Early Churn Detection project validated
-- via Mann-Whitney U / Cox PH as a 3x risk multiplier, and the
-- SME Card Churn project independently found spend-drop >30% as
-- a 6-week-early precursor. Reusing a VALIDATED THRESHOLD across
-- projects (not reusing the model) is exactly the kind of
-- consistency an interviewer wants to hear.
-- ============================================================

WITH ref AS (
    SELECT MAX(activity_date) AS ref_date FROM customer_activity_unified
),

recency AS (
    SELECT customer_id, MAX(activity_date) AS last_activity_date
    FROM customer_activity_unified
    GROUP BY customer_id
),

-- Trailing 3-month activity count vs the prior 3-month window —
-- this LAG-style period comparison is what feeds the "35% drop"
-- rule below. Done via two separate date-filtered CTEs rather
-- than LAG() itself, since LAG needs a sequential row per period
-- and here we want both periods' counts side-by-side per customer.
last_period AS (
    SELECT customer_id, COUNT(*) AS activity_count
    FROM customer_activity_unified, ref
    WHERE activity_date BETWEEN DATE(ref.ref_date, '-3 months') AND ref.ref_date
    GROUP BY customer_id
),

prior_period AS (
    SELECT customer_id, COUNT(*) AS activity_count
    FROM customer_activity_unified, ref
    WHERE activity_date BETWEEN DATE(ref.ref_date, '-6 months') AND DATE(ref.ref_date, '-3 months')
    GROUP BY customer_id
),

combined AS (
    SELECT
        c.customer_id,
        CAST(julianday(ref.ref_date) - julianday(r.last_activity_date) AS INTEGER) AS recency_days,
        COALESCE(lp.activity_count, 0) AS last_3mo_activity,
        COALESCE(pp.activity_count, 0) AS prior_3mo_activity
    FROM crm_customers c
    CROSS JOIN ref
    LEFT JOIN recency r ON r.customer_id = c.customer_id
    LEFT JOIN last_period lp ON lp.customer_id = c.customer_id
    LEFT JOIN prior_period pp ON pp.customer_id = c.customer_id
),

scored AS (
    SELECT
        *,
        CASE
            WHEN prior_3mo_activity = 0 THEN NULL  -- no baseline to compare against — avoid divide-by-zero
            ELSE ROUND(100.0 * (last_3mo_activity - prior_3mo_activity) / prior_3mo_activity, 1)
        END AS activity_change_pct
    FROM combined
)

SELECT
    customer_id,
    recency_days,
    last_3mo_activity,
    prior_3mo_activity,
    activity_change_pct,
    -- Tier language matches Predictive Maintenance / SME Card Churn's
    -- CRITICAL/AT_RISK/MONITOR/HEALTHY convention — same rubric,
    -- reused vocabulary, so a stakeholder reading dashboards across
    -- projects doesn't have to relearn what each tier means.
    CASE
        WHEN recency_days > 90 THEN 'CRITICAL'
        WHEN activity_change_pct IS NOT NULL AND activity_change_pct <= -35 AND recency_days > 30 THEN 'CRITICAL'
        WHEN activity_change_pct IS NOT NULL AND activity_change_pct <= -35 THEN 'AT_RISK'
        WHEN recency_days > 45 THEN 'AT_RISK'
        WHEN activity_change_pct IS NOT NULL AND activity_change_pct <= -15 THEN 'MONITOR'
        ELSE 'HEALTHY'
    END AS churn_risk_tier
FROM scored
ORDER BY
    CASE churn_risk_tier
        WHEN 'CRITICAL' THEN 1 WHEN 'AT_RISK' THEN 2 WHEN 'MONITOR' THEN 3 ELSE 4
    END,
    recency_days DESC;
