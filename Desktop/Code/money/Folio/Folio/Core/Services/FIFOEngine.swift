import Foundation

/// Pure FIFO trade-matching engine. No side effects, fully testable.
enum FIFOEngine {

    static func computeHoldings(from transactions: [Transaction]) -> [Holding] {
        let groups = Dictionary(grouping: transactions) { $0.symbol + $0.assetType.rawValue }

        return groups.compactMap { _, txs -> Holding? in
            let sorted = txs.sorted { $0.date < $1.date }
            guard let first = sorted.first else { return nil }

            var openLots: [(quantity: Double, price: Double)] = []
            var realisedPnL: Double = 0

            for tx in sorted {
                switch tx.type {
                case .buy:
                    openLots.append((tx.quantity, tx.price))

                case .sell:
                    var remaining = tx.quantity
                    while remaining > 0, !openLots.isEmpty {
                        let matched = min(remaining, openLots[0].quantity)
                        let lotPrice = openLots[0].price
                        // Attribute fees proportionally to the matched quantity
                        let attributedFee = tx.quantity > 0 ? tx.fee * (matched / tx.quantity) : 0
                        realisedPnL += matched * (tx.price - lotPrice) - attributedFee
                        openLots[0].quantity -= matched
                        remaining -= matched
                        if openLots[0].quantity < 1e-10 { openLots.removeFirst() }
                    }
                }
            }

            let openQuantity = openLots.reduce(0) { $0 + $1.quantity }
            guard openQuantity > 1e-10 else { return nil } // fully liquidated

            let totalCostBasis    = openLots.reduce(0) { $0 + $1.quantity * $1.price }
            let averageCostBasis  = totalCostBasis / openQuantity

            return Holding(
                symbol:           first.symbol,
                name:             first.name,
                assetType:        first.assetType,
                coinGeckoId:      first.coinGeckoId,
                quantity:         openQuantity,
                averageCostBasis: averageCostBasis,
                totalCostBasis:   totalCostBasis,
                realisedPnL:      realisedPnL,
                transactions:     sorted
            )
        }
        .sorted { $0.symbol < $1.symbol }
    }

    /// Returns all open (unmatched BUY) lots for a set of pre-filtered, date-sorted transactions.
    static func openLots(from transactions: [Transaction]) -> [OpenLot] {
        let sorted = transactions.sorted { $0.date < $1.date }
        var lots: [(date: Date, quantity: Double, price: Double, index: Int)] = []

        for tx in sorted {
            switch tx.type {
            case .buy:
                lots.append((tx.date, tx.quantity, tx.price, lots.count))
            case .sell:
                var remaining = tx.quantity
                while remaining > 0, !lots.isEmpty {
                    let matched = min(remaining, lots[0].quantity)
                    lots[0].quantity -= matched
                    remaining -= matched
                    if lots[0].quantity < 1e-10 { lots.removeFirst() }
                }
            }
        }

        return lots.enumerated().map { idx, lot in
            OpenLot(
                id: "\(lot.date.timeIntervalSince1970)-\(idx)",
                date: lot.date,
                quantity: lot.quantity,
                price: lot.price
            )
        }
    }

    /// Returns all closed (fully matched BUY→SELL) trades for a set of pre-filtered, date-sorted transactions.
    static func closedTrades(from transactions: [Transaction]) -> [Trade] {
        guard let first = transactions.first else { return [] }
        let sorted = transactions.sorted { $0.date < $1.date }

        struct Lot { var date: Date; var quantity: Double; let price: Double }
        var lots: [Lot] = []
        var trades: [Trade] = []

        for tx in sorted {
            switch tx.type {
            case .buy:
                lots.append(Lot(date: tx.date, quantity: tx.quantity, price: tx.price))
            case .sell:
                var remaining = tx.quantity
                while remaining > 0, !lots.isEmpty {
                    let matched = min(remaining, lots[0].quantity)
                    let attributedFee = tx.quantity > 0 ? tx.fee * (matched / tx.quantity) : 0
                    trades.append(Trade(
                        id: "\(lots[0].date.timeIntervalSince1970)-\(tx.date.timeIntervalSince1970)-\(matched)",
                        symbol: first.symbol,
                        assetType: first.assetType,
                        quantity: matched,
                        entryPrice: lots[0].price,
                        entryDate: lots[0].date,
                        exitPrice: tx.price,
                        exitDate: tx.date,
                        fee: attributedFee
                    ))
                    lots[0].quantity -= matched
                    remaining -= matched
                    if lots[0].quantity < 1e-10 { lots.removeFirst() }
                }
            }
        }

        return trades.sorted { $0.exitDate > $1.exitDate }
    }
}
