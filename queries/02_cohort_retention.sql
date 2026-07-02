-- ============================================================
-- Cohort Retention Grid — month-0 to month-12
-- ------------------------------------------------------------
-- Interview framing (say this out loud in a live SQL round):
-- "A retention query without a date spine silently drops months
-- with zero activity — the curve looks smoother than reality
-- because missing rows aren't the same as zero. The spine forces
-- every (cohort, month_number) combination to exist, so a real
-- drop-off shows up as an explicit 0%, not a gap."
--
-- This is the same discipline as the fraud pipeline's time-based
-- train/test split — don't let silent absence get mistaken for
-- a signal.
-- ============================================================

-- Step 1: Cohort assignment — the month each customer signed up.
WITH cohorts AS (
    SELECT
        customer_id,
        DATE(strftime('%Y-%m-01', signup_date)) AS cohort_month
    FROM crm_customers
),

-- Step 2: Cohort sizes — denominator for every retention % below.
cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS cohort_size
    FROM cohorts
    GROUP BY cohort_month
),

-- Step 3: Date spine — every month_offset (0-12) crossed with every
-- cohort that actually exists. This is what guarantees "no activity"
-- renders as a real 0.00 row instead of a missing one.
month_offsets AS (
    SELECT 0 AS n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3
    UNION SELECT 4 UNION SELECT 5 UNION SELECT 6 UNION SELECT 7
    UNION SELECT 8 UNION SELECT 9 UNION SELECT 10 UNION SELECT 11 UNION SELECT 12
),
spine AS (
    SELECT cs.cohort_month, mo.n AS month_offset
    FROM cohort_sizes cs
    CROSS JOIN month_offsets mo
),

-- Step 4: Actual retained customers per (cohort, month_offset).
-- CAST/julianday diff-in-months trick — SQLite has no native
-- DATE_DIFF(month), so we compute it from julianday() the same
-- way we'd handle a dialect gap in BigQuery vs Postgres.
retained AS (
    SELECT
        c.cohort_month,
        CAST(
            (CAST(strftime('%Y', a.activity_month) AS INTEGER) - CAST(strftime('%Y', c.cohort_month) AS INTEGER)) * 12
            + (CAST(strftime('%m', a.activity_month) AS INTEGER) - CAST(strftime('%m', c.cohort_month) AS INTEGER))
        AS INTEGER) AS month_offset,
        COUNT(DISTINCT c.customer_id) AS retained_customers
    FROM cohorts c
    JOIN customer_monthly_activity a ON a.customer_id = c.customer_id
    GROUP BY c.cohort_month, month_offset
    HAVING month_offset BETWEEN 0 AND 12
)

-- Step 5: LEFT JOIN spine -> retained (spine is authoritative — this
-- is where the zero-fill actually happens), then compute retention %.
SELECT
    s.cohort_month,
    cs.cohort_size,
    s.month_offset,
    COALESCE(r.retained_customers, 0) AS retained_customers,
    ROUND(100.0 * COALESCE(r.retained_customers, 0) / cs.cohort_size, 1) AS retention_pct,
    -- LAG here shows month-over-month retention decay, not just
    -- absolute level — same "rate of change matters more than
    -- level" instinct as the churn early-warning system.
    ROUND(
        100.0 * COALESCE(r.retained_customers, 0) / cs.cohort_size
        - LAG(ROUND(100.0 * COALESCE(r.retained_customers, 0) / cs.cohort_size, 1))
            OVER (PARTITION BY s.cohort_month ORDER BY s.month_offset),
    1) AS pct_point_change_vs_prev_month
FROM spine s
JOIN cohort_sizes cs ON cs.cohort_month = s.cohort_month
LEFT JOIN retained r ON r.cohort_month = s.cohort_month AND r.month_offset = s.month_offset
WHERE cs.cohort_size >= 5   -- drop tiny cohorts, they're noise not signal
ORDER BY s.cohort_month, s.month_offset;
