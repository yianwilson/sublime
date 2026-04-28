import SwiftUI
import Charts

struct AnalyticsView: View {
    @EnvironmentObject private var vm: PortfolioViewModel

    private var analytics: TradeAnalytics { vm.tradeAnalytics }

    @AppStorage("analytics.pnlRange") private var pnlRangeRawValue = PerformanceRange.all.rawValue

    private var pnlRange: PerformanceRange {
        get { PerformanceRange(rawValue: pnlRangeRawValue) ?? .all }
        nonmutating set { pnlRangeRawValue = newValue.rawValue }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    lifetimeStatsCard
                    pnlChartCard
                    overallStatsCard
                    tradingInsightsCard
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

    // MARK: - Lifetime Stats Card

    private var lifetimeStatsCard: some View {
        let startedText = vm.portfolioStartDate.map { Self.dateFormatter.string(from: $0) } ?? "—"
        let cagrText = vm.cagr.map { String(format: "%.1f%%", $0) } ?? "—"
        let cagrColor: Color = (vm.cagr ?? 0) >= 0 ? .green : .red
        let totalReturn = vm.totalCostBasis > 0
            ? (vm.totalPortfolioValue - vm.totalCostBasis) / vm.totalCostBasis * 100
            : 0.0
        let totalReturnText = vm.totalCostBasis > 0 ? String(format: "%.1f%%", totalReturn) : "—"
        let totalReturnColor: Color = totalReturn >= 0 ? .green : .red
        let hasData = vm.portfolioStartDate != nil

        return ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)

            VStack(alignment: .leading, spacing: 16) {
                Text("Portfolio Lifetime")
                    .font(.headline)
                    .padding(.horizontal, 4)

                if !hasData {
                    Text("No transaction data yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 10) {
                        lifetimeStatRow(label: "Started", value: startedText, color: .primary)
                        lifetimeStatRow(label: "CAGR", value: cagrText, color: cagrColor)
                        lifetimeStatRow(label: "Total Return", value: totalReturnText, color: totalReturnColor)

                        Divider()

                        if let best = vm.bestDay {
                            HStack {
                                Text("Best Day")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Self.dateFormatter.string(from: best.date))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "+%.2f%%", best.percent))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal, 4)
                        }

                        if let worst = vm.worstDay {
                            HStack {
                                Text("Worst Day")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Self.dateFormatter.string(from: worst.date))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.2f%%", worst.percent))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.red)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func lifetimeStatRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - P&L Dual-Line Chart Card

    private struct PnLPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let series: String
    }

    private var pnlChartCard: some View {
        let realisedFiltered = vm.filteredPerformanceSeries(
            range: pnlRange,
            series: vm.realisedPnLSeries
        )
        let unrealisedFiltered = vm.filteredPerformanceSeries(
            range: pnlRange,
            series: vm.unrealisedPnLSeries
        )
        let realisedPoints = realisedFiltered.map {
            PnLPoint(date: $0.date, value: $0.totalValue, series: "Realised")
        }
        let unrealisedPoints = unrealisedFiltered.map {
            PnLPoint(date: $0.date, value: $0.totalValue, series: "Unrealised")
        }
        let hasData = !realisedPoints.isEmpty || !unrealisedPoints.isEmpty

        return ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)

            VStack(alignment: .leading, spacing: 16) {
                Text("Realised vs Unrealised P&L")
                    .font(.headline)
                    .padding(.horizontal, 4)

                Picker("Range", selection: Binding(
                    get: { pnlRange },
                    set: { pnlRange = $0 }
                )) {
                    ForEach(PerformanceRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                if !hasData {
                    Text(vm.isReconstructing
                         ? "Reconstructing history…"
                         : "No data yet — refresh to build history.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Chart {
                        ForEach(unrealisedPoints) { point in
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("P&L", point.value),
                                series: .value("Type", point.series)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(by: .value("Type", point.series))
                        }
                        ForEach(realisedPoints) { point in
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("P&L", point.value),
                                series: .value("Type", point.series)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(by: .value("Type", point.series))
                        }
                        RuleMark(y: .value("Zero", 0))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(dash: [4]))
                    }
                    .chartForegroundStyleScale([
                        "Realised": Color.blue,
                        "Unrealised": Color.orange
                    ])
                    .frame(height: 180)
                    .chartYAxis {
                        AxisMarks(position: .trailing) { value in
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(v.asCurrency(code: vm.baseCurrencyCode))
                                        .font(.caption2)
                                }
                            }
                            AxisGridLine()
                        }
                    }
                    .chartLegend(position: .bottom, alignment: .leading)
                }
            }
            .padding(16)
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

    // MARK: - Trading Insights

    private var tradingInsights: [String] {
        let bySymbol = analytics.bySymbol.values
        var insights: [String] = []

        // Best symbol by win rate (min 2 trades)
        if let best = bySymbol.filter({ $0.totalTrades >= 2 }).max(by: { $0.winRate < $1.winRate }) {
            insights.append("Your best win rate is on \(best.symbol) (\(Int(best.winRate))% of \(best.totalTrades) trades)")
        }

        // Symbol with most trades
        if let most = bySymbol.max(by: { $0.totalTrades < $1.totalTrades }), most.totalTrades >= 3 {
            insights.append("\(most.symbol) is your most traded asset with \(most.totalTrades) closed trades")
        }

        // Worst symbol by realised P&L (min 1 trade, negative P&L only)
        if let worst = bySymbol.filter({ $0.totalPnL < 0 }).min(by: { $0.totalPnL < $1.totalPnL }) {
            let formatted = worst.totalPnL.formatted(.currency(code: "USD").presentation(.narrow))
            insights.append("\(worst.symbol) is your biggest loser: \(formatted)")
        }

        // Overall profit factor observation (min 5 trades)
        if analytics.totalTrades >= 5 {
            if analytics.profitFactor >= 2.0 {
                insights.append("Strong profit factor of \(String(format: "%.1f", analytics.profitFactor))x — your winners significantly outpace your losers")
            } else if analytics.profitFactor < 1.0 {
                insights.append("Profit factor below 1.0 — losses currently outpace gains")
            }
        }

        return insights
    }

    private var tradingInsightsCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.regularMaterial)

            VStack(alignment: .leading, spacing: 16) {
                Text("Trading Insights")
                    .font(.headline)
                    .padding(.horizontal, 4)

                if tradingInsights.isEmpty {
                    Text("Add trades to unlock insights.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(tradingInsights, id: \.self) { insight in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(insight)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(16)
        }
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
