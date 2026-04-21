# Current State — Trading App

> **Purpose:** Quick-start context for any new session. Read this first. Do NOT re-read all sprint history or agent logs.
> **Last updated:** 2026-04-21 (Sprint 15 COMPLETE)

---

## Where We Are

- **Sprint:** 15 COMPLETE — starting Sprint 16 next session
- **Tests:** 256 passing, 0 failing
- **Smoke check:** 5/5 endpoints 200
- **Branch:** minimal-clean

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

## Key Change This Sprint — H16 Regime-Dependent Weights

**Finding:** Fixed weights are regime-blind. Component × regime attribution showed:
- BULL: high dip score **hurts** (-5.3pp win rate) — dipping = laggard, not opportunity
- BEAR: high trend score is **toxic** (-10.9pp win rate) — extended stocks keep falling

**Deployed:** `config/scoring.yaml` → `regime_weights` block; `swing.py` selects at score time.

| Regime | trend | dip | catalyst | rs |
|--------|-------|-----|----------|----|
| BULL | 40 | 5 | 33 | 8 |
| CAUTION | 25 | 25 | 28 | 7 |
| BEAR | 5 | 40 | 30 | 5 |

Algo fingerprint (cfg= in trade notes) lets us compare pre/post-H16 forward performance.

---

## Key Change This Sprint — Breakout Screener

**Old (broken):** Near 52w high + volume surge + RSI 52-72 = already broken out, chasing.

**New (pre-breakout):**
- 5–20% below 52w high (building toward resistance)
- BB squeeze active NOW (bb_width_percentile < 30)
- Volume drying up (< 0.85x) — sellers exhausted
- RSI 40–60 — consolidating, room to run
- Above SMA20 + SMA50 — uptrend intact
- RS > 45 vs sector — holding up in base

Entry: current price ±1% | Target: 52w high | Stop: SMA20 or -6%

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
2. **AV key not configured** — news_score uses FRED fallback. Amber warning in Leaderboard.
3. **Accuracy page slow** — `/api/accuracy/report` ~10s. Removed from nav. Revisit 2026-07.

---

## Sprint 15 Summary (DONE)

| Story | Status | What Was Built |
|-------|--------|---------------|
| H13 | ✅ | Day-of-week entry analysis — Thursday in CAUTION is near coin-flip (+0.12% avg) |
| H15 infra | ✅ | Simulator now enters top-3 breakout trades daily (tagged `auto-paper-trade-breakout`), enabling forward H15 test in ~30 days |
| S46 | ✅ | Screener: `bear_min_conviction` query param filters results in BEAR regime |

**H13 key finding:** The overall Thursday underperformance is a CAUTION-regime effect. Thursday in CAUTION: +0.12% avg / 52.1% win rate (coin-flip). Monday in CAUTION: +3.26% avg. No hard simulator filter added — documented as guidance.

**H15 status:** Not yet testable (need ~30 days of forward breakout trades). Infra live as of 2026-04-21.

---

## Sprint 16 Candidates

| Story | Priority | Description |
|-------|----------|-------------|
| H15 | P1 | Does breakout mode outperform swing in BULL? (needs ~30 days of forward breakout trades) |
| S42 | P2 | Weight re-optimisation — after ≥30 FRED-scored forward trades |
| S47 | P2 | Position sizing: vary by conviction (currently flat 3%; change to 1.5%–5% range) |
| H13b | P3 | Validate Thursday/CAUTION finding on forward trades; optionally add simulator day preference |

---

## Key Files

| File | Purpose |
|------|---------|
| `app/services/screener.py` | Pre-breakout base screener; BEAR conviction floor (S46) |
| `app/scoring/modes/swing.py` | Swing scorer — regime-dependent weights (H16) |
| `config/scoring.yaml` | Weights + regime_weights + thresholds |
| `app/services/paper_trade_simulator.py` | Simulator — swing + breakout daily entries (H15 infra) |
| `scripts/h13_day_of_week_analysis.py` | H13 day-of-week attribution script |
| `app/core/scheduler.py` | Scheduled jobs (simulator at 21:30 UTC) |
| `frontend/src/pages/Screener.tsx` | Screener UI — regime filter + position sizing |
| `frontend/src/pages/Leaderboard.tsx` | Main UI — BEAR caution badge + regime banner |
| `scripts/daily_note.py` | Daily Obsidian note (macro + picks + simulator results) |
| `scripts/com.trading.daily-note.plist` | launchd plist — run daily_note.py at 22:00 |
| `scripts/h11_exit_logic_analysis.py` | H11 hold duration analysis (rerun after forward data) |

---

## Infrastructure Commands

```bash
# Run tests
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml run --rm backend bash -c "pip install pytest -q 2>/dev/null && python -m pytest tests/ --ignore=tests/e2e -q 2>&1" | tail -3

# Rebuild backend
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml build --no-cache backend && docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml up -d --force-recreate backend

# Rebuild frontend
docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml build --no-cache frontend && docker compose -f /Users/edwardwilson/Desktop/Code/Trading/docker-compose.yml up -d --force-recreate frontend

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
