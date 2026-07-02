"""
Customer 360 — Synthetic Data Generator
----------------------------------------
Same design pattern as Telco-AI-Suite's synthetic CDR generator:
we don't generate pure random noise, we generate customers with
DISTINCT BEHAVIORAL PROFILES so the downstream cohort/LTV/churn
queries have real signal to find (a retention grid on random data
is a flat line — not interview-worthy).

500 customers / 200 "items" ratio deliberately matches the GCP
Recommender scale, so the two projects tell a consistent story
about the size of systems you've operated on.
"""

import sqlite3
import uuid
import random
from datetime import date, datetime, timedelta

random.seed(42)  # reproducibility — same reason Fraud API benchmarks were seeded

DB_PATH = "customer360.db"
N_CUSTOMERS = 500
SIM_START = date(2024, 1, 1)
SIM_END = date(2025, 12, 31)

# ------------------------------------------------------------------
# Step 1: Define behavioral profiles (mirrors Telco's 5-profile design)
# Each profile controls activity FREQUENCY and DECAY — the two levers
# that actually produce a differentiated retention curve later.
# ------------------------------------------------------------------
PROFILES = {
    "loyal_high_value":   {"weight": 0.15, "monthly_activity_p": 0.90, "decay": 0.02, "txn_amount": (2000, 8000)},
    "steady_regular":     {"weight": 0.30, "monthly_activity_p": 0.65, "decay": 0.05, "txn_amount": (500, 2000)},
    "seasonal":           {"weight": 0.20, "monthly_activity_p": 0.40, "decay": 0.03, "txn_amount": (300, 1500)},
    "early_churner":      {"weight": 0.20, "monthly_activity_p": 0.55, "decay": 0.35, "txn_amount": (200, 900)},
    "one_time_dabbler":   {"weight": 0.15, "monthly_activity_p": 0.20, "decay": 0.60, "txn_amount": (100, 500)},
}

REGIONS = ["North", "South", "East", "West"]
SEGMENTS = ["enterprise", "smb", "individual"]
CHANNELS_ACQ = ["organic", "paid_search", "referral", "social_ads", "partner"]
CHANNELS_TXN = ["web", "mobile", "store"]
CATEGORIES = ["electronics", "apparel", "home", "grocery", "beauty"]
DEVICES = ["mobile", "desktop", "tablet"]
PLATFORMS = ["instagram", "twitter", "linkedin"]
ENGAGEMENT_TYPES = ["like", "comment", "share"]
SUPPORT_CHANNELS = ["email", "chat", "phone"]
EVENT_TYPES = ["login", "add_to_cart", "wishlist_add", "search", "support_ticket_opened"]


def months_between(d1: date, d2: date):
    """Generate the first-of-month date for every month between d1 and d2 inclusive."""
    cur = date(d1.year, d1.month, 1)
    out = []
    while cur <= d2:
        out.append(cur)
        if cur.month == 12:
            cur = date(cur.year + 1, 1, 1)
        else:
            cur = date(cur.year, cur.month + 1, 1)
    return out


def random_day_in_month(month_start: date):
    if month_start.month == 12:
        next_month = date(month_start.year + 1, 1, 1)
    else:
        next_month = date(month_start.year, month_start.month + 1, 1)
    days_in_month = (next_month - month_start).days
    return month_start + timedelta(days=random.randint(0, days_in_month - 1))


def build_customers():
    """Step 2a: Create the CRM dimension — every other table's foreign key anchor."""
    customers = []
    profile_names = list(PROFILES.keys())
    weights = [PROFILES[p]["weight"] for p in profile_names]

    for _ in range(N_CUSTOMERS):
        cust_id = str(uuid.uuid4())[:8]
        profile = random.choices(profile_names, weights=weights, k=1)[0]
        # Signup spread across first 18 months so cohorts have varying lifespans —
        # required for a real month-0..month-12 retention grid (need customers
        # who've had 12+ months to actually churn or stay).
        signup_offset = random.randint(0, 545)
        signup_date = SIM_START + timedelta(days=signup_offset)
        customers.append({
            "customer_id": cust_id,
            "signup_date": signup_date,
            "segment": random.choice(SEGMENTS),
            "region": random.choice(REGIONS),
            "acquisition_channel": random.choice(CHANNELS_ACQ),
            "profile": profile,  # kept in-memory only, not written to CRM table (that'd be leakage —
                                  # same discipline as Fraud API keeping SHAP features out of the label column)
        })
    return customers


