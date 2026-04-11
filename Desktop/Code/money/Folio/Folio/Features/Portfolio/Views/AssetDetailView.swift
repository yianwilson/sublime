import SwiftUI

private enum DetailTab: String, CaseIterable {
    case overview = "Overview"
    case trades   = "Trades"
}

struct AssetDetailView: View {
    let holding: Holding
    @EnvironmentObject private var vm: PortfolioViewModel
    @State private var selectedTab: DetailTab = .overview
    @State private var selectedTrade: Trade? = nil

    private var price: Double { vm.livePrice(for: holding) }

    private var openLots: [OpenLot] {
        FIFOEngine.openLots(from: holding.transactions)
    }
    private var closedTrades: [Trade] {
        FIFOEngine.closedTrades(from: holding.transactions)
    }

    var body: some View {
        List {
            // Tab Picker
            Section {
                Picker("View", selection: $selectedTab) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))

            if selectedTab == .overview {
                overviewSections
            } else {
                tradesSections
            }
        }
        .listStyle(.insetGrouped)
        .sheet(item: $selectedTrade) { trade in
            TradeDetailView(trade: trade).environmentObject(vm)
        }
        .navigationTitle(holding.symbol)
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await vm.refreshPrices() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.isLoading {
                    ProgressView()
                } else {
                    Button { Task { await vm.refreshPrices() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewSections: some View {
        Section("Live Price") {
            row("Current Price", price.asCurrency())
            row(
                "Today",
                vm.dailyChangeValue(for: holding).asChange(code: vm.baseCurrencyCode),
                accent: vm.dailyChangeValue(for: holding) >= 0 ? .green : .red
            )
            row(
                "Daily Change %",
                vm.dailyChangePercent(for: holding).asPercent(),
                accent: vm.dailyChangePercent(for: holding) >= 0 ? .green : .red
            )
            row(
                "Return",
                holding.unrealisedPnLPercent(price: price).asPercent(),
                accent: holding.unrealisedPnLPercent(price: price) >= 0 ? .green : .red
            )
        }

        Section("Position") {
            row("Quantity", holding.quantity.asQuantity())
            row("Avg Buy Price", holding.averageCostBasis.asCurrency())
            row("Cost Basis", vm.costBasis(for: holding).asCurrency(code: vm.baseCurrencyCode))
            row("Market Value", vm.currentValue(for: holding).asCurrency(code: vm.baseCurrencyCode))
            row(
                "Unrealised P&L",
                vm.pnl(for: holding).asChange(code: vm.baseCurrencyCode),
                accent: vm.pnl(for: holding) >= 0 ? .green : .red
            )
            if holding.realisedPnL != 0 {
                row(
                    "Realised P&L",
                    (holding.realisedPnL * vm.audPerUSD).asChange(code: vm.baseCurrencyCode),
                    accent: holding.realisedPnL >= 0 ? .green : .red
                )
            }
        }

        if let stats = vm.tradeAnalytics.bySymbol[holding.symbol], stats.totalTrades > 0 {
            Section("Trade Analytics") {
                row("Closed Trades", "\(stats.totalTrades)")
                row("Win Rate", stats.winRate.asPercent(digits: 1),
                    accent: stats.winRate >= 50 ? .green : .red)
                row("Avg Hold", "\(Int(stats.avgHoldingDays))d")
                row(
                    "Total Realised",
                    (stats.totalPnL * vm.audPerUSD).asChange(code: vm.baseCurrencyCode),
                    accent: stats.totalPnL >= 0 ? .green : .red
                )
            }
        }

        Section("Info") {
            row("Symbol", holding.symbol)
            row("Name", holding.name)
            row("Type", holding.assetType.rawValue)
            row("Base Currency", vm.baseCurrencyCode)
        }
    }

    // MARK: - Trades

    @ViewBuilder
    private var tradesSections: some View {
        // Open lots
        Section(header: Text("Open Lots (\(openLots.count))")) {
            if openLots.isEmpty {
                Text("No open lots")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(openLots) { lot in
                    openLotRow(lot)
                }
            }
        }

        // Closed trades
        Section(header: Text("Closed Trades (\(closedTrades.count))")) {
            if closedTrades.isEmpty {
                Text("No closed trades yet")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(closedTrades) { trade in
                    closedTradeRow(trade)
                }
            }
        }
    }

    private func openLotRow(_ lot: OpenLot) -> some View {
        let unrealised = lot.unrealisedPnL(currentPrice: price)
        let unrealisedPct = lot.unrealisedPnLPercent(currentPrice: price)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lot.date, style: .date)
                    .font(.subheadline.weight(.medium))
                Text("\(lot.quantity.asQuantity()) @ \(lot.price.asCurrency())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(lot.daysHeld)d held")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(unrealised.asChange())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(unrealised >= 0 ? .green : .red)
                Text(unrealisedPct.asPercent())
                    .font(.caption)
                    .foregroundStyle(unrealised >= 0 ? .green : .red)
                Text(lot.totalCost.asCurrency())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func closedTradeRow(_ trade: Trade) -> some View {
        let pnlColor: Color = trade.pnl >= 0 ? .green : .red
        return Button {
            selectedTrade = trade
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(trade.exitDate, style: .date)
                            .font(.subheadline.weight(.medium))
                        Text("\(trade.holdingDays)d")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text("\(trade.quantity.asQuantity()) · \(trade.entryPrice.asCurrency()) → \(trade.exitPrice.asCurrency())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(trade.pnl.asChange())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(pnlColor)
                    Text(trade.pnlPercent.asPercent())
                        .font(.caption)
                        .foregroundStyle(pnlColor)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func row(_ label: String, _ value: String, accent: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(accent).fontWeight(.medium)
        }
    }
}
