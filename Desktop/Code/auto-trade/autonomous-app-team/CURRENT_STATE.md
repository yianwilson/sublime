# Current State — Trading App

> **Purpose:** Quick-start context for any new session. Read this first. Do NOT re-read all sprint history or agent logs.
> **Last updated:** 2026-04-07 (Sprint 12 complete)

---

## Where We Are

- **Sprint:** 12 COMPLETE → Sprint 13 ready to start
- **Tests:** 197 passing, 0 failing
- **Smoke check:** 5/5 endpoints 200 (including new /api/macro/regime/guidance)
- **Backend:** Rebuilt and redeployed (Sprint 12 clean)

---

## Sprint 12 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| S34 | ✅ | Regime guidance endpoint + TypeScript types + upgraded Leaderboard banner with live win rates |
| S35 | ✅ | Pre-done — UMCSENT (38 rows) + USEPUINDXD (1,188 rows) already seeded from Sprint 11 agent work |
| S36 | ✅ | Pre-done — regime analysis display was already correct, tests guard it |
| S37 | ✅ | H10 backfill bias script — verdict: INSUFFICIENT FORWARD DATA (all 2,714 trades are back-fill) |

---

## Key Finding — H10 Bias Analysis (S37)

- All 2,714 trades are back-fill with fixed 10-day hold periods
- BEAR <40 win rate: 64.1% (back-fill only — no forward trades yet)
- Hold_days: min=10, median=10, max=13 — **no look-ahead bias signal**
- Verdict: cannot confirm or deny until 30+ forward BEAR <40 trades accumulate

---

## Top Blockers

1. **No forward paper trades** — all 2,714 trades are back-filled. H10 and H11 cannot be validated until users enter real forward trades via the UI.
2. **Pre-existing TypeScript errors** in Screener.tsx (`deriveVerdict` undefined), Signals.tsx, StockDetail.tsx — frontend build has warnings but app runs. Fix: S38.
3. **AV key not configured** — news_score uses FRED fallback. Amber warning in Leaderboard. No fix planned (AV is paid).

---

## Next Sprint (Sprint 13) — Candidates

| Story | Priority | Description |
|-------|----------|-------------|
| S38 | P1 | Fix pre-existing TypeScript errors in Screener.tsx, Signals.tsx, StockDetail.tsx |
| S39 | P2 | BEAR regime entry filter — show UI warning on leaderboard for 50-69 conviction entries in BEAR regime |
| S40 | P2 | H11 exit logic investigation — analyse return distribution by hold duration to improve win/loss ratio |
| S41 | P3 | H3 weight re-optimisation — rerun with FRED sentiment data now fully seeded |

---

## Key Files

| File | Purpose |
|------|---------|
| `app/api/macro.py` | /api/macro/regime + /api/macro/regime/guidance endpoints |
| `app/scoring/signals.py` | BUY/SELL/HOLD signal generation (regime-adaptive) |
| `app/scoring/modes/swing.py` | SwingScorer with FRED sentiment fallback |
| `app/services/fred_sentiment.py` | FredSentimentService — UMCSENT + VIXCLS + USEPUINDXD composite |
| `app/services/macro_regime.py` | MacroRegimeService — BULL/CAUTION/BEAR |
| `frontend/src/api/client.ts` | TypeScript API client (RegimeGuidance types + macroAPI.getGuidance) |
| `frontend/src/pages/Leaderboard.tsx` | Main trading UI (upgraded regime banner, AV warning) |
| `scripts/h10_backfill_bias_analysis.py` | H10 backfill bias investigation script |
| `scripts/regime_stratified_analysis.py` | Regime stratified backtest analysis |
| `scripts/seed_fred_series.py` | Generic FRED series historical seeder |
| `HYPOTHESES.md` | H1–H12; H12 updated with real regime data |
| `state/project_state.json` | Machine-readable sprint state |

---

## Infrastructure Commands

```bash
# Run tests
docker compose run --rm backend sh -c "pip install pytest -q 2>/dev/null && python -m pytest tests/ --ignore=tests/e2e -q 2>&1" | tail -3

# Rebuild backend after code changes
docker compose build --no-cache backend && docker compose up -d --force-recreate backend

# Run H10 bias analysis
docker compose run --rm backend python scripts/h10_backfill_bias_analysis.py

# Run regime analysis (real data)
docker compose run --rm backend python scripts/regime_stratified_analysis.py

# Frontend build check
cd frontend && npm run build
```

---

## What NOT To Do

- Do NOT run the Analyst Agent until 500+ new forward trades OR win rate shifts >5%
- Do NOT run Playwright E2E — not a sprint gate; manual only
- Do NOT run weight optimiser until ≥30 FRED-scored trades accumulated (still zero forward trades)
