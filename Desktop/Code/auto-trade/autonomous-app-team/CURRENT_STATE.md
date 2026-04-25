# Current State — Trading App

> **Purpose:** Quick-start context for any new session. Read this first. Do NOT re-read all sprint history or agent logs.
> **Last updated:** 2026-04-25 (Sprint 16 COMPLETE)

---

## Where We Are

- **Sprint:** 16 COMPLETE — starting Sprint 17 next session
- **Tests:** 272 passing, 0 failing
- **Branch:** minimal-clean

---

## Sprint 16 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Innovation scorer fix | ✅ | Tier-based quality signal replaces broken momentum proxy. NVDA/ANET dipping = still high quality score |
| S47 position sizing | ✅ | 1.5%–5% conviction-scaled sizing (was flat 3%). Low conviction → 1.5%, high → 5% |
| Sector ETF safety | ✅ | AVOID tier no longer disables Ticker.enabled — sector ETFs keep price data flowing for RS calculations |
| UI chip system | ✅ | Shared Chips.tsx with ScoreChip/RegimeBadge/StatusPill/SignalTag across all pages |
| Config test isolation | ✅ | Portfolio tests now patch write_scoring_config so tests can't reset config/scoring.yaml |

---

## Key Changes This Sprint

### Innovation Scorer — Tier-Based Quality

**Problem:** Dipping stocks (NVDA@$175, ANET@$127) got innovation score ~22 because the scorer used momentum_slope as quality proxy. Negative momentum → 0 for momentum components.

**Fix:** Innovation score now uses watchlist tier exclusively:
- AI_CORE (NVDA, MSFT, AMD…): 95
- AI_INFRA (ANET, AVGO, QCOM…): 85
- GROWTH (CRWD, PLTR, LLY…): 70
- QUALITY (JPM, COST, V…): 55
- AVOID / unknown: 35

Fundamentals (revenue/EPS growth) contribute 50% when available; tier fills in otherwise.
Momentum has **zero** effect on innovation score.

### S47 — Conviction-Scaled Position Sizing

`config/scoring.yaml`:
```yaml
position_sizing:
  min_position_pct: 1.5
  max_position_pct: 5.0
```
Conviction 50 → 3.25% ($3,250 on $100k). Conviction 90 → 4.5% ($4,500).

### Sector ETF Safety

`update_watchlist.py --apply` no longer sets `Ticker.enabled=False` for AVOID tickers.
Scoring exclusion is handled entirely by the Watchlist join. Sector ETFs (XLK, XLF, etc.) stay enabled for price ingestion so RS calculations work correctly.

---

## Sprint 14 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| Breakout redesign | ✅ | Pre-breakout base screener — finds stocks coiling BEFORE the move, not after |
| S43 | ✅ | Screener: BEAR regime filter hides conviction 50–69 by default (toggle to show) |
| S44 | ✅ | Screener: position sizing guidance (Size: X% / $Y) in each card footer |
| S45 | ✅ | Daily note: simulator results section + launchd plist for 22:00 auto-run |
| H16 | ✅ | Regime-dependent swing weights — BULL trend-heavy, BEAR dip-heavy |

---

## Sprint 15 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| H13 | ✅ | Day-of-week entry analysis — Thursday in CAUTION is near coin-flip (+0.12% avg) |
| H15 infra | ✅ | Simulator now enters top-3 breakout trades daily (tagged `auto-paper-trade-breakout`), enabling forward H15 test in ~30 days |
| S46 | ✅ | Screener: `bear_min_conviction` query param filters results in BEAR regime |

---

## Key Change — H16 Regime-Dependent Weights

| Regime | trend | dip | catalyst | rs |
|--------|-------|-----|----------|----|
| BULL | 40 | 5 | 33 | 8 |
| CAUTION | 25 | 25 | 28 | 7 |
| BEAR | 5 | 40 | 30 | 5 |

---

## Forward Trade Pipeline

- Simulator running daily since Sprint 13. Enters top-5 swing, closes per regime hold limit.
- Tags: `notes='auto-paper-trade YYYY-MM-DD'`
- Daily note auto-runs at 22:00 (after simulator) — install plist to activate:
  `cp scripts/com.trading.daily-note.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.trading.daily-note.plist`
- Rerun H10/H11 analysis after 30 days (~150 forward trades).
- Full Analyst Agent trigger: 500+ forward trades OR win rate shifts >5%.

---

## Top Blockers

1. **Forward trades need time** — ~3 months to meaningful forward data. No action needed.
2. **AV key not configured** — news_score uses FRED fallback. No UI warning (removed).
3. **Accuracy page slow** — `/api/accuracy/report` ~10s. Removed from nav. Revisit 2026-07.

---

## Sprint 17 Candidates

| Story | Priority | Description |
|-------|----------|-------------|
| H15 | P1 | Does breakout mode outperform swing in BULL? (needs ~30 days of forward breakout trades, ~2026-05-21) |
| S42 | P2 | Weight re-optimisation — after ≥30 FRED-scored forward trades |
| H13b | P3 | Validate Thursday/CAUTION finding on forward trades; optionally add simulator day preference |
| Quality dip screener | P2 | Dedicated screener mode: tier + dip_score + RS for NVDA@$175 type setups |

---

## Key Files

| File | Purpose |
|------|---------|
| `app/scoring/components/innovation_light.py` | Tier-based innovation scorer (H16-aligned) |
| `app/services/screener.py` | Pre-breakout base screener; BEAR conviction floor (S46) |
| `app/scoring/modes/swing.py` | Swing scorer — regime-dependent weights (H16) |
| `config/scoring.yaml` | Weights + regime_weights + position sizing (1.5–5%) |
| `app/services/paper_trade_simulator.py` | Simulator — swing + breakout daily entries (H15 infra) |
| `scripts/update_watchlist.py` | Agent-curated watchlist (run every 3 sprints) |
| `app/models/watchlist.py` | Watchlist DB model (tier: AI_CORE/AI_INFRA/GROWTH/QUALITY/AVOID) |
| `app/scoring/engine.py` | Universe filter via watchlist join |
| `frontend/src/components/Chips.tsx` | Shared chip/badge/pill components |
| `scripts/daily_note.py` | Daily Obsidian note (macro + picks + simulator results) |

---

## Infrastructure Commands

```bash
# Run tests
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml run --rm backend sh -c "pip install pytest -q 2>/dev/null && python -m pytest tests/ --ignore=tests/e2e -q 2>&1" | tail -3

# Rebuild backend
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml build backend && docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml up -d backend

# Rebuild frontend
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml build frontend && docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml up -d frontend

# Manually trigger simulator
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml run --rm backend python -c "
from app.core.db import SessionLocal
from app.services.paper_trade_simulator import run_simulator
db = SessionLocal()
print(run_simulator(db))
db.close()
"
```

---

## What NOT To Do

- Do NOT run the Analyst Agent until 500+ forward trades OR win rate shifts >5%
- Do NOT run Playwright E2E — not a sprint gate; manual only
- Do NOT run weight optimiser until ≥30 FRED-scored trades accumulated
- Do NOT spawn sub-agents for implementation — permission isolation breaks the workflow; implement directly in main conversation
