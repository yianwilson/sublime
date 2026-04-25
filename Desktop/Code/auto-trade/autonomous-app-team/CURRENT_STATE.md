# Current State — Trading App

> **Purpose:** Quick-start context for any new session. Read this first. Do NOT re-read all sprint history or agent logs.
> **Last updated:** 2026-04-25 (Sprint 17 COMPLETE)

---

## Where We Are

- **Sprint:** 17 COMPLETE — starting Sprint 18 next session
- **Tests:** 280 passing, 0 failing
- **Branch:** minimal-clean

---

## Sprint 17 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Quality Dip Screener | ✅ | New "Quality Dip" tab in screener. AI_CORE/AI_INFRA/GROWTH tier + 5–25% dip + RS ≥ 35. Surfaces NVDA@$175, ANET@$127 type setups |

### Quality Dip Screener Design

**Algorithm:** `dip_quality_score = dip_score×0.5 + rs_score×0.3 + tier_rank×0.2`

Tier ranks: AI_CORE=100, AI_INFRA=85, GROWTH=70

**Filters:**
- Tier ∈ {AI_CORE, AI_INFRA, GROWTH} — quality companies only
- Drawdown 3m: −5% to −25% — meaningful dip, not crash
- RS score ≥ 35 — still outperforming sector despite dip

**Card shows:** tier badge (violet/blue/emerald), drawdown%, dip score bar, RS score bar, RSI14, 200MA flag, current price

---

## Sprint 16 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Innovation scorer fix | ✅ | Tier-based quality signal replaces broken momentum proxy |
| S47 position sizing | ✅ | 1.5%–5% conviction-scaled sizing (was flat 3%) |
| Sector ETF safety | ✅ | AVOID tier no longer disables Ticker.enabled |
| UI chip system | ✅ | Shared Chips.tsx with ScoreChip/RegimeBadge/StatusPill/SignalTag |
| Config test isolation | ✅ | Portfolio tests patch write_scoring_config |

---

## Sprint 15 Summary (DONE)

| Story | Status |
|-------|--------|
| H13 day-of-week | ✅ Thursday in CAUTION near coin-flip (+0.12% avg) |
| H15 infra | ✅ Breakout simulator entries tagged `auto-paper-trade-breakout` |
| S46 BEAR floor | ✅ `bear_min_conviction` query param |

---

## Key Change — H16 Regime-Dependent Weights

| Regime | trend | dip | catalyst | rs |
|--------|-------|-----|----------|----|
| BULL | 40 | 5 | 33 | 8 |
| CAUTION | 25 | 25 | 28 | 7 |
| BEAR | 5 | 40 | 30 | 5 |

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

## Sprint 18 Candidates

| Story | Priority | Description |
|-------|----------|-------------|
| H15 | P1 | Breakout vs swing comparison — ready ~2026-05-21 |
| Daily note quality dip | P2 | Include top-3 quality dip picks in Obsidian daily note |
| S42 | P2 | Weight re-optimisation — needs ≥30 FRED-scored forward trades |
| H13b | P3 | Thursday/CAUTION validation on forward trades |

---

## Key Files

| File | Purpose |
|------|---------|
| `app/services/screener.py` | Pre-breakout + swing + quality_dip screener |
| `app/api/screener.py` | GET /screener, /screener/prebreakout, /screener/quality-dip |
| `app/scoring/components/innovation_light.py` | Tier-based innovation scorer |
| `app/scoring/modes/swing.py` | Swing scorer — regime-dependent weights (H16) |
| `config/scoring.yaml` | Weights + regime_weights + position sizing (1.5–5%) |
| `app/models/watchlist.py` | Watchlist DB (AI_CORE/AI_INFRA/GROWTH/QUALITY/AVOID) |
| `scripts/update_watchlist.py` | Agent-curated watchlist (run every 3 sprints) |
| `app/scoring/engine.py` | Universe filter via watchlist join |
| `frontend/src/components/Chips.tsx` | Shared chip/badge/pill components |
| `frontend/src/pages/Screener.tsx` | 3-tab screener: Swing/Breakout/Quality Dip |

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
