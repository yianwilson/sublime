import Foundation

enum AlertDirection: String, Codable {
    case above = "Above"
    case below = "Below"
}

struct PriceAlert: Identifiable, Codable {
    let id: UUID
    let symbol: String
    let targetPrice: Double
    let direction: AlertDirection
    var isActive: Bool   // false after triggered to avoid repeat firing

    init(symbol: String, targetPrice: Double, direction: AlertDirection) {
        self.id = UUID()
        self.symbol = symbol
        self.targetPrice = targetPrice
        self.direction = direction
        self.isActive = true
    }
}
