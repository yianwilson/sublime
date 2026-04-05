# HYPOTHESES.md — Sprint 5 Post-Sprint Analysis
**Date:** 2026-03-28
**Sprint:** 5
**Analyst:** Analyst Agent

---

## Context: First Real Data Snapshot

Sprint 5 delivered S17 (historical back-fill). **2,714 closed paper trades now exist in the DB**, covering real historical scoring outcomes. This is the first empirically grounded analysis in the project. Hypotheses below are now split between data-confirmed findings and structural hypotheses carried forward from Sprint 4.

---

## CRITICAL FINDING: U-Shaped Conviction vs. Outcome Correlation

The expected monotonic relationship between conviction score and win rate does NOT exist across the mid-range of conviction scores. The data shows a **U-shaped pattern**:

| Conviction Bucket | N Trades | Win Rate | Avg Return |
|-------------------|----------|----------|------------|
| < 40              | 348      | **64.7%** | +2.69%    |
| 40–49             | 367      | 55.6%    | +0.52%    |
| 50–59             | 1,689    | 55.1%    | +1.36%    |
| 60–69             | 295      | 56.3%    | +2.30%    |
| 70+               | 15       | **73.3%** | +4.36%   |

**Portfolio-level summary (all 2,714 closed trades):**
- Win rate: **56.6%**
- Average return per trade: **+1.54%**
- Average conviction score: **52.2**
- Median return: **+0.95%**
- Return stdev: **9.02%**
- Avg win: **+6.67%** | Avg loss: **-5.17%** | Win/Loss ratio: **1.29x**
- Return range: -28.1% to +99.1%

---

## H1: The News Pillar Is Dead Weight — 20% of Conviction Score Is Noise

**Status:** CONFIRMED (code-level) — now with data corroboration
**Priority:** HIGH

**Evidence:**
In `app/scoring/modes/swing.py` line 133:
```python
result["news_score"] = 50.0  # Placeholder until Sprint 2
```

The news pillar is hardcoded to neutral (50.0) for every ticker. This means 20% of the conviction score (`w_news = 0.2` in `config/scoring.yaml`) adds exactly 10 points to every stock identically.

**Data update (Sprint 5):** The conviction score distribution confirms the news hardcoding signature: the median conviction is 52.2 and stdev is only 8.4, which is extremely tight for a genuine 3-pillar model. The narrow distribution is consistent with the constant +10 offset and the CAUTION regime always returning 50 for macro (H4). The 50–59 bucket contains 62% of all trades — a strong clustering around the constant 50 anchor.

**Hypothesis:** Adding real news sentiment will widen the conviction distribution, shifting the median score and pushing genuinely weak-news stocks below 45. Current calibration thresholds will need re-zeroing.

**Test:** Wire ANTHROPIC_API_KEY. Compare conviction score stdev before/after. Expect stdev to increase from ~8.4 to >12 once two live pillars are differentiating.

---

## H2: Catalyst Scorer Has a Structural Baseline Floor That Inflates Quiet-Day Scores

**Status:** SUSPECTED (code-level)
**Priority:** MEDIUM

**Evidence:**
`_calculate_baseline_activity()` in `app/scoring/components/catalysts.py` adds a ~27.5 floor for quiet stocks. With catalyst score at 30% of the swing composite, this adds ~8 points even when nothing is happening.

**Data update (Sprint 5):** The tight score clustering (62% of trades between conviction 50–59) is consistent with catalyst floor compression suppressing differentiation. The distribution stdev of 8.4 is too narrow for a genuinely multi-signal model.

**Test:** Compare catalyst score distribution in periods cross-referenced with low VIX (quiet market days). If catalyst score stdev < 10 on those days, the floor is dominating.

---

## H3: The Conviction Weights Are Unvalidated — Now Partially Testable

**Status:** PARTIALLY TESTABLE — first data exists
**Priority:** HIGH (S06 is now unblocked)

**Evidence (Sprint 4):**
`config/scoring.yaml`: `w_tech: 0.5, w_macro: 0.3, w_news: 0.2`

These weights have never been validated. RS is weighted at 5% of tech (= 2.5% of conviction) despite academic consensus ranking it as a top-3 predictor.

