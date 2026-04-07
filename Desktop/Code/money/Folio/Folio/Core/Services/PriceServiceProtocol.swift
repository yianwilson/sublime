import Foundation

protocol PriceServiceProtocol {
    func fetchQuotes(for items: [PriceLookup]) async -> [String: AssetQuote]
    func searchAssets(query: String) async -> [AssetSearchResult]
}

/// Minimal data needed to fetch a price quote — decoupled from Holding and WatchlistItem.
struct PriceLookup {
    let symbol: String
    let assetType: AssetType
    let coinGeckoId: String
}

struct AssetSearchResult: Identifiable {
    var id: String { symbol + assetType.rawValue }
    let symbol: String
    let name: String
    let assetType: AssetType
    let coinGeckoId: String
    let market: String?
    let marketRank: Int?
}
