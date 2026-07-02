"""
Customer 360 — Pipeline Automation Layer
------------------------------------------------------------
Interview framing: this mirrors the Self-Correcting ETL Agent's
core discipline — checkpoint recovery + structured logging — but
solves a DIFFERENT problem. The ETL Agent recovers from CODE
failures (schema/null/type errors) by patching itself. This
runner recovers from RUN failures (a step crashes mid-pipeline)
by resuming from the last completed step instead of restarting
from zero. Same principle (don't lose completed work on a crash),
applied at a different layer of the stack — that's the distinction
to draw if an interviewer asks "isn't this just the ETL agent
again?"

Step-level design:
  1. Every run gets a run_id (timestamp-based).
  2. Each of the 4 SQL steps is checkpointed BEFORE and AFTER
     execution into `pipeline_checkpoints` — same idea as the ETL
     Agent's SQLite checkpoint table, adapted from "code patch
     history" to "pipeline step history".
  3. On --resume, we don't blindly re-run everything: we look up
     the most recent INCOMPLETE run and only re-execute steps that
     didn't reach COMPLETED. This is the actual "self-healing"
     property, not just retry-from-scratch.
  4. Structured logs go to logs/pipeline.jsonl (JSON Lines) — same
     format choice as the Distributed Anomaly Detection Engine's
     JSONL output, so both projects' logs could feed the same
     downstream log aggregator without a format-translation step.
  5. LTV / churn / retention results are MATERIALIZED into real
     tables (not left as views) — a production dashboard or API
     shouldn't have to recompute a 500-customer RFM query on every
     page load. This is the same reasoning as caching model
     predictions instead of scoring on-request in the Fraud API.
"""

import sqlite3
import json
import logging
import argparse
from datetime import datetime, timezone
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
DB_PATH = BASE_DIR / "customer360.db"
QUERIES_DIR = BASE_DIR / "queries"
LOG_DIR = Path(__file__).resolve().parent / "logs"
LOG_DIR.mkdir(exist_ok=True)

# ------------------------------------------------------------------
# Structured JSONL logging — one JSON object per line, same pattern
# as the anomaly detection engine's structured event log.
# ------------------------------------------------------------------
logger = logging.getLogger("customer360_pipeline")
logger.setLevel(logging.INFO)


def log_event(event_type: str, **fields):
    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "event_type": event_type,
        **fields,
    }
    with open(LOG_DIR / "pipeline.jsonl", "a") as f:
        f.write(json.dumps(record) + "\n")
    print(f"[{record['timestamp']}] {event_type}: {fields}")


# ------------------------------------------------------------------
# Pipeline step definitions. materialize_as=None means the step is
# a view/side-effect only (unification); otherwise results get
# written into a real table under that name.
# ------------------------------------------------------------------
STEPS = [
    {"name": "unification",       "sql_file": "01_unification.sql",     "materialize_as": None},
    {"name": "cohort_retention",  "sql_file": "02_cohort_retention.sql","materialize_as": "cohort_retention_results"},
    {"name": "ltv_scoring",       "sql_file": "03_ltv_scoring.sql",     "materialize_as": "ltv_scores"},
    {"name": "churn_risk_score",  "sql_file": "04_churn_risk_score.sql","materialize_as": "churn_risk_scores"},
]


def ensure_checkpoint_table(conn):
    conn.execute("""
        CREATE TABLE IF NOT EXISTS pipeline_checkpoints (
            run_id      TEXT NOT NULL,
            step_name   TEXT NOT NULL,
            status      TEXT NOT NULL,   -- PENDING / RUNNING / COMPLETED / FAILED
            row_count   INTEGER,
            started_at  TEXT,
            completed_at TEXT,
            error_message TEXT,
            PRIMARY KEY (run_id, step_name)
        )
    """)
    conn.commit()