**Critical data finding (Sprint 5):** The U-shaped conviction-outcome pattern suggests the weight optimisation problem is non-trivial. The <40 bucket outperforms the 40–59 range. This is counterintuitive and warrants investigation: it may indicate that very-low-conviction scores are being assigned to genuinely contrarian setups that subsequently outperform (mean reversion or oversold bounces), or that the low-conviction trades are being entered at better prices. **S06 (weight optimisation) is now formally unblocked.**

**Hypothesis (revised):** The optimal conviction weights will not produce a simple linear win-rate gradient. The optimiser should target expected return per trade (not just win rate), since the <40 bucket has both high win rate AND the second-highest average return. Weight optimisation should consider whether the composite score's absolute level is a reliable threshold signal or only useful for relative ranking.

**Test:** S06 — Run Bayesian weight optimisation against the 2,714 closed trades. Use expected return as the objective. Report Spearman correlation between conviction quintile and avg return.

---

## H4: The Macro Veto Collapses the Leaderboard in BEAR Regimes

**Status:** STRUCTURAL CONCERN (code-level)
**Priority:** MEDIUM

**Evidence:**
Macro veto fires when `macro_score < 35`, capping conviction at 50.0. In strong BEAR, most cyclicals get macro_score ~10.

**Data update (Sprint 5):** The conviction score median of 52.2 and tight distribution suggests back-fill data was predominantly gathered during CAUTION or mild BULL conditions (CAUTION returns macro_score = 50 for all sectors, suppressing differentiation from the macro pillar entirely). This is consistent with the bulk of the score mass sitting in 50–59.

**Test:** Filter the 2,714 trades by approximate regime at entry date. Compare conviction distribution across BULL vs CAUTION vs BEAR sub-periods. If BEAR-period trades are over-represented in the <40 bucket with high win rate, the macro veto may be suppressing otherwise good setups.

---

## H5: RS Scorer Makes O(n) DB Queries Per Bulk Scoring Run

**Status:** CONFIRMED (code-level, performance risk)
**Priority:** MEDIUM — unchanged from Sprint 4

For universes > 100 tickers, bulk scoring will exhibit O(n) DB query growth from RS sub-scoring (estimated 300+ queries for 60-ticker universe). Not yet a bottleneck at current scale but will become one as the ticker universe grows.

**Test:** Profile `/api/leaderboard` latency as universe grows to 150+. If > 5 seconds, RS pre-fetching must be implemented.

---

## H6: The Sanity Cap Rarely Binds

**Status:** DATA-SUPPORTED
**Priority:** LOW

**Data update (Sprint 5):** Only 2.5% of the 2,714 trades (67 trades) have conviction >= 65. The sanity cap at 65 (firing when sanity_score < 30) operates on a near-empty tail of the distribution. The cap is structurally sound in design but irrelevant in practice — the real distribution rarely reaches it.

**Revised hypothesis:** The cap is not the problem. The problem is that the score distribution is compressed into a narrow band (stdev 8.4) that never reaches the cap for most stocks. Widening the score distribution (by fixing H1 and H2) will eventually make the cap relevant again.

---

## H7: Paper Trade Back-Fill (S17) — COMPLETED

**Status:** CLOSED — S17 delivered
**Priority:** N/A

2,714 closed trades back-filled from historical scores. S06 (weight optimisation) is now unblocked. H7 is resolved.

---

## H8: Position Sizing Guidance (S08) — Superseded by Data

**Status:** SUPERSEDED
**Priority:** LOW

S17 back-fill has made the friction hypothesis moot — we now have 2,714 trades regardless of UI friction. H8 remains valid for the forward-looking real-trading flow but is no longer a critical blocker.

---

## H9: Sector Exposure Warning (S08) — Needs Observation

**Status:** AWAITING DATA (real trades going forward)
**Priority:** MEDIUM

No update from back-fill data (back-fill trades were not entered via the modal and would not have triggered the warning UI). This hypothesis is only testable via forward real-trade entries. Carry forward to Sprint 6.

---

## H10: NEW — The <40 Conviction Bucket Outperformance Is a Tradeable Signal

**Status:** NEW HYPOTHESIS — data-driven
**Priority:** HIGH

**Evidence (Sprint 5 data):**
The <40 conviction bucket (348 trades) has:
- Win rate: 64.7% (highest of any bucket)
- Avg return: +2.69% (second highest after 70+ which has only 15 trades)
- This bucket outperforms the 50–59 bucket (62% of all trades, win rate 55.1%, avg return +1.36%) on both dimensions

