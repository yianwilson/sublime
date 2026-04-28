# Product Backlog — Folio (Delta Clone)

Last updated: 2026-04-26
Status: Active — Sprint 6 executing

---

## COMPLETED (S00–S18 + ad-hoc sprints)

| Story | Feature | Notes |
|-------|---------|-------|
| S00 | Transaction-native data model | Transaction, FIFOEngine |
| S01 | FIFO trade matching engine | openLots, closedTrades, Trade |
| S02 | Cost basis via FIFO, realised/unrealised split | PortfolioViewModel |
| S03 | Portfolio time-series reconstruction | TimeSeriesEngine, HistoricalPriceService |
| S04 | Asset Detail → Trades tab | Open + closed trades list |
| S05 | Trade Detail screen | Entry/exit breakdown, holding period |
| S06 | Portfolio value chart ($/%, time filters) | DashboardView |
| S08 | Today's Movers contribution bars | DashboardView |
| S09 | Cumulative realised P&L curve | DashboardView |
| S10 | Drawdown chart + max drawdown metric | DashboardView |
| S11 | Trade analytics engine | Win rate, profit factor, avg hold, best/worst |
| S13 | Watchlist tab | WatchlistView, WatchlistViewModel |
| S14 | Asset search | AssetViewModel, Yahoo/CoinGecko search |
| S15 | News feed per holding + market news | NewsService, NewsItem |
| S16 | Multiple portfolios | PortfoliosViewModel, ManagePortfoliosView |
| S18 | CSV import (transactions) | buy/sell rows, date parsing |
| AD1 | Price alerts + local notifications | PriceAlert, AlertsService |
| AD2 | Extended hours prices | AssetQuote.preMarketPrice/postMarketPrice |
| AD3 | Sector allocation breakdown | allocationBySector |
| AD4 | Upcoming events (earnings, Fed) | EventsService, UpcomingEvent |
| AD5 | S&P 500 benchmark overlay on chart | benchmarkSeries, showBenchmark toggle |
| AD6 | Dividend transaction type | totalDividends on Holding |
| AD7 | Portfolio lifetime stats (CAGR, best/worst day) | AnalyticsView lifetimeStatsCard |
| AD8 | Holding weight % in portfolio list | HoldingRowView |
| AD9 | Settings screen (appearance, clear data) | SettingsView, 5th tab |

---

## BACKLOG (prioritised)

### Sprint 6 — Executing now

| ID | Story | Priority | Size |
|----|-------|----------|------|
| S19 | Transaction notes field | P1 | S |
| S20 | Realised vs Unrealised P&L dual-line chart | P1 | M |
| S21 | Asset price history chart in AssetDetailView | P1 | M |
| S22 | Enhanced symbol insights ("You perform best on X") | P2 | S |
| S23 | iOS WidgetKit home screen widget | P1 | L |

### Sprint 7 — Queued

| ID | Story | Priority | Size |
|----|-------|----------|------|
| S24 | Candlestick / OHLC chart mode on asset detail | P2 | M |
| S25 | Portfolio tags / labels on transactions | P2 | S |
| S26 | AUD-native asset support (ASX stocks via .AX suffix) | P2 | M |
| S27 | Portfolio comparison view (two portfolios side by side) | P3 | M |
| S28 | Dark/light chart theme follows system setting | P3 | S |
| S29 | Recurring investment simulator (DCA calculator) | P3 | L |

---

## DECISIONS NEEDED (escalate to Ed)

- S17 Widget: App Groups entitlement requires a real Team ID for device install. Simulator-only is fine for now.
- S29 DCA simulator: is this in-scope for v1?