def get_resumable_run(conn):
    """
    Find the most recent run_id that has at least one step NOT
    COMPLETED. Returns None if there's nothing to resume (either no
    runs yet, or the last run fully completed) — mirrors the ETL
    Agent's check for "is there an unresolved checkpoint" before
    deciding whether to patch-and-resume or start clean.
    """
    row = conn.execute("""
        SELECT run_id FROM pipeline_checkpoints
        WHERE status != 'COMPLETED'
        ORDER BY started_at DESC
        LIMIT 1
    """).fetchone()
    return row[0] if row else None


def run_step(conn, run_id: str, step: dict):
    """Execute one pipeline step with before/after checkpointing."""
    name = step["name"]
    started_at = datetime.now(timezone.utc).isoformat()

    conn.execute("""
        INSERT OR REPLACE INTO pipeline_checkpoints
        (run_id, step_name, status, started_at)
        VALUES (?, ?, 'RUNNING', ?)
    """, (run_id, name, started_at))
    conn.commit()
    log_event("step_started", run_id=run_id, step=name)

    try:
        sql = (QUERIES_DIR / step["sql_file"]).read_text()

        if step["materialize_as"] is None:
            # Unification step is a view definition — just execute it.
            conn.executescript(sql)
            row_count = None
        else:
            # Materialize the query result into a real table.
            # DROP + CREATE TABLE AS is deliberately simple over an
            # incremental upsert — at 500 customers, full refresh is
            # cheap and correctness-by-construction beats delta logic
            # complexity. Flag this tradeoff if asked "would this
            # scale to 5M customers?" — no, you'd want incremental
            # materialization at that scale.
            table = step["materialize_as"]
            conn.execute(f"DROP TABLE IF EXISTS {table}")
            conn.execute(f"CREATE TABLE {table} AS {sql}")
            row_count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

        conn.commit()
        completed_at = datetime.now(timezone.utc).isoformat()
        conn.execute("""
            UPDATE pipeline_checkpoints
            SET status='COMPLETED', row_count=?, completed_at=?
            WHERE run_id=? AND step_name=?
        """, (row_count, completed_at, run_id, name))
        conn.commit()
        log_event("step_completed", run_id=run_id, step=name, row_count=row_count)

    except Exception as e:
        completed_at = datetime.now(timezone.utc).isoformat()
        conn.execute("""
            UPDATE pipeline_checkpoints
            SET status='FAILED', completed_at=?, error_message=?
            WHERE run_id=? AND step_name=?
        """, (completed_at, str(e), run_id, name))
        conn.commit()
        log_event("step_failed", run_id=run_id, step=name, error=str(e))
        # Re-raise so the run halts here — downstream steps depend on
        # this one's output (e.g. LTV needs the unification view),
        # so silently continuing would produce wrong numbers, not
        # just missing ones.
        raise


def run_pipeline(resume: bool = False):
    conn = sqlite3.connect(DB_PATH)
    ensure_checkpoint_table(conn)

    if resume:
        run_id = get_resumable_run(conn)
        if run_id is None:
            log_event("resume_noop", detail="no incomplete run found, starting fresh")
            run_id = datetime.now(timezone.utc).strftime("run_%Y%m%dT%H%M%S")
        else:
            log_event("resume_started", run_id=run_id)
    else:
        run_id = datetime.now(timezone.utc).strftime("run_%Y%m%dT%H%M%S")

    completed_steps = {
        row[0] for row in conn.execute(
            "SELECT step_name FROM pipeline_checkpoints WHERE run_id=? AND status='COMPLETED'",
            (run_id,)
        ).fetchall()
    }

    log_event("pipeline_started", run_id=run_id, resume=resume,
              steps_to_skip=list(completed_steps))

    for step in STEPS:
        if step["name"] in completed_steps:
            log_event("step_skipped", run_id=run_id, step=step["name"],
                      reason="already completed in this run")
            continue
        run_step(conn, run_id, step)

    log_event("pipeline_completed", run_id=run_id)
    conn.close()
    return run_id


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Customer 360 pipeline runner")
    parser.add_argument("--resume", action="store_true",
                        help="Resume the most recent incomplete run instead of starting fresh")
    args = parser.parse_args()
    run_pipeline(resume=args.resume)
