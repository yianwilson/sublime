# Current State — Trading App

> **Purpose:** Quick-start context for any new session. Read this first. Do NOT re-read all sprint history or agent logs.
> **Last updated:** 2026-04-25 (Sprint 22 COMPLETE + bug fixes committed)

---

## Where We Are

- **Sprint:** 22 COMPLETE (+ post-sprint bug fixes) — starting Sprint 23 next session
- **Tests:** 292 passing, 0 failing
- **Branch:** minimal-clean (pushed — commit 609baec3)

---

## Sprint 22 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Curated Watchlist UI | ✅ | `GET /api/watchlist/curated` endpoint. Watchlist page gains "Curated Quality Tiers" tab: AI_CORE/AI_INFRA/GROWTH/QUALITY sections with TierBadge, live conviction + tech ScoreBars, signal chip, rationale, link to StockDetail. 6 new tests. |
| Bug: All SELL signals in curated watchlist | ✅ | Removed percentile-based SELL condition from `signals.py`. SELL is now conviction-only. Percentile gates BUY confirmation only. |
| Bug: Screener showing overbought stocks as Buy | ✅ | Screener now post-filters for dip+RSI before scoring; Buy verdict requires `dip_met AND rsi_met`; target uses `high_3m` only if ≥8% above close. |

---

## Sprint 21 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| StockDetail component scores + tier badge | ✅ | TierBadge added to stock header. New "Component Scores" card with score bars (Trend/Dip/Catalyst/RS/Innovation/Sanity/Momentum/Breakout Str./Volume) — shows only populated components, same green/amber/slate coloring as leaderboard. |

---

## Sprint 20 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| ScoreBar component + Innovation column | ✅ | Inline `ScoreBar` mini-bar (green ≥60 / amber 40–59 / slate <40) replaces all plain-number component score cells. Innovation column added to swing mode. All 7 swing + 5 breakout component columns now visual. |

---

## Sprint 19 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Tier + component scores in leaderboard | ✅ | `TierBadge` in Chips.tsx. Tier shown next to symbol in Leaderboard. All component scores (trend/dip/catalyst/rs/innovation/sanity + breakout set) now populated from backend. `ScoreResponse` + `SwingScore` TS interface both carry `tier`. |

---

## Sprint 18 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Quality dip in daily note | ✅ | Top 5 quality dip picks added to Obsidian daily note (above swing/breakout picks). Shows tier, drawdown%, dip score, RS, 200MA flag |

---

## Sprint 17 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Quality Dip Screener | ✅ | New "Quality Dip" tab in screener UI. AI_CORE/AI_INFRA/GROWTH + 5–25% dip + RS ≥ 35. GET /api/screener/quality-dip |

### Quality Dip Screener Design

**Algorithm:** `dip_quality_score = dip_score×0.5 + rs_score×0.3 + tier_rank×0.2`

Tier ranks: AI_CORE=100, AI_INFRA=85, GROWTH=70

**Filters:** Tier ∈ {AI_CORE, AI_INFRA, GROWTH} · Drawdown 3m: −5% to −25% · RS ≥ 35

---

## Sprint 16 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Innovation scorer fix | ✅ | Tier-based quality signal (AI_CORE=95 … AVOID=35). Momentum has zero effect |
| S47 position sizing | ✅ | 1.5%–5% conviction-scaled (was flat 3%) |
| Sector ETF safety | ✅ | AVOID tier no longer disables Ticker.enabled |
| UI chip system | ✅ | Shared Chips.tsx across all pages |

---

## Key Change — H16 Regime-Dependent Weights

| Regime | trend | dip | catalyst | rs |
|--------|-------|-----|----------|----|
| BULL | 40 | 5 | 33 | 8 |
| CAUTION | 25 | 25 | 28 | 7 |
| BEAR | 5 | 40 | 30 | 5 |

---

## Signal Thresholds (post-S22 fix)

| Regime | buy_score | buy_pct | sell_score |
|--------|-----------|---------|------------|
| BULL | 75 | 90 | 60 |
| CAUTION | 70 | 90 | 55 |
| BEAR | 65 | 90 | 50 |

SELL = conviction < sell_score only (percentile no longer triggers SELL)

---

## Forward Trade Pipeline

- Simulator entering top-5 swing + top-3 breakout daily since Sprint 13/15.
- Swing tags: `auto-paper-trade YYYY-MM-DD`
- Breakout tags: `auto-paper-trade-breakout YYYY-MM-DD`
- H15 (breakout vs swing) testable ~2026-05-21 (30 days of forward breakout trades)
- Full Analyst trigger: 500+ forward trades OR win rate shifts >5%

---

## Top Blockers

1. **Forward trades need time** — ~3 months to meaningful forward data.
2. **AV key not configured** — news_score uses FRED fallback.
3. **Accuracy page slow** — ~10s, removed from nav. Revisit 2026-07.

---

## Sprint 23 Candidates

| Story | Priority | Description |
|-------|----------|-------------|
| H15 | P1 | Breakout vs swing comparison — ready ~2026-05-21 |
| S42 | P2 | Weight re-optimisation — needs ≥30 FRED-scored forward trades |
| H13b | P3 | Thursday/CAUTION validation on forward trades |

---

## Key Files

| File | Purpose |
|------|---------|
| `scripts/daily_note.py` | Daily Obsidian note — macro + quality dips + swing + breakout + simulator |
| `app/services/screener.py` | Pre-breakout + swing + quality_dip screener |
| `app/api/screener.py` | GET /screener, /screener/prebreakout, /screener/quality-dip |
| `app/scoring/signals.py` | BUY/SELL/HOLD signal logic (conviction-only SELL) |
| `app/scoring/components/innovation_light.py` | Tier-based innovation scorer |
| `app/scoring/modes/swing.py` | Swing scorer — regime-dependent weights (H16) |
| `config/scoring.yaml` | Weights + regime_weights + position sizing (1.5–5%) |
| `app/models/watchlist.py` | Watchlist DB (AI_CORE/AI_INFRA/GROWTH/QUALITY/AVOID) |
| `scripts/update_watchlist.py` | Agent-curated watchlist (run every 3 sprints) |
| `frontend/src/pages/Screener.tsx` | 3-tab screener: Swing/Breakout/Quality Dip |
| `frontend/src/components/Chips.tsx` | Shared chip/badge/pill components |
| `app/api/tickers.py` | Ticker universe CRUD + `GET /api/watchlist/curated` |
| `frontend/src/pages/Watchlist.tsx` | Curated tiers tab (live scores) + ticker universe tab |

---

## Infrastructure Commands

```bash
# Run tests
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml run --rm backend sh -c "pip install pytest -q 2>/dev/null && python -m pytest tests/ --ignore=tests/e2e -q 2>&1" | tail -3

# Rebuild backend
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml build backend && docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml up -d backend

# Rebuild frontend
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml build frontend && docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml up -d frontend

# Quality dip API test
curl -s http://localhost:8000/api/screener/quality-dip | python3 -m json.tool | head -30
```

---

## What NOT To Do

- Do NOT run the Analyst Agent until 500+ forward trades OR win rate shifts >5%
- Do NOT run Playwright E2E — not a sprint gate; manual only
- Do NOT run weight optimiser until ≥30 FRED-scored trades accumulated
- Do NOT spawn sub-agents for implementation — implement directly in main conversation
