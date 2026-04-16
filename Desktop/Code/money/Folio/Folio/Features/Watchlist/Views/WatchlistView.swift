import SwiftUI

private enum WatchlistSortOrder: String, CaseIterable {
    case name   = "Name"
    case price  = "Price"
    case change = "Change %"
}

struct WatchlistView: View {
    @EnvironmentObject private var vm: WatchlistViewModel
    @State private var showAddItem = false
    @State private var sortOrder: WatchlistSortOrder = .name

    private var sortedItems: [WatchlistItem] {
        switch sortOrder {
        case .name:
            return vm.items.sorted { $0.symbol < $1.symbol }
        case .price:
            return vm.items.sorted { (vm.quote(for: $0)?.currentPrice ?? 0) > (vm.quote(for: $1)?.currentPrice ?? 0) }
        case .change:
            return vm.items.sorted { (vm.quote(for: $0)?.dailyChangePercent ?? 0) > (vm.quote(for: $1)?.dailyChangePercent ?? 0) }
        }
    }

    var body: some View {
        List {
            ForEach(sortedItems) { item in
                WatchlistRow(item: item)
            }
            .onDelete(perform: vm.deleteItems)
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Watchlist")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if vm.isLoading {
                    ProgressView()
                } else {
                    Button {
                        Task { await vm.refreshQuotes() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(WatchlistSortOrder.allCases, id: \.self) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    Button {
                        showAddItem = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .refreshable {
            await vm.refreshQuotes()
        }
        .sheet(isPresented: $showAddItem) {
            AddWatchlistItemView()
                .environmentObject(vm)
        }
        .overlay {
            if vm.items.isEmpty {
                ContentUnavailableView(
                    "No Watchlist Items",
                    systemImage: "star",
                    description: Text("Tap + to add assets you want to monitor.")
                )
            }
        }
        .task {
            await vm.refreshQuotes()
        }
    }
}

private struct WatchlistRow: View {
    @EnvironmentObject private var vm: WatchlistViewModel
    let item: WatchlistItem

    private var quote: AssetQuote? {
        vm.quote(for: item)
    }

    private var dailyChangePercent: Double {
        quote?.dailyChangePercent ?? 0
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(item.assetType.color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: item.assetType.icon)
                    .foregroundStyle(item.assetType.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.symbol)
                    .font(.headline)
                Text(item.assetType.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text((quote?.currentPrice ?? 0).asCurrency(code: quote?.currencyCode ?? "USD"))
                    .font(.subheadline.weight(.medium))
                Text(dailyChangePercent.asPercent())
                    .font(.caption)
                    .foregroundStyle(dailyChangePercent >= 0 ? .green : .red)
                if let q = quote, q.previousClose != nil {
                    Text(q.dailyChange.asChange(code: q.currencyCode))
                        .font(.caption2)
                        .foregroundStyle(q.dailyChange >= 0 ? .green : .red)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