def build_activity(customers):
    """
    Step 2b: For each customer, walk month-by-month from signup to SIM_END.
    Each month, roll a probability (profile's monthly_activity_p, decayed
    over tenure) to decide if they're "active" that month. If active,
    generate rows across all 5 sources for that month.

    This decay-based walk is what CREATES the retention curve shape —
    the SQL later just measures what we've already engineered here.
    """
    transactions, events, web_sessions, social, support = [], [], [], [], []

    for cust in customers:
        profile = PROFILES[cust["profile"]]
        months = months_between(cust["signup_date"], SIM_END)

        for month_idx, month_start in enumerate(months):
            # Probability decays each month since signup — this IS the churn mechanism
            active_p = profile["monthly_activity_p"] * ((1 - profile["decay"]) ** month_idx)
            if random.random() > active_p:
                continue  # customer inactive this month across all sources

            n_events_this_month = random.randint(1, 3)

            # --- Transactions (0-2 per active month) ---
            for _ in range(random.randint(0, 2)):
                transactions.append({
                    "transaction_id": str(uuid.uuid4())[:10],
                    "customer_id": cust["customer_id"],
                    "transaction_date": random_day_in_month(month_start),
                    "amount": round(random.uniform(*profile["txn_amount"]), 2),
                    "product_category": random.choice(CATEGORIES),
                    "channel": random.choice(CHANNELS_TXN),
                })

            # --- Events ---
            for _ in range(n_events_this_month):
                events.append({
                    "event_id": str(uuid.uuid4())[:10],
                    "customer_id": cust["customer_id"],
                    "event_type": random.choice(EVENT_TYPES),
                    "event_timestamp": datetime.combine(
                        random_day_in_month(month_start),
                        datetime.min.time()
                    ) + timedelta(hours=random.randint(0, 23)),
                })

            # --- Web sessions ---
            if random.random() < 0.7:
                web_sessions.append({
                    "session_id": str(uuid.uuid4())[:10],
                    "customer_id": cust["customer_id"],
                    "session_date": random_day_in_month(month_start),
                    "duration_seconds": random.randint(30, 1800),
                    "pages_viewed": random.randint(1, 15),
                    "device": random.choice(DEVICES),
                })

            # --- Social engagement ---
            if random.random() < 0.3:
                social.append({
                    "engagement_id": str(uuid.uuid4())[:10],
                    "customer_id": cust["customer_id"],
                    "engagement_date": random_day_in_month(month_start),
                    "platform": random.choice(PLATFORMS),
                    "engagement_type": random.choice(ENGAGEMENT_TYPES),
                })

            # --- Support interactions (rarer) ---
            if random.random() < 0.12:
                resolved = 1 if random.random() < 0.85 else 0
                support.append({
                    "interaction_id": str(uuid.uuid4())[:10],
                    "customer_id": cust["customer_id"],
                    "interaction_date": random_day_in_month(month_start),
                    "channel": random.choice(SUPPORT_CHANNELS),
                    "resolved": resolved,
                    "csat_score": random.randint(1, 5) if resolved and random.random() < 0.6 else None,
                })

    return transactions, events, web_sessions, social, support


def load_to_sqlite(customers, transactions, events, web_sessions, social, support):
    """Step 3: Load everything into SQLite against the schema.sql DDL."""
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()

    with open("schema.sql") as f:
        cur.executescript(f.read())

    cur.executemany(
        "INSERT INTO crm_customers VALUES (?,?,?,?,?)",
        [(c["customer_id"], c["signup_date"].isoformat(), c["segment"], c["region"], c["acquisition_channel"])
         for c in customers]
    )
    cur.executemany(
        "INSERT INTO transactions VALUES (?,?,?,?,?,?)",
        [(t["transaction_id"], t["customer_id"], t["transaction_date"].isoformat(),
          t["amount"], t["product_category"], t["channel"]) for t in transactions]
    )
    cur.executemany(
        "INSERT INTO events VALUES (?,?,?,?)",
        [(e["event_id"], e["customer_id"], e["event_type"], e["event_timestamp"].isoformat()) for e in events]
    )
    cur.executemany(
        "INSERT INTO web_sessions VALUES (?,?,?,?,?,?)",
        [(w["session_id"], w["customer_id"], w["session_date"].isoformat(),
          w["duration_seconds"], w["pages_viewed"], w["device"]) for w in web_sessions]
    )
    cur.executemany(
        "INSERT INTO social_engagement VALUES (?,?,?,?,?)",
        [(s["engagement_id"], s["customer_id"], s["engagement_date"].isoformat(),
          s["platform"], s["engagement_type"]) for s in social]
    )
    cur.executemany(
        "INSERT INTO support_interactions VALUES (?,?,?,?,?,?)",
        [(s["interaction_id"], s["customer_id"], s["interaction_date"].isoformat(),
          s["channel"], s["resolved"], s["csat_score"]) for s in support]
    )

    conn.commit()

    # Quick sanity counts — verify before moving to querying
    for tbl in ["crm_customers", "transactions", "events", "web_sessions", "social_engagement", "support_interactions"]:
        n = cur.execute(f"SELECT COUNT(*) FROM {tbl}").fetchone()[0]
        print(f"{tbl:25s} {n:>8,} rows")

    conn.close()


if __name__ == "__main__":
    customers = build_customers()
    transactions, events, web_sessions, social, support = build_activity(customers)
    load_to_sqlite(customers, transactions, events, web_sessions, social, support)
