import SwiftUI
import Charts

private enum ChartMode: String, CaseIterable {
    case dollar  = "$"
    case percent = "%"
}

struct DashboardView: View {
    @EnvironmentObject private var vm: PortfolioViewModel
    @AppStorage("dashboard.performanceRange") private var selectedRangeRawValue = PerformanceRange.oneMonth.rawValue
    @State private var chartMode: ChartMode = .dollar

    private var selectedRange: PerformanceRange {
        get { PerformanceRange(rawValue: selectedRangeRawValue) ?? .oneMonth }
        nonmutating set { selectedRangeRawValue = newValue.rawValue }
    }

    /// Prefer reconstructed (S03) data; fall back to sparse snapshots.
    private var effectiveSeries: [PerformanceSnapshot] {
        vm.reconstructedSeries.isEmpty ? vm.performanceSeries : vm.reconstructedSeries
    }

    private var filteredSeries: [PerformanceSnapshot] {
        vm.filteredPerformanceSeries(range: selectedRange, series: effectiveSeries)
    }

    private var isUsingReconstructed: Bool { !vm.reconstructedSeries.isEmpty }

    // MARK: - Computed Properties (S07 & S08)

    private var allClosedTrades: [Trade] {
        vm.holdings.flatMap { FIFOEngine.closedTrades(from: $0.transactions) }
            .sorted { $0.pnl > $1.pnl }
    }

    // MARK: - Computed Properties (S09 — Trade Performance Curve)

    private var cumulativePnLSeries: [(date: Date, value: Double)] {
        let trades = vm.holdings
            .flatMap { FIFOEngine.closedTrades(from: $0.transactions) }
            .sorted { $0.exitDate < $1.exitDate }
        guard !trades.isEmpty else { return [] }
        var cumulative = 0.0
        return trades.map { trade in
            cumulative += trade.pnl * vm.audPerUSD
            return (date: trade.exitDate, value: cumulative)
        }
    }

    // MARK: - Computed Properties (S10 — Drawdown Chart)

    private var drawdownSeries: [(date: Date, value: Double)] {
        let series = effectiveSeries
        guard !series.isEmpty else { return [] }
        var peak = series[0].totalValue
        return series.map { snap in
            if snap.totalValue > peak { peak = snap.totalValue }
            let dd = peak > 0 ? (snap.totalValue - peak) / peak * 100 : 0
            return (date: snap.date, value: dd)
        }
    }

    private var maxDrawdown: Double {
        drawdownSeries.min(by: { $0.value < $1.value })?.value ?? 0
    }

