import Foundation

/// A matched BUY→SELL pair produced by the FIFO engine.
struct Trade: Identifiable {
    let id: String
    let symbol: String
    let assetType: AssetType
    let quantity: Double
    let entryPrice: Double
    let entryDate: Date
    let exitPrice: Double
    let exitDate: Date
    let fee: Double
    let entryNotes: String?

    init(
        id: String,
        symbol: String,
        assetType: AssetType,
        quantity: Double,
        entryPrice: Double,
        entryDate: Date,
        exitPrice: Double,
        exitDate: Date,
        fee: Double,
        entryNotes: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.assetType = assetType
        self.quantity = quantity
        self.entryPrice = entryPrice
        self.entryDate = entryDate
        self.exitPrice = exitPrice
        self.exitDate = exitDate
        self.fee = fee
        self.entryNotes = entryNotes
    }

    var pnl: Double { quantity * (exitPrice - entryPrice) - fee }
    var pnlPercent: Double {
        guard entryPrice > 0 else { return 0 }
        return (exitPrice - entryPrice) / entryPrice * 100
    }
    var holdingDays: Int {
        Calendar.current.dateComponents([.day], from: entryDate, to: exitDate).day ?? 0
    }
}

/// A single unmatched BUY lot still open in a position.
struct OpenLot: Identifiable {
    let id: String
    let date: Date
    let quantity: Double
    let price: Double

    var totalCost: Double { quantity * price }
    var daysHeld: Int {
        Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
    }
    func unrealisedPnL(currentPrice: Double) -> Double { quantity * (currentPrice - price) }
    func unrealisedPnLPercent(currentPrice: Double) -> Double {
        guard price > 0 else { return 0 }
        return (currentPrice - price) / price * 100
    }
}
