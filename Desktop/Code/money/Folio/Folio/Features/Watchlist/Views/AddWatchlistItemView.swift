import SwiftUI

struct AddWatchlistItemView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var watchlistVM: WatchlistViewModel
    @StateObject private var vm = AssetViewModel()

    @State private var searchQuery = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search symbol or name...", text: $searchQuery)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .onChange(of: searchQuery) { _, query in
                                vm.search(query: query)
                            }
                        if vm.isSearching {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }

                if !vm.searchResults.isEmpty {
                    Section("Results") {
                        ForEach(vm.searchResults) { result in
                            Button {
                                watchlistVM.add(
                                    WatchlistItem(
                                        symbol: result.symbol,
                                        name: result.name,
                                        assetType: result.assetType,
                                        coinGeckoId: result.coinGeckoId
                                    )
                                )
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: result.assetType.icon)
                                        .foregroundStyle(result.assetType.color)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.symbol).bold()
                                        Text(result.name)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let metadata = metadataText(for: result) {
                                            Text(metadata)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        if let badge = badgeText(for: result) {
                                            Text(badge)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                                .foregroundStyle(.secondary)
                                        }
                                        if watchlistVM.contains(symbol: result.symbol, assetType: result.assetType) {
                                            Text("Added")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .disabled(watchlistVM.contains(symbol: result.symbol, assetType: result.assetType))
                            .tint(.primary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add Watchlist Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func badgeText(for result: AssetSearchResult) -> String? {
        switch result.assetType {
        case .crypto:
            guard let rank = result.marketRank else { return nil }
            return "Rank #\(rank)"
        case .stock, .etf:
            return result.market
        }
    }

    private func metadataText(for result: AssetSearchResult) -> String? {
        nil
    }
}