This is counterintuitive. Stocks that score lowest on the model's conviction scale are producing the best outcomes. Three candidate explanations:

1. **Mean reversion signal:** Low-conviction scores may coincide with oversold conditions (low trend + low catalyst = recent sell-off). These are set up for bounce trades regardless of conviction model assessment.
2. **Back-fill data bias:** Historical scores at low conviction may have been entered post-hoc for stocks that had already begun recovering — a form of hindsight contamination in the back-fill.
3. **Model inversion in certain regimes:** In CAUTION (macro 50 constant), the tech score fully determines the relative ranking. Low-conviction stocks in CAUTION may be genuinely oversold dip setups that the catalyst floor (H2) is suppressing despite their favourable price action.

**Hypothesis:** If explanation 1 or 3 is correct, filtering to add a long-only rule that explicitly targets <40 conviction scores during CAUTION regimes will improve overall portfolio win rate. If explanation 2 (back-fill bias) is correct, the <40 bucket result is an artefact and will not replicate in forward data.

**Test:**
1. Filter the <40 bucket trades by estimated regime at entry. If they are concentrated in CAUTION, explanation 3 is supported.
2. Compare back-fill trade entry dates against the trade outcome direction. Look for clustering of back-fill entries immediately before confirmed price moves (hindsight signal).
3. Monitor forward paper trades at <40 conviction for 2 sprints. If win rate regresses toward 55%, explanation 2 is confirmed.

---

## H11: NEW — Win/Loss Ratio Below Target (1.29x vs 1.5x target)

**Status:** NEW FINDING — target miss
**Priority:** HIGH

**Evidence (Sprint 5 data):**
- Avg win: +6.67%
- Avg loss: -5.17%
- Win/loss ratio: **1.29x**
- Target: 1.5x

The model is producing a positive expected value (+1.54% avg return, 56.6% win rate), but the win/loss ratio is 14% below the 1.5x target. The model wins more often than it loses but the wins are not outsized relative to the losses.

**Hypothesis:** The current exit logic (or lack thereof) is limiting upside capture. If exit rules are static (e.g. fixed hold period from back-fill) or absent, the winners are being capped while losers are being held to full loss. Improving the exit strategy (trailing stops, profit targets proportional to conviction) should improve the ratio without affecting win rate.

**Test:** In S06 or a dedicated exit strategy story: analyse return distribution by hold duration. If long-duration losers are dragging the avg loss, a time-based stop (e.g., close after 20 days if not in profit) would improve the ratio. If win distribution is heavily right-skewed with a few large outliers (max +99.1%), the problem may be cut-short winners rather than held losers.

---

---

## H12: Regime-conviction interaction

**Status:** UPDATED — Real data now available (T10Y2Y seeded 2026-04-05)
**Priority:** HIGH
**Date added:** 2026-04-04 (S29-T3) | **Updated:** 2026-04-05 (Sprint 11 — S31 seeded 812 T10Y2Y rows)

**Evidence (updated — real regime stratification):**

T10Y2Y seeded via `scripts/seed_t10y2y.py` covering 2023-01-01 to 2026-04-05 (812 rows). Re-run of `scripts/regime_stratified_analysis.py` on 2026-04-05 against 2,714 closed trades now produces genuine BULL/CAUTION/BEAR stratification.

**Regime summary table:**

| Regime  | N Trades | Win Rate | Notes |
|---------|----------|----------|-------|
| BULL    | 980      | 57.6%    | Highest win rate |
| BEAR    | 779      | 57.0%    | Close second |
| CAUTION | 955      | 55.4%    | Weakest regime |
| UNKNOWN | 0        | —        | All trades now classified |

Note: avg return figures from the script display are ×100 inflated (display bug — stored values are already in percent). Win rates are reliable.

**Regime × conviction bucket table (key cells with n ≥ 10):**

