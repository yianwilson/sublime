import Foundation

struct AssetQuote: Codable, Equatable {
    let currentPrice: Double
    let previousClose: Double?
    let currencyCode: String
    let sector: String?
    let preMarketPrice: Double?
    let postMarketPrice: Double?

    init(
        currentPrice: Double,
        previousClose: Double?,
        currencyCode: String,
        sector: String?,
        preMarketPrice: Double? = nil,
        postMarketPrice: Double? = nil
    ) {
        self.currentPrice = currentPrice
        self.previousClose = previousClose
        self.currencyCode = currencyCode
        self.sector = sector
        self.preMarketPrice = preMarketPrice
        self.postMarketPrice = postMarketPrice
    }

    var dailyChange: Double {
        guard let previousClose else { return 0 }
        return currentPrice - previousClose
    }

    var dailyChangePercent: Double {
        guard let previousClose, previousClose > 0 else { return 0 }
        return ((currentPrice - previousClose) / previousClose) * 100
    }

    var extendedHoursPrice: Double? {
        postMarketPrice ?? preMarketPrice
    }

    var extendedHoursLabel: String {
        if postMarketPrice != nil { return "After Hours" }
        if preMarketPrice != nil { return "Pre-Market" }
        return ""
    }
}