    private var todaysMovers: [(Holding, Double)] {
        vm.holdings
            .map { ($0, vm.dailyChangeValue(for: $0)) }
            .filter { $0.1 != 0 }
            .sorted { abs($0.1) > abs($1.1) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                eventsCard
                todaysMoversCard
                realisedPnLCard
                tradePerformanceCard
                drawdownCard
                insightsCard
                performanceCard
                allocationCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dashboard")
        .refreshable {
            await vm.refreshPrices()
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(spacing: 10) {
            Text("Total Value")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(vm.totalPortfolioValue.asCurrency(code: vm.baseCurrencyCode))
                .font(.system(size: 40, weight: .bold, design: .rounded))

            HStack(spacing: 6) {
                Image(systemName: vm.totalPnL >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text(vm.totalPnL.asChange(code: vm.baseCurrencyCode))
                Text("(\(vm.totalPnLPercent.asPercent()))")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(vm.totalPnL >= 0 ? .green : .red)

            Divider().padding(.horizontal, 32)

            HStack(spacing: 4) {
                Image(systemName: vm.totalDailyChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                Text(vm.totalDailyChange.asChange(code: vm.baseCurrencyCode))
                Text("(\(vm.totalDailyChangePercent.asPercent()))")
                Text("today")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(vm.totalDailyChange >= 0 ? .green : .red)

            Text("Base currency: AUD | 1 USD = \(String(format: "%.3f", vm.audPerUSD)) AUD")
                .font(.caption)
                .foregroundStyle(.secondary)

            if vm.isLoading {
                ProgressView("Refreshing market data...")
                    .font(.caption)
                    .padding(.top, 4)
            }

            if let error = vm.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Insights Card

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insights")
                .font(.headline)

            ForEach(vm.insights) { insight in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(color(for: insight.severity))
                        .frame(width: 10, height: 10)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(insight.title)
                            .font(.subheadline.weight(.semibold))
                        Text(insight.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(color(for: insight.severity).opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Performance Card

    private var performanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Performance")
                    .font(.headline)
                Spacer()
                if vm.isReconstructing {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.7)
                        Text("Rebuilding…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if isUsingReconstructed {
                    Label("Full history", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                Picker("Range", selection: Binding(
                    get: { selectedRange },
                    set: { selectedRange = $0 }
                )) {
                    ForEach(PerformanceRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Mode", selection: $chartMode) {
                    ForEach(ChartMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 70)
            }

            if filteredSeries.count < 2 {
                Text(vm.isReconstructing
                     ? "Reconstructing history from your transactions…"
                     : "Not enough data for \(selectedRange.rawValue). Refresh to build your history.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let chartData = percentData(from: filteredSeries)
                Chart(chartData, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(chartMode == .dollar ? "Value" : "Return %", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(chartColor(from: chartData))

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value(chartMode == .dollar ? "Value" : "Return %", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(chartColor(from: chartData).opacity(0.12))
                }
                .frame(height: 180)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(chartMode == .dollar ? v.asCurrency(code: vm.baseCurrencyCode) : "\(String(format: "%.1f", v))%")
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private struct ChartPoint { let date: Date; let value: Double }

    private func percentData(from series: [PerformanceSnapshot]) -> [ChartPoint] {
        guard chartMode == .percent, let first = series.first, first.totalValue > 0 else {
            return series.map { ChartPoint(date: $0.date, value: $0.totalValue) }
        }
        return series.map { ChartPoint(date: $0.date, value: ($0.totalValue - first.totalValue) / first.totalValue * 100) }
    }

    private func chartColor(from data: [ChartPoint]) -> Color {
        guard let first = data.first, let last = data.last else { return .blue }
        return last.value >= first.value ? .green : .red
    }

    // MARK: - Allocation Card

    private var allocationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allocation")
                .font(.headline)

            if vm.allocationByType.isEmpty {
                Text("Add assets to see allocation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                allocationBar

                ForEach(vm.allocationByType, id: \.0) { type, pct in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(type.color)
                            .frame(width: 10, height: 10)
                        Image(systemName: type.icon)
                            .foregroundStyle(type.color)
                            .frame(width: 18)
                        Text(type.rawValue)
                            .font(.subheadline)
                        Spacer()
                        Text(pct.asPercent(digits: 1))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private var allocationBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(vm.allocationByType, id: \.0) { type, pct in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(type.color)
                        .frame(width: geo.size.width * pct / 100)
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Events Card

    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Upcoming Events")
                .font(.headline)

            if vm.upcomingEvents.isEmpty {
                Text("No events in the next 60 days — tap refresh to load.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.upcomingEvents) { event in
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(eventColor(event).opacity(0.15))
                                .frame(width: 44, height: 44)
                            VStack(spacing: 1) {
                                Text(event.relativeLabel)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(eventColor(event))
                            }
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(event.name)
                                    .font(.subheadline.weight(.semibold))
                                if case .earnings(let isOwned) = event.kind, isOwned {
                                    Text("OWNED")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(event.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: eventIcon(event))
                            .foregroundStyle(eventColor(event))
                    }
                    .padding(10)
                    .background(eventColor(event).opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Today's Movers Card (S08)

    private var todaysMoversCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Today's Movers")
                .font(.headline)

            if todaysMovers.isEmpty {
                Text("No price data yet — refresh to load.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let totalAbs = todaysMovers.reduce(0.0) { $0 + abs($1.1) }

                ForEach(todaysMovers, id: \.0.symbol) { holding, change in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(holding.symbol)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(change.asChange(code: vm.baseCurrencyCode))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(change >= 0 ? .green : .red)
                                Text(vm.dailyChangePercent(for: holding).asPercent())
                                    .font(.caption)
                                    .foregroundStyle(change >= 0 ? .green : .red)
                            }
                        }

                        GeometryReader { geo in
                            let proportion = totalAbs > 0 ? abs(change) / totalAbs : 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(change >= 0 ? Color.green : Color.red)
                                .frame(width: geo.size.width * proportion, height: 6)
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Realised P&L Card (S07)

    private var realisedPnLCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Realised P&L")
                .font(.headline)

            if allClosedTrades.isEmpty {
                Text("No closed trades yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let totalRealisedPnL = allClosedTrades.reduce(0.0) { $0 + $1.pnl } * vm.audPerUSD

                HStack {
                    Text("Total Realised")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(totalRealisedPnL.asChange(code: vm.baseCurrencyCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(totalRealisedPnL >= 0 ? .green : .red)
                        Text("\(allClosedTrades.count) closed trade\(allClosedTrades.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                Divider()

                ForEach(allClosedTrades.prefix(5)) { trade in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trade.symbol)
                                .font(.subheadline.weight(.semibold))
                            Text(trade.exitDate, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            let audPnL = trade.pnl * vm.audPerUSD
                            Text(audPnL.asChange(code: vm.baseCurrencyCode))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(trade.pnl >= 0 ? .green : .red)
                            Text(trade.pnlPercent.asPercent())
                                .font(.caption)
                                .foregroundStyle(trade.pnl >= 0 ? .green : .red)
                        }
                    }
                }

                if allClosedTrades.count > 5 {
                    Text("Show all \(allClosedTrades.count) trades")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Trade Performance Card (S09)

    private var tradePerformanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trade Performance")
                    .font(.headline)
                Text("Cumulative realised P&L")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if cumulativePnLSeries.isEmpty {
                Text("No closed trades yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let finalValue = cumulativePnLSeries.last?.value ?? 0
                let lineColor: Color = finalValue >= 0 ? .green : .red

                Chart(cumulativePnLSeries, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Cumulative P&L", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(lineColor)

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Cumulative P&L", point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(lineColor.opacity(0.12))
                }
                .frame(height: 160)
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Drawdown Card (S10)

    private var drawdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drawdown")
                .font(.headline)

            if drawdownSeries.count < 2 {
                Text("Not enough data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                HStack {
                    Text("Max Drawdown")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(maxDrawdown.asPercent())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(maxDrawdown == 0 ? .green : .red)
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                Chart(drawdownSeries, id: \.date) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Drawdown %", point.value)
                    )
                    .foregroundStyle(Color.red.opacity(0.5))
                }
                .frame(height: 140)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(String(format: "%.1f", v))%")
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func eventColor(_ event: UpcomingEvent) -> Color {
        switch event.kind {
        case .earnings: return .purple
        case .fedDecision: return .orange
        }
    }

    private func eventIcon(_ event: UpcomingEvent) -> String {
        switch event.kind {
        case .earnings: return "chart.bar.fill"
        case .fedDecision: return "building.columns.fill"
        }
    }

    private func color(for severity: Insight.Severity) -> Color {
        switch severity {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}
