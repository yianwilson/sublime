import Foundation

@MainActor
final class WatchlistViewModel: ObservableObject {
    @Published private(set) var items: [WatchlistItem] = []
    @Published private(set) var quotes: [String: AssetQuote] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let priceService: PriceServiceProtocol
    private let persistence: PersistenceService

    init(
        priceService: PriceServiceProtocol = PriceService(),
        persistence: PersistenceService = PersistenceService()
    ) {
        self.priceService = priceService
        self.persistence = persistence
        self.items = persistence.loadWatchlist()
    }

    func add(_ item: WatchlistItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        items.sort { $0.symbol < $1.symbol }
        save()
        Task {
            await refreshQuotes()
        }
    }

    func deleteItems(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    func refreshQuotes() async {
        guard !items.isEmpty else { return }
        isLoading = true
        errorMessage = nil

        let lookups = items.map {
            PriceLookup(symbol: $0.symbol, assetType: $0.assetType, coinGeckoId: $0.coinGeckoId)
        }

        let latestQuotes = await priceService.fetchQuotes(for: lookups)
        if latestQuotes.isEmpty {
            errorMessage = "Could not fetch watchlist prices. Check your connection."
        } else {
            quotes = latestQuotes
        }

        isLoading = false
    }

    func quote(for item: WatchlistItem) -> AssetQuote? {
        quotes[item.symbol]
    }

    func contains(symbol: String, assetType: AssetType) -> Bool {
        items.contains { $0.symbol == symbol.uppercased() && $0.assetType == assetType }
    }

    private func save() {
        persistence.saveWatchlist(items)
    }
}
