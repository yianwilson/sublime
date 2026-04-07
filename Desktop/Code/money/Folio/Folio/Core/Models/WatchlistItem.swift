import Foundation

struct WatchlistItem: Identifiable, Codable, Equatable {
    let id: String
    let symbol: String
    let name: String
    let assetType: AssetType
    let coinGeckoId: String

    init(
        symbol: String,
        name: String,
        assetType: AssetType,
        coinGeckoId: String = ""
    ) {
        let normalizedSymbol = symbol.uppercased()
        self.id = normalizedSymbol + assetType.rawValue
        self.symbol = normalizedSymbol
        self.name = name
        self.assetType = assetType
        self.coinGeckoId = coinGeckoId
    }
}
