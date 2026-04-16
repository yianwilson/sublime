import Foundation

struct AssetQuote: Codable, Equatable {
    let currentPrice: Double
    let previousClose: Double?
    let currencyCode: String
    let sector: String?

    var dailyChange: Double {
        guard let previousClose else { return 0 }
        return currentPrice - previousClose
    }

    var dailyChangePercent: Double {
        guard let previousClose, previousClose > 0 else { return 0 }
        return ((currentPrice - previousClose) / previousClose) * 100
    }
}
