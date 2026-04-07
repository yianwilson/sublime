import Foundation

enum TransactionType: String, Codable, CaseIterable, Identifiable {
    case buy  = "BUY"
    case sell = "SELL"

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

struct Transaction: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var symbol: String           // always uppercase
    var assetType: AssetType
    var name: String
    var coinGeckoId: String
    var type: TransactionType
    var quantity: Double         // always positive
    var price: Double            // per unit, USD
    var fee: Double              // total transaction fee, USD
    var date: Date
}