| Regime  | Bucket | N   | Win%  | Signal |
|---------|--------|-----|-------|--------|
| BULL    | <40    | 5   | 100%  | n too small |
| BULL    | 40-49  | 66  | 68.2% | ✅ Strong |
| BULL    | 50-59  | 737 | 56.0% | Baseline |
| BULL    | 60-69  | 164 | 56.7% | Marginal edge |
| BULL    | 70+    | 8   | 100%  | n too small |
| CAUTION | 40-49  | 98  | 54.1% | Weak |
| CAUTION | 50-59  | 732 | 55.5% | Baseline |
| CAUTION | 60-69  | 118 | 56.8% | Modest edge |
| BEAR    | <40    | 343 | 64.1% | ✅ Strongest reliable cell |
| BEAR    | 40-49  | 203 | 52.2% | Underperforms |
| BEAR    | 50-59  | 220 | 50.9% | Near coin-flip |
| BEAR    | 60-69  | 13  | 46.2% | ⚠️ Negative edge (small n) |

**Key findings:**

1. **BEAR <40 is the standout cell** (n=343, 64.1% win rate) — the strongest reliable signal in the entire dataset. Mean-reversion thesis holds in BEAR markets specifically for oversold stocks.

2. **CAUTION is the weakest regime** (55.4%) — the macro_score suppression concern from H4 may explain this: CAUTION regime likely drags conviction scores into a "grey zone" that neither triggers strong entries nor strong avoidance.

3. **BEAR 50-59 is a near coin-flip** (50.9%, n=220) — mid-range conviction in BEAR markets has essentially no edge. This is the bucket to filter out.

4. **Conviction ≥ 60 in BEAR is counter-productive** (46.2% win rate, n=13 — low confidence but directionally consistent with: in BEAR regimes, high absolute scores may indicate stocks resisting downtrend, not good dip-buys).

5. **BULL 40-49 strong** (68.2%, n=66) — momentum + slight dip combination works in uptrends.

**Proposed change — regime-conditional entry filter:**

Based on the data, the actionable rule is:
- In **BEAR regime**: prefer `conviction < 40` entries over mid-range (50-69). The <40 bucket (64.1%) outperforms the 50-59 bucket (50.9%) by 13 percentage points.
- In **CAUTION regime**: no strong regime-specific filter — use universal threshold.
- In **BULL regime**: 40-49 bucket has edge (68.2%) — slightly lower conviction works in uptrends.

Implement as: regime-aware `min_conviction` and `max_conviction` guidance in the leaderboard UI, not a hard filter in scoring.

**Expected impact:**

If BEAR-regime trades are filtered to `conviction < 50` (removing the 50-59 and 60-69 buckets): eliminates 233 low-edge trades (50.9% and 46.2% win rates), keeping 343 high-edge trades (64.1%). Portfolio-wide impact depends on BEAR regime frequency (~29% of all trades at current rate).

**Status:** Testable — data is available. Propose as Sprint 12 story: "Regime-conditional leaderboard guidance overlay."

**Next action:** Design Sprint 12 story for regime-aware conviction filtering in UI.

---

## Summary Priority Table

| ID | Hypothesis | Testable Now? | Blocker | Impact |
|----|-----------|--------------|---------|--------|
| H12 | Regime-conviction interaction — REAL DATA: BEAR<40=64.1% win, BEAR 50-59=50.9% (coin-flip), CAUTION weakest regime | Yes | Design regime-conditional UI guidance (Sprint 12) | HIGH |
| H10 | <40 bucket outperformance — mean reversion or back-fill bias | Yes | Regime + date analysis of back-fill trades | HIGH |
| H11 | Win/loss ratio 1.29x vs 1.5x target — exit logic needed | Yes | Exit strategy analysis | HIGH |
| H3 | Conviction weights unvalidated — S06 now unblocked | Yes | Run S06 | HIGH |
| H1 | News pillar constant noise — widens score distribution if fixed | Yes (code) | ANTHROPIC_API_KEY | HIGH |
| H9 | Sector exposure warning reduces sector concentration | Awaiting forward data | 5+ real paper trades | MEDIUM |
| H2 | Catalyst floor compresses score distribution | Partially | Score distribution analysis | MEDIUM |
| H4 | Macro veto collapses leaderboard in BEAR — regime filter needed | Partially | Regime tagging of back-fill trades | MEDIUM |
| H5 | RS scorer O(n) DB queries | Yes | Profiling | MEDIUM |
| H6 | Sanity cap rarely binds — distribution too narrow to reach it | Data-confirmed | Fixed when H1/H2 fixed | LOW |
