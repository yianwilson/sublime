import SwiftUI

struct WatchlistView: View {
    @EnvironmentObject private var vm: WatchlistViewModel
    @State private var showAddItem = false

    var body: some View {
        List {
            ForEach(vm.items) { item in
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
                Button {
                    showAddItem = true
                } label: {
                    Image(systemName: "plus")
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
                Text(item.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text((quote?.currentPrice ?? 0).asCurrency(code: quote?.currencyCode ?? "USD"))
                    .font(.subheadline.weight(.semibold))
                Text(dailyChangePercent.asPercent())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(dailyChangePercent >= 0 ? .green : .red)
            }
        }
        .padding(.vertical, 4)
    }
}
