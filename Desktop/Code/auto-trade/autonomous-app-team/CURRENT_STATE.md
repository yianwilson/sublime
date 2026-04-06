# Current State — Trading App

> **Purpose:** Quick-start context for any new session. Read this first. Do NOT re-read all sprint history or agent logs.
> **Last updated:** 2026-04-07 (Sprint 13 S38 complete)

---

## Where We Are

- **Sprint:** 13 IN PROGRESS (S38 done, S39-S41 queued)
- **Tests:** 208 passing, 0 failing
- **Smoke check:** 5/5 endpoints 200
- **Backend:** Rebuilt and redeployed (S38 clean)

---

## S38 — Auto Paper Trade Simulator (DONE)

`app/services/paper_trade_simulator.py`:
- Runs daily at 21:30 UTC via scheduler
- `enter_daily_trades()` — opens top 5 swing conviction scores, skips ETFs + already-open symbols
- `close_matured_trades()` — auto-closes at 14 days with current price, computes return_pct
- Trades tagged `notes='auto-paper-trade YYYY-MM-DD'` (not 'backfill') — distinguishable in H10 analysis

Forward trades will now accumulate automatically. Rerun `h10_backfill_bias_analysis.py` after ~30 days.

---

## Sprint 12 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| S34 | ✅ | Regime guidance endpoint + Leaderboard banner with live win rates |
| S35 | ✅ | Pre-done — UMCSENT + USEPUINDXD already seeded |
| S36 | ✅ | Pre-done — display was already correct |
| S37 | ✅ | H10 bias script — INSUFFICIENT FORWARD DATA (all back-fill, median hold=10d) |
| S38 | ✅ | Auto paper trade simulator — forward trades will now accumulate daily |

---

## Top Blockers

1. **Forward trades need time to accumulate** — S38 runs nightly. After ~30 days (~150 forward trades) H10/H11 become testable.
2. **Pre-existing TypeScript errors** in Screener.tsx (`deriveVerdict` undefined), Signals.tsx, StockDetail.tsx — fix: S39.
3. **AV key not configured** — news_score uses FRED fallback. Amber warning in Leaderboard.

---

## Next Sprint 13 Remaining Candidates

| Story | Priority | Description |
|-------|----------|-------------|
| S39 | P1 | Fix pre-existing TypeScript errors (Screener.tsx deriveVerdict, Signals.tsx, StockDetail.tsx) |
| S40 | P2 | BEAR regime entry warning — show UI caution for 50-69 conviction entries in BEAR |
| S41 | P2 | H11 exit logic investigation — analyse return distribution by hold duration |
| S42 | P3 | H3 weight re-optimisation — rerun with full FRED sentiment data |

---

## Key Files

| File | Purpose |
|------|---------|
| `app/services/paper_trade_simulator.py` | Auto forward paper trade entry/exit |
| `app/core/scheduler.py` | Scheduled jobs (simulator at 21:30 UTC) |
| `app/api/macro.py` | /api/macro/regime/guidance endpoint |
| `app/scoring/modes/swing.py` | SwingScorer with FRED sentiment fallback |
| `frontend/src/pages/Leaderboard.tsx` | Main trading UI (upgraded regime banner) |
| `scripts/h10_backfill_bias_analysis.py` | H10 bias investigation (rerun after 30 days) |
| `scripts/regime_stratified_analysis.py` | Regime stratified backtest analysis |
| `HYPOTHESES.md` | H1–H12; H12 = regime-conviction interaction data |

---

## Infrastructure Commands

```bash
# Run tests
docker compose run --rm backend sh -c "pip install pytest -q 2>/dev/null && python -m pytest tests/ --ignore=tests/e2e -q 2>&1" | tail -3

# Rebuild backend after code changes
docker compose build --no-cache backend && docker compose up -d --force-recreate backend

# Manually trigger paper trade simulator (for testing)
docker compose run --rm backend python -c "
from app.core.db import SessionLocal
from app.services.paper_trade_simulator import run_simulator
db = SessionLocal()
print(run_simulator(db))
db.close()
"

# Check H10 bias after forward trades accumulate
docker compose run --rm backend python scripts/h10_backfill_bias_analysis.py
```

---

## What NOT To Do

- Do NOT run the Analyst Agent until 500+ forward trades OR win rate shifts >5%
- Do NOT run Playwright E2E — not a sprint gate; manual only
- Do NOT run weight optimiser until ≥30 FRED-scored trades accumulated
