-- ============================================================
-- Customer 360 Platform — Schema
-- SQLite here mirrors BigQuery (same pattern as GCP Recommender:
-- SQLite = BigQuery stand-in, swap-ready via connection string only)
-- ============================================================

-- Master customer dimension (the "hub" — every source joins back to this)
CREATE TABLE crm_customers (
    customer_id     TEXT PRIMARY KEY,
    signup_date     DATE NOT NULL,
    segment         TEXT NOT NULL,      -- 'enterprise', 'smb', 'individual'
    region          TEXT NOT NULL,
    acquisition_channel TEXT NOT NULL
);

-- Source 1: Transactions
CREATE TABLE transactions (
    transaction_id  TEXT PRIMARY KEY,
    customer_id     TEXT NOT NULL,
    transaction_date DATE NOT NULL,
    amount          REAL NOT NULL,
    product_category TEXT NOT NULL,
    channel         TEXT NOT NULL,       -- 'web', 'mobile', 'store'
    FOREIGN KEY (customer_id) REFERENCES crm_customers(customer_id)
);

-- Source 2: Product/behavioral events
CREATE TABLE events (
    event_id        TEXT PRIMARY KEY,
    customer_id     TEXT NOT NULL,
    event_type      TEXT NOT NULL,       -- 'login','add_to_cart','support_ticket', etc.
    event_timestamp DATETIME NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES crm_customers(customer_id)
);

-- Source 3: Web sessions
CREATE TABLE web_sessions (
    session_id      TEXT PRIMARY KEY,
    customer_id     TEXT NOT NULL,
    session_date    DATE NOT NULL,
    duration_seconds INTEGER NOT NULL,
    pages_viewed    INTEGER NOT NULL,
    device          TEXT NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES crm_customers(customer_id)
);

-- Source 4: Social engagement
CREATE TABLE social_engagement (
    engagement_id   TEXT PRIMARY KEY,
    customer_id     TEXT NOT NULL,
    engagement_date DATE NOT NULL,
    platform        TEXT NOT NULL,       -- 'instagram','twitter','linkedin'
    engagement_type TEXT NOT NULL,       -- 'like','comment','share'
    FOREIGN KEY (customer_id) REFERENCES crm_customers(customer_id)
);

-- Source 5: Support/service interactions
CREATE TABLE support_interactions (
    interaction_id  TEXT PRIMARY KEY,
    customer_id     TEXT NOT NULL,
    interaction_date DATE NOT NULL,
    channel         TEXT NOT NULL,       -- 'email','chat','phone'
    resolved        INTEGER NOT NULL,    -- 0/1, SQLite has no native BOOLEAN
    csat_score      INTEGER,             -- 1-5, nullable (not every ticket gets rated)
    FOREIGN KEY (customer_id) REFERENCES crm_customers(customer_id)
);
