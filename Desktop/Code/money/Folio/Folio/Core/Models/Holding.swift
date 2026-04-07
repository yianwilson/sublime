import Foundation

/// A derived open position, computed by FIFOEngine from the transaction log.
/// Never stored — always recomputed from transactions.
struct Holding: Identifiable, Equatable {
    let symbol: String
    let name: String
    let assetType: AssetType
    let coinGeckoId: String
    let quantity: Double             // sum of open lot quantities
    let averageCostBasis: Double     // weighted avg price of open lots (USD/unit)
    let totalCostBasis: Double       // total cost of open lots (USD)
    let realisedPnL: Double          // USD, from closed lots
    let transactions: [Transaction]  // all transactions for this symbol+type

    var id: String { symbol + assetType.rawValue }

    func currentValue(price: Double) -> Double {
        quantity * price
    }

    func unrealisedPnL(price: Double) -> Double {
        currentValue(price: price) - totalCostBasis
    }

    func unrealisedPnLPercent(price: Double) -> Double {
        guard averageCostBasis > 0 else { return 0 }
        return ((price - averageCostBasis) / averageCostBasis) * 100
    }
}
