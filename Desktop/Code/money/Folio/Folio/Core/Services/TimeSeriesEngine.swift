import Foundation

/// Reconstructs daily portfolio value from transactions + historical price data.
/// Pure function — no side effects, fully testable.
enum TimeSeriesEngine {

    /// Returns daily portfolio value snapshots in USD.
    /// Days where any holding has no price data are skipped.
    static func computeDailySeries(
        transactions: [Transaction],
        priceHistory: [String: [Date: Double]],
        calendar: Calendar = .current
    ) -> [PerformanceSnapshot] {
        guard !transactions.isEmpty else { return [] }

        let sortedTx = transactions.sorted { $0.date < $1.date }
        let firstDate = calendar.startOfDay(for: sortedTx[0].date)
        let today = calendar.startOfDay(for: Date())
        guard firstDate <= today else { return [] }

        // Build day list
        var days: [Date] = []
        var d = firstDate
        while d <= today {
            days.append(d)
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400)
        }

        // Running open-lots state: symbol → [(quantity, costPrice)]
        var openLots: [String: [(quantity: Double, costPrice: Double)]] = [:]
        var txIndex = 0
        var snapshots: [PerformanceSnapshot] = []

        for day in days {
            // Consume all transactions on or before this day
            while txIndex < sortedTx.count {
                let tx = sortedTx[txIndex]
                guard calendar.startOfDay(for: tx.date) <= day else { break }

                switch tx.type {
                case .buy:
                    openLots[tx.symbol, default: []].append((tx.quantity, tx.price))
                case .sell:
                    var remaining = tx.quantity
                    while remaining > 0 {
                        guard var lots = openLots[tx.symbol], !lots.isEmpty else { break }
                        let matched = min(remaining, lots[0].quantity)
                        lots[0].quantity -= matched
                        remaining -= matched
                        openLots[tx.symbol] = lots[0].quantity < 1e-10 ? Array(lots.dropFirst()) : lots
                    }
                    if openLots[tx.symbol]?.isEmpty == true { openLots.removeValue(forKey: tx.symbol) }
                case .dividend:
                    break // dividends do not affect open lot positions
                }
                txIndex += 1
            }

            guard !openLots.isEmpty else { continue }

            // Price every open symbol; skip day if any is missing
            var totalValue: Double = 0
            var allPriced = true

            for (symbol, lots) in openLots {
                guard let price = closestPrice(symbol: symbol, on: day, history: priceHistory, calendar: calendar) else {
                    allPriced = false
                    break
                }
                totalValue += lots.reduce(0) { $0 + $1.quantity } * price
            }

            if allPriced && totalValue > 0 {
                snapshots.append(PerformanceSnapshot(date: day, totalValue: totalValue))
            }
        }

        return snapshots
    }

    // MARK: - Helpers

    private static func closestPrice(
        symbol: String,
        on date: Date,
        history: [String: [Date: Double]],
        calendar: Calendar
    ) -> Double? {
        guard let h = history[symbol] else { return nil }
        if let exact = h[date] { return exact }
        for offset in 1...5 {
            if let prev = calendar.date(byAdding: .day, value: -offset, to: date),
               let price = h[prev] { return price }
        }
        return nil
    }
}
