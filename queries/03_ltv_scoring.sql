-- ============================================================
-- LTV Scoring — RFM + Behavioral Signal
-- ------------------------------------------------------------
-- Interview framing: this is a HEURISTIC LTV, not a predictive
-- ML LTV. Deliberately kept as pure SQL — the point of this
-- project is showing you can generate a usable business score
-- with zero model dependency. Your ML-based risk scoring
-- (XGBoost + SHAP, Early Churn / Credit Default / Predictive
-- Maintenance) is a DIFFERENT tool for a DIFFERENT situation:
-- reach for RFM when you need a fast, explainable segmentation
-- with no labeled outcome data yet; reach for XGBoost once you
-- have enough history to learn non-linear interactions and want
-- calibrated probabilities (PR-AUC, SHAP attribution) instead of
-- rule-based tiers. Same reason LR stayed champion over XGBoost
-- in Credit Default when XGBoost failed the Gini gate — simpler
-- and more explainable wins when the extra complexity isn't
-- earning its keep.
--
-- NTILE(5) is the standard RFM quintile window function — same
-- window-function family as LAG in the retention grid, applied
-- to a ranking problem instead of a sequential one.
-- ============================================================

WITH ref AS (
    -- "Today" = latest activity date in the simulated dataset.
    SELECT MAX(activity_date) AS ref_date FROM customer_activity_unified
),

-- Recency: days since last touch, ANY source (not just transactions —
-- a customer who's still browsing/engaging isn't "recent" by spend
-- alone; this is the whole point of unifying 5 sources).
recency AS (
    SELECT customer_id, MAX(activity_date) AS last_activity_date
    FROM customer_activity_unified
    GROUP BY customer_id
),

-- Frequency: distinct active months in the trailing 6 months.
frequency AS (
    SELECT customer_id, COUNT(DISTINCT DATE(strftime('%Y-%m-01', activity_date))) AS frequency_months
    FROM customer_activity_unified, ref
    WHERE activity_date >= DATE(ref.ref_date, '-6 months')
    GROUP BY customer_id
),

-- Monetary: actual ₹ spend in the trailing 6 months (transactions only —
-- this is the one signal that has to come from a single, trustworthy source).
monetary AS (
    SELECT customer_id, SUM(amount) AS monetary_6mo
    FROM transactions, ref
    WHERE transaction_date >= DATE(ref.ref_date, '-6 months')
    GROUP BY customer_id
),

-- Behavioral signal beyond classic RFM: how many DIFFERENT sources
-- this customer touches. A customer active on transactions + social +
-- web is stickier than one active on transactions alone, even at
-- equal spend — this is the "5+ disparate sources" value-add over
-- a spend-only LTV model.
diversity AS (
    SELECT customer_id, COUNT(DISTINCT source) AS source_diversity
    FROM customer_activity_unified
    GROUP BY customer_id
),

rfm_base AS (
    SELECT
        c.customer_id,
        CAST(julianday(ref.ref_date) - julianday(r.last_activity_date) AS INTEGER) AS recency_days,
        COALESCE(f.frequency_months, 0) AS frequency_months,
        COALESCE(m.monetary_6mo, 0) AS monetary_6mo,
        COALESCE(d.source_diversity, 0) AS source_diversity
    FROM crm_customers c
    CROSS JOIN ref
    LEFT JOIN recency r ON r.customer_id = c.customer_id
    LEFT JOIN frequency f ON f.customer_id = c.customer_id
    LEFT JOIN monetary m ON m.customer_id = c.customer_id
    LEFT JOIN diversity d ON d.customer_id = c.customer_id
),

-- Quintile scoring: NTILE(5) splits customers into 5 equal-sized
-- buckets ranked by each metric. Recency is inverted (6 - NTILE)
-- because FEWER days-since-last-activity = BETTER, but NTILE
-- ranks ascending by default.
rfm_scored AS (
    SELECT
        *,
        6 - NTILE(5) OVER (ORDER BY recency_days ASC)      AS r_score,
        NTILE(5) OVER (ORDER BY frequency_months ASC)      AS f_score,
        NTILE(5) OVER (ORDER BY monetary_6mo ASC)          AS m_score
    FROM rfm_base
)

SELECT
    customer_id,
    recency_days,
    frequency_months,
    ROUND(monetary_6mo, 2)     AS monetary_6mo_inr,
    source_diversity,
    r_score, f_score, m_score,
    (r_score + f_score + m_score) AS rfm_total,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champion'
        WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal'
        WHEN r_score <= 2 AND f_score >= 3                  THEN 'At Risk (was active)'
        WHEN r_score <= 2 AND f_score <= 2                  THEN 'Lost'
        ELSE 'Developing'
    END AS rfm_segment,
    -- Heuristic LTV = avg monthly spend x an assumed remaining-lifetime
    -- horizon that varies by segment. This horizon assumption is the
    -- explicit, callable-out weak point of a rules-based LTV vs a
    -- survival-model based one (Cox PH, as used in Early Churn) —
    -- say that out loud if asked "how would you improve this."
    ROUND(
        (monetary_6mo / 6.0) *
        CASE
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 24
            WHEN r_score >= 3 AND f_score >= 3                  THEN 12
            WHEN r_score <= 2 AND f_score >= 3                  THEN 4
            WHEN r_score <= 2 AND f_score <= 2                  THEN 1
            ELSE 6
        END
    , 0) AS estimated_ltv_inr
FROM rfm_scored
ORDER BY estimated_ltv_inr DESC;
