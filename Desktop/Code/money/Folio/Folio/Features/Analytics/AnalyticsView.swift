import SwiftUI

struct AnalyticsView: View {
    @EnvironmentObject private var vm: PortfolioViewModel

    private var analytics: TradeAnalytics { vm.tradeAnalytics }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    overallStatsCard
                    symbolBreakdownCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Analytics")
            .refreshable { await vm.refreshPrices() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !allClosedTrades.isEmpty {
                        ShareLink(
                            item: generateTradeCSV(),
                            preview: SharePreview("Trade History.csv", icon: Image(systemName: "tablecells"))
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Overall Stats Card

    private var overallStatsCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)

            VStack(alignment: .leading, spacing: 16) {
                Text("Trading Performance")
                    .font(.headline)
                    .padding(.horizontal, 4)

                if analytics.totalTrades == 0 {
                    Text("No closed trades yet. Add a SELL transaction to see analytics.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                } else {
                    metricsGrid

                    if analytics.bestTrade != nil || analytics.worstTrade != nil {
                        Divider()
                        bestWorstRows
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Metrics Grid

    private var metricsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 12) {
            metricTile(label: "Trades", value: "\(analytics.totalTrades)", color: .primary)

            metricTile(
                label: "Win Rate",
                value: analytics.winRate.asPercent(digits: 1),
                color: analytics.winRate >= 50 ? .green : .red
            )

            metricTile(
                label: "Profit Factor",
                value: analytics.profitFactor == 0
                    ? "—"
                    : String(format: "%.2f", analytics.profitFactor),
                color: analytics.profitFactor >= 1 ? .green : .red
            )

            metricTile(
                label: "Avg Hold",
                value: "\(Int(analytics.avgHoldingDays))d",
                color: .primary
            )

            metricTile(
                label: "Avg Win",
                value: analytics.avgWin == 0 ? "—" : analytics.avgWin.asCurrency(),
                color: .green
            )

            metricTile(
                label: "Avg Loss",
                value: analytics.avgLoss == 0 ? "—" : analytics.avgLoss.asCurrency(),
                color: .red
            )
        }
    }

    private func metricTile(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Best / Worst Rows

    private var bestWorstRows: some View {
        VStack(spacing: 8) {
            if let best = analytics.bestTrade {
                HStack {
                    Text("Best Trade")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(best.symbol)
                        .font(.subheadline.weight(.semibold))
                    Text(best.pnl.asChange())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            if let worst = analytics.worstTrade {
                HStack {
                    Text("Worst Trade")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(worst.symbol)
                        .font(.subheadline.weight(.semibold))
                    Text(worst.pnl.asChange())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Symbol Breakdown Card

    private var symbolBreakdownCard: some View {
        Group {
            if !analytics.bySymbol.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.regularMaterial)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("By Symbol")
                            .font(.headline)
                            .padding(.horizontal, 4)

                        let sorted = analytics.bySymbol.values
                            .sorted { $0.totalPnL > $1.totalPnL }

                        VStack(spacing: 0) {
                            ForEach(Array(sorted.enumerated()), id: \.element.symbol) { index, stats in
                                if index > 0 {
                                    Divider()
                                        .padding(.vertical, 8)
                                }
                                symbolRow(stats: stats)
                            }
                            Divider()
                            HStack {
                                Text("Total Realised")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                let total = analytics.bySymbol.values.reduce(0) { $0 + $1.totalPnL }
                                Text((total * vm.audPerUSD).asChange(code: vm.baseCurrencyCode))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(total >= 0 ? .green : .red)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - CSV Export

    private var allClosedTrades: [Trade] {
        vm.holdings
            .flatMap { FIFOEngine.closedTrades(from: $0.transactions) }
            .sorted { $0.exitDate < $1.exitDate }
    }

    private func generateTradeCSV() -> String {
        let header = "Symbol,AssetType,Quantity,EntryDate,EntryPrice(USD),ExitDate,ExitPrice(USD),PnL(USD),PnL(AUD),HoldingDays,FinancialYear"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let rows = allClosedTrades.map { trade -> String in
            let entryDate = formatter.string(from: trade.entryDate)
            let exitDate = formatter.string(from: trade.exitDate)
            let pnlAUD = trade.pnl * vm.audPerUSD
            // Australian financial year: July 1 – June 30
            let cal = Calendar.current
            let exitYear = cal.component(.year, from: trade.exitDate)
            let exitMonth = cal.component(.month, from: trade.exitDate)
            let fy = exitMonth >= 7 ? "FY\(exitYear)-\(exitYear + 1)" : "FY\(exitYear - 1)-\(exitYear)"

            return [
                trade.symbol,
                trade.assetType.rawValue,
                String(format: "%.4f", trade.quantity),
                entryDate,
                String(format: "%.4f", trade.entryPrice),
                exitDate,
                String(format: "%.4f", trade.exitPrice),
                String(format: "%.2f", trade.pnl),
                String(format: "%.2f", pnlAUD),
                "\(trade.holdingDays)",
                fy
            ].joined(separator: ",")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    private func symbolRow(stats: SymbolStats) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(stats.symbol)
                    .font(.subheadline.weight(.semibold))
                Text("\(stats.totalTrades) trades · \(Int(stats.avgHoldingDays))d avg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(stats.totalPnL.asChange())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stats.totalPnL >= 0 ? .green : .red)
                Text(stats.winRate.asPercent(digits: 0) + " WR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    AnalyticsView()
        .environmentObject(PortfolioViewModel())
}
