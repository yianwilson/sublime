import SwiftUI
import UniformTypeIdentifiers

private enum SortOrder: String, CaseIterable {
    case value       = "Value"
    case pnl         = "P&L $"
    case returnPct   = "Return %"
    case dailyChange = "Today"
    case symbol      = "Symbol"
}

struct PortfolioListView: View {
    @EnvironmentObject private var vm: PortfolioViewModel
    @State private var showAddAsset = false
    @State private var showImporter = false
    @State private var sortOrder: SortOrder = .value

    private var sortedHoldings: [Holding] {
        vm.holdings.sorted { a, b in
            switch sortOrder {
            case .value:       return vm.currentValue(for: a) > vm.currentValue(for: b)
            case .pnl:         return vm.pnl(for: a) > vm.pnl(for: b)
            case .returnPct:   return vm.pnlPercent(for: a) > vm.pnlPercent(for: b)
            case .dailyChange: return vm.dailyChangePercent(for: a) > vm.dailyChangePercent(for: b)
            case .symbol:      return a.symbol < b.symbol
            }
        }
    }

    var body: some View {
        List {
            ForEach(sortedHoldings) { holding in
                NavigationLink(destination: AssetDetailView(holding: holding)) {
                    HoldingRowView(holding: holding)
                }
            }
            .onDelete { offsets in
                let idsToDelete = Set(offsets.map { sortedHoldings[$0].id })
                for holding in vm.holdings where idsToDelete.contains(holding.id) {
                    vm.deleteHolding(holding)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Portfolio")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if vm.isLoading {
                    ProgressView()
                } else {
                    Menu {
                        Button {
                            Task { await vm.refreshPrices() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button {
                            showImporter = true
                        } label: {
                            Label("Import CSV", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Menu {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                if sortOrder == order {
                                    Label(order.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(order.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    Button { showAddAsset = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .refreshable {
            await vm.refreshPrices()
        }
        .sheet(isPresented: $showAddAsset) {
            AddAssetView()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText]
        ) { result in
            if case .success(let url) = result {
                Task {
                    await vm.importCSV(from: url)
                }
            }
        }
        .overlay {
            if vm.holdings.isEmpty {
                ContentUnavailableView(
                    "No Holdings",
                    systemImage: "chart.pie",
                    description: Text("Tap + to add a transaction or import a CSV file.")
                )
            }
        }
    }
}

// MARK: - Holding Row

private struct HoldingRowView: View {
    @EnvironmentObject private var vm: PortfolioViewModel
    let holding: Holding

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(holding.assetType.color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: holding.assetType.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(holding.assetType.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(holding.symbol)
                    .font(.headline)
                Text(holding.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                metricRow(
                    leading: "Value",
                    leadingValue: vm.currentValue(for: holding).asCurrency(code: vm.baseCurrencyCode),
                    trailing: "Cost",
                    trailingValue: vm.costBasis(for: holding).asCurrency(code: vm.baseCurrencyCode),
                    trailingColor: .secondary
                )

                metricRow(
                    leading: "P&L",
                    leadingValue: vm.pnl(for: holding).asChange(code: vm.baseCurrencyCode),
                    leadingColor: vm.pnl(for: holding) >= 0 ? .green : .red,
                    trailing: "P&L %",
                    trailingValue: vm.pnlPercent(for: holding).asPercent(),
                    trailingColor: vm.pnlPercent(for: holding) >= 0 ? .green : .red
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func metricRow(
        leading: String,
        leadingValue: String,
        leadingColor: Color = .primary,
        trailing: String,
        trailingValue: String,
        trailingColor: Color = .primary
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(leading)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(leadingValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(leadingColor)
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(trailing)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(trailingValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trailingColor)
            }
        }
    }
}
