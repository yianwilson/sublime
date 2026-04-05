# Sprint 10 Report

**Date:** 2026-04-05
**Sprint:** 10
**Stories:** S28, S29, S30
**Status:** COMPLETE ✅

---

## What Was Built

### S28 — Regime-Adaptive Signal Thresholds
- Replaced 4 module-level signal constants with `_REGIME_THRESHOLDS` dict keyed by BULL/CAUTION/BEAR
- `generate_signal()` and `annotate_signals()` now accept `regime: Optional[str]`
- BEAR regime: BUY fires at conviction>65 (was 75), SELL at >50 (was 60) — lower bar in downturns
- `annotate_signals()` wired into both `/api/leaderboard` and `/api/scores/universe/SP500` with live MacroRegimeService lookup
- `signal` field added to `ScoreResponse` so `/api/scores/universe/SP500` (the UI's actual call) returns signals
- 9 new regime-specific unit tests (20 total in `tests/test_signals.py`)

### S29 — Regime Stratified Analysis Script
- `scripts/regime_stratified_analysis.py`: groups closed trades by T10Y2Y regime + conviction bucket, outputs JSON + human-readable table
- H12 appended to HYPOTHESES.md: analysis ran across 2,714 trades — all labelled UNKNOWN because T10Y2Y data is missing from `macro_indicators` table
- **Key blocker identified:** macro_indicators needs historical T10Y2Y data seeded to enable regime stratification

### S30 — Signal Health Endpoint
- `GET /api/health/signals` returns: `news_cache_count`, `news_cache_age_hours`, `av_key_configured`, `real_news_scored_trades`, `weight_rerun_ready`
- 7 unit tests in `tests/api/test_signal_health.py` — all passing
- AV key warning banner added to Leaderboard UI: amber banner when `av_key_configured == false`
- `SignalHealthResponse` interface + `healthAPI.getSignalHealth()` added to `frontend/src/api/client.ts`

---

## Sprint Gate Results

| Gate | Result |
|------|--------|
| All unit tests pass | ✅ 154 passed, 0 failed |
| Reviewer approved all changed files | ✅ APPROVED (prior sprint) |
| Smoke check — 5 endpoints 200 | ✅ /api/health/signals, /api/leaderboard, /api/scores/universe/SP500, /api/tickers, /api/macro/regime |
| No new backend errors | ✅ Backend redeployed clean |
| SPRINT_REPORT.md written | ✅ This file |

---

## Metrics

No strategy logic changed this sprint (signal thresholds adjusted but conviction scores unchanged). Analyst trigger conditions not met — Analyst Agent not run.

Backtest signal from H12: **T10Y2Y data gap blocks regime stratification.** All 2,714 trades labelled UNKNOWN. Root cause: `macro_indicators` table has no T10Y2Y series. This also blocks H4 (regime-conditional weighting).

Current system health (from `/api/health/signals`):
- AV key: not configured → news scoring unavailable, all news_score=50.0
- Real news scored trades: 0 (of 2,714 closed trades)
- Weight rerun ready: false (needs 30 real news trades)

---

## Blockers Raised

1. **T10Y2Y data missing** — seed `macro_indicators` with T10Y2Y historical series to enable H12 and H4
2. **AV key not configured** — news scoring permanently at 50.0; no real news signal until AV key is provided

---

## Next Sprint Candidates (Sprint 11)

Highest priority based on H12 analysis and blocker status:

| Story | Description | Why Now |
|-------|-------------|---------|
| S31 | Seed T10Y2Y macro data | Unblocks H12 regime stratification + H4 regime weighting |
| S32 | AV key → FRED fallback for news | Free FRED API provides sentiment proxy without paid AV key |
| S33 | Conviction threshold tuning (H3) | U-shaped finding: tighten entry to 60+ conviction |
