import Foundation

struct TradeAnalytics {
    let totalTrades: Int
    let winRate: Double          // 0–100 %
    let avgWin: Double           // avg P&L of winning trades (USD)
    let avgLoss: Double          // avg P&L of losing trades (USD, negative)
    let profitFactor: Double     // abs(sum wins) / abs(sum losses); 0 if no losses
    let avgHoldingDays: Double
    let bestTrade: Trade?
    let worstTrade: Trade?

    // Per-symbol breakdown (symbol → stats)
    let bySymbol: [String: SymbolStats]
}

struct SymbolStats {
    let symbol: String
    let totalTrades: Int
    let winRate: Double
    let totalPnL: Double         // USD
    let avgHoldingDays: Double
}

enum TradeAnalyticsEngine {

    static func compute(trades: [Trade]) -> TradeAnalytics {
        guard !trades.isEmpty else {
            return TradeAnalytics(
                totalTrades: 0,
                winRate: 0,
                avgWin: 0,
                avgLoss: 0,
                profitFactor: 0,
                avgHoldingDays: 0,
                bestTrade: nil,
                worstTrade: nil,
                bySymbol: [:]
            )
        }

        let wins = trades.filter { $0.pnl > 0 }
        let losses = trades.filter { $0.pnl < 0 }

        let winRate: Double = Double(wins.count) / Double(trades.count) * 100

        let avgWin: Double = wins.isEmpty
            ? 0
            : wins.reduce(0) { $0 + $1.pnl } / Double(wins.count)

        let avgLoss: Double = losses.isEmpty
            ? 0
            : losses.reduce(0) { $0 + $1.pnl } / Double(losses.count)

        let sumWins = wins.reduce(0) { $0 + $1.pnl }
        let sumLosses = losses.reduce(0) { $0 + $1.pnl }
        let profitFactor: Double = losses.isEmpty
            ? 0
            : sumWins / abs(sumLosses)

        let avgHoldingDays: Double = trades.reduce(0) { $0 + Double($1.holdingDays) } / Double(trades.count)

        let bestTrade = trades.max(by: { $0.pnl < $1.pnl })
        let worstTrade = trades.min(by: { $0.pnl < $1.pnl })

        let bySymbol = computeBySymbol(trades: trades)

        return TradeAnalytics(
            totalTrades: trades.count,
            winRate: winRate,
            avgWin: avgWin,
            avgLoss: avgLoss,
            profitFactor: profitFactor,
            avgHoldingDays: avgHoldingDays,
            bestTrade: bestTrade,
            worstTrade: worstTrade,
            bySymbol: bySymbol
        )
    }

    // MARK: - Private

    private static func computeBySymbol(trades: [Trade]) -> [String: SymbolStats] {
        let grouped = Dictionary(grouping: trades, by: \.symbol)

        return grouped.reduce(into: [:]) { result, entry in
            let symbol = entry.key
            let symbolTrades = entry.value
            let symbolWins = symbolTrades.filter { $0.pnl > 0 }
            let winRate = Double(symbolWins.count) / Double(symbolTrades.count) * 100
            let totalPnL = symbolTrades.reduce(0) { $0 + $1.pnl }
            let avgHoldingDays = symbolTrades.reduce(0) { $0 + Double($1.holdingDays) } / Double(symbolTrades.count)

            result[symbol] = SymbolStats(
                symbol: symbol,
                totalTrades: symbolTrades.count,
                winRate: winRate,
                totalPnL: totalPnL,
                avgHoldingDays: avgHoldingDays
            )
        }
    }
}
