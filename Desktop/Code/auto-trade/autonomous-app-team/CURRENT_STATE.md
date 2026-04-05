# Current State — Trading App

> **Purpose:** Quick-start context for any new session. Read this first. Do NOT re-read all sprint history or agent logs.
> **Last updated:** 2026-04-05 (Sprint 10 complete)

---

## Where We Are

- **Sprint:** 10 COMPLETE → Sprint 11 ready to start
- **Tests:** 154 passing, 0 failing
- **Smoke check:** 5/5 endpoints 200 (including new /api/health/signals)
- **Backend:** Rebuilt and redeployed (force-recreate)

---

## Sprint 10 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| S28 | ✅ | Regime-adaptive signal thresholds (BULL/CAUTION/BEAR) wired into both API endpoints |
| S29 | ✅ | Regime stratified analysis script — ran, found T10Y2Y data missing, H12 written |
| S30 | ✅ | /api/health/signals endpoint + AV warning banner in Leaderboard UI |

---

## Top Blockers

1. **T10Y2Y data missing from macro_indicators** — blocks H12 regime stratification AND H4 regime weighting. All 2,714 trades labelled UNKNOWN. Fix: S31 (seed T10Y2Y historical data).
2. **AV key not configured** — news_score stuck at 50.0 for all trades. Leaderboard now shows amber warning. Fix: either configure AV key or build S32 (FRED news fallback).

---

## Next Sprint (Sprint 11) — Candidates

| Story | Priority | Description |
|-------|----------|-------------|
| S31 | P1 | Seed T10Y2Y historical data into macro_indicators (unblocks H12 + H4) |
| S32 | P1 | FRED-based news/sentiment fallback (free, no paid key required) |
| S33 | P2 | Conviction threshold tuning — tighten 60-69 bucket based on H3 U-curve finding |

---

## Key Files

| File | Purpose |
|------|---------|
| `app/scoring/signals.py` | BUY/SELL/HOLD signal generation (regime-adaptive) |
| `app/api/health.py` | /api/health/signals endpoint |
| `app/api/scoring.py` | Universe scoring endpoint (signals annotated here) |
| `app/api/leaderboard.py` | Leaderboard endpoint (signals annotated here) |
| `scripts/regime_stratified_analysis.py` | Regime stratified backtest analysis |
| `scripts/seed_ticker_sectors.py` | Seeds 76 tickers with GICS sectors |
| `tests/api/test_signal_health.py` | 7 health endpoint tests |
| `tests/test_signals.py` | 20 signal tests (9 regime-specific) |
| `frontend/src/pages/Leaderboard.tsx` | Main trading UI (has AV warning banner) |
| `frontend/src/api/client.ts` | TypeScript API client (has SignalHealthResponse + healthAPI) |
| `HYPOTHESES.md` | H1–H12; H12 = T10Y2Y data gap finding |
| `state/project_state.json` | Machine-readable sprint state |

---

## Infrastructure Commands

```bash
# Run tests (requires pip install in container first if not done)
docker compose run --rm backend sh -c "pip install pytest -q && pytest tests/ --ignore=tests/e2e -q"

# Rebuild backend after code changes
docker compose build --no-cache backend && docker compose up -d --force-recreate backend

# Check health endpoint
curl http://localhost:8000/api/health/signals

# Frontend build check
cd frontend && npm run build

# Regime analysis (requires T10Y2Y data to be seeded first)
docker compose run --rm backend python scripts/regime_stratified_analysis.py
```

---

## What NOT To Do

- Do NOT run the Analyst Agent unless 500+ new trades accumulated or win rate shifts >5%
- Do NOT use Health Agent — `/api/health/signals` now covers its function
- Do NOT run weight optimiser (scripts/optimise_weights.py) until AV key configured + ≥30 real news-scored trades
- Do NOT run Playwright E2E — not a sprint gate; manual only
