# Real-Time Customer 360 Platform — Build Log

## Status: Steps 1-7 complete and verified

| Step | What | File |
|---|---|---|
| 1 | Schema — 5 sources + CRM hub | `schema.sql` |
| 2 | Synthetic data — 500 customers, 5 behavioral profiles | `generate_data.py` |
| 3 | Unification layer (UNION ALL down to customer x month) | `queries/01_unification.sql` |
| 4 | Cohort retention grid (date spine + LAG) | `queries/02_cohort_retention.sql` |
| 5 | LTV scoring — RFM (NTILE quintiles) + source diversity | `queries/03_ltv_scoring.sql` |
| 6 | Churn risk score — rules-based, 4-tier | `queries/04_churn_risk_score.sql` |
| 7 | Automation — checkpointed, resumable pipeline runner | `automation/pipeline_runner.py` |

## How to run
```bash
python3 generate_data.py                        # one-time: builds customer360.db
python3 automation/pipeline_runner.py            # fresh run of all 4 steps
python3 automation/pipeline_runner.py --resume   # resume most recent incomplete run
```
Structured logs land in `automation/logs/pipeline.jsonl` (one JSON object
per event — same format as the Distributed Anomaly Detection Engine's logs).

## Verified results (not just written, actually run)
- **Data**: 500 customers, 2,648 transactions, 5,403 events, 1,883 web
  sessions, 783 social, 327 support interactions across 5 behavioral profiles
- **Cohort retention**: date-spine zero-fills confirmed — no missing months
- **LTV**: 114 Champion, 119 Loyal, 67 At Risk, 67 Developing, 133 Lost;
  top Champion ≈ ₹2.3L estimated LTV, Lost customers correctly floor at ₹0
- **Churn risk**: 233 CRITICAL / 42 AT_RISK / 24 MONITOR / 201 HEALTHY —
  CRITICAL customers are almost entirely the early_churner/dabbler profiles
  seeded in step 2, confirming the rules find real signal, not noise
- **Automation crash-recovery test**: seeded a checkpoint table simulating
  a run that failed after step 2, called `--resume`, confirmed it skipped
  the 2 completed steps and only re-executed the 2 remaining ones

## Design decisions worth remembering for interviews

**Data & unification (steps 1-4)**
- Synthetic data has 5 behavioral profiles with decaying activity
  probability, not random noise — a retention curve needs real
  churn/loyalty signal baked in, or the cohort grid is flat and
  uninteresting. Same principle as the Telco-AI-Suite CDR generator.
- Unification = UNION ALL down to `(customer_id, activity_date)`, not a
  wide join. Different sources have different grains (a transaction is
  an event, a web session is a duration) — forcing them into one row
  shape loses information. Normalize to the lowest common denominator
  first, reason on top of that.
- Date spine is what makes "zero activity" a real 0.00% row instead of
  a silently missing one. Built via `CROSS JOIN` of cohorts x
  month_offsets (0-12), then `LEFT JOIN` the actual counts onto that
  spine — the spine is authoritative, the data fills in.
- `LAG()` computes point-to-point retention change, not just level —
  mirrors the "rate of change over absolute value" instinct from the
  churn early-warning system (35% activity drop = 3x risk).

**LTV & churn scoring (steps 5-6)**
- LTV is a heuristic (RFM x segment-based horizon), not ML — deliberate
  choice so this stays a pure-SQL project and doesn't duplicate the
  XGBoost work already done in Early Churn Detection / Credit Default.
  The honest weak point to name if asked "how would you improve this":
  the remaining-lifetime horizon is an assumption, not fitted — a Cox
  PH survival model (as used in Early Churn) would replace that
  assumption with data.
- Churn risk reuses a VALIDATED THRESHOLD, not a model — the -35%
  activity-drop cutoff is the same one Early Churn Detection confirmed
  via Mann-Whitney U / Cox PH as a 3x risk multiplier, and SME Card
  Churn independently found (spend drop >30%, 6-week precursor).
  Carrying a validated number across projects, without carrying the
  model that produced it, is what shows portfolio coherence rather
  than disconnected repos.
- Tier vocabulary (CRITICAL/AT_RISK/MONITOR/HEALTHY) intentionally
  matches Predictive Maintenance and SME Card Churn's tiering
  convention — same rubric, reused language, one less thing a
  stakeholder has to relearn per dashboard.

**Automation (step 7)**
- Checkpointing solves a different problem than the ETL Agent's — the
  ETL Agent recovers from CODE failures (patches bad logic via Ollama).
  This recovers from RUN failures (a step crashes mid-pipeline) by
  resuming from the last COMPLETED step instead of restarting from
  zero. Same "don't lose completed work on crash" principle, different
  layer — worth drawing that distinction if asked "isn't this the same
  project again?"
- Results are materialized into real tables, not left as views — a
  dashboard/API shouldn't recompute a 500-row RFM query on every page
  load. Same reasoning as caching model predictions instead of scoring
  on-request in the Fraud API.
- Full DROP+CREATE per run, not incremental upsert — correct at 500
  customers, and simpler is safer than delta-logic bugs. Flag this
  explicitly if asked "would this scale to 5M customers?" — no, that's
  where you'd need incremental materialization or a proper orchestrator
  (Airflow/Dagster) instead of a single Python script.

## Next steps (not yet built)
- Step 8 (optional): Thin FastAPI/Streamlit query layer over the
  materialized tables
