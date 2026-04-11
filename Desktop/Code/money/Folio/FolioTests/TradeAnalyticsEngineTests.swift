import XCTest
@testable import Folio

final class TradeAnalyticsEngineTests: XCTestCase {

    // MARK: - Fixture

    private func trade(
        symbol: String = "AAPL",
        qty: Double = 1,
        entry: Double,
        exit: Double,
        days: Int = 10
    ) -> Trade {
        let now = Date()
        let entryDate = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        return Trade(
            id: UUID().uuidString,
            symbol: symbol,
            assetType: .stock,
            quantity: qty,
            entryPrice: entry,
            entryDate: entryDate,
            exitPrice: exit,
            exitDate: now,
            fee: 0
        )
    }

    // MARK: - Tests

    func testEmptyTradesReturnsZeroAnalytics() {
        let analytics = TradeAnalyticsEngine.compute(trades: [])
        XCTAssertEqual(analytics.totalTrades, 0)
        XCTAssertEqual(analytics.winRate, 0)
        XCTAssertEqual(analytics.avgWin, 0)
        XCTAssertEqual(analytics.avgLoss, 0)
        XCTAssertEqual(analytics.profitFactor, 0)
        XCTAssertEqual(analytics.avgHoldingDays, 0)
        XCTAssertNil(analytics.bestTrade)
        XCTAssertNil(analytics.worstTrade)
        XCTAssertTrue(analytics.bySymbol.isEmpty)
    }

    func testAllWinsProducesHundredPercentWinRate() {
        let trades = [
            trade(entry: 100, exit: 110),
            trade(entry: 200, exit: 220),
            trade(entry: 50, exit: 60)
        ]
        let analytics = TradeAnalyticsEngine.compute(trades: trades)
        XCTAssertEqual(analytics.totalTrades, 3)
        XCTAssertEqual(analytics.winRate, 100, accuracy: 0.001)
        XCTAssertEqual(analytics.avgLoss, 0, accuracy: 0.001)
        // No losses → profitFactor is 0
        XCTAssertEqual(analytics.profitFactor, 0, accuracy: 0.001)
    }

    func testMixedTradesComputeCorrectMetrics() {
        // Two wins: +10, +20 → sum = 30, avg = 15
        // One loss: -5 → sum = -5, avg = -5
        // winRate = 2/3 * 100 ≈ 66.67
        // profitFactor = 30 / 5 = 6
        let trades = [
            trade(entry: 100, exit: 110, days: 5),  // +10
            trade(entry: 100, exit: 120, days: 10), // +20
            trade(entry: 100, exit: 95, days: 15)   // -5
        ]
        let analytics = TradeAnalyticsEngine.compute(trades: trades)

        XCTAssertEqual(analytics.totalTrades, 3)
        XCTAssertEqual(analytics.winRate, 2.0 / 3.0 * 100, accuracy: 0.001)
        XCTAssertEqual(analytics.avgWin, 15, accuracy: 0.001)
        XCTAssertEqual(analytics.avgLoss, -5, accuracy: 0.001)
        XCTAssertEqual(analytics.profitFactor, 6, accuracy: 0.001)
        // avgHoldingDays = (5 + 10 + 15) / 3 = 10
        XCTAssertEqual(analytics.avgHoldingDays, 10, accuracy: 0.001)
    }

    func testBySymbolGroupsCorrectly() {
        // AAPL: +10 win, -5 loss → winRate 50%, totalPnL +5
        // TSLA: +30 win → winRate 100%, totalPnL +30
        let trades = [
            trade(symbol: "AAPL", entry: 100, exit: 110, days: 10), // +10
            trade(symbol: "AAPL", entry: 100, exit: 95,  days: 5),  // -5
            trade(symbol: "TSLA", entry: 200, exit: 230, days: 20)  // +30
        ]
        let analytics = TradeAnalyticsEngine.compute(trades: trades)

        XCTAssertEqual(analytics.bySymbol.count, 2)

        let aapl = try! XCTUnwrap(analytics.bySymbol["AAPL"])
        XCTAssertEqual(aapl.totalTrades, 2)
        XCTAssertEqual(aapl.winRate, 50, accuracy: 0.001)
        XCTAssertEqual(aapl.totalPnL, 5, accuracy: 0.001)
        XCTAssertEqual(aapl.avgHoldingDays, 7.5, accuracy: 0.001)

        let tsla = try! XCTUnwrap(analytics.bySymbol["TSLA"])
        XCTAssertEqual(tsla.totalTrades, 1)
        XCTAssertEqual(tsla.winRate, 100, accuracy: 0.001)
        XCTAssertEqual(tsla.totalPnL, 30, accuracy: 0.001)
    }

    func testBestAndWorstTradeAreCorrect() {
        let best = trade(entry: 100, exit: 150, days: 5)   // pnl = +50
        let middle = trade(entry: 100, exit: 110, days: 10) // pnl = +10
        let worst = trade(entry: 100, exit: 80,  days: 15) // pnl = -20

        let analytics = TradeAnalyticsEngine.compute(trades: [middle, worst, best])

        XCTAssertEqual(analytics.bestTrade?.id, best.id)
        XCTAssertEqual(analytics.worstTrade?.id, worst.id)
    }

    func testBreakEvenTradesExcludedFromWinsAndLosses() {
        // pnl == 0 → break-even, excluded from both wins and losses
        let breakEven = trade(entry: 100, exit: 100, days: 5) // pnl = 0
        let win = trade(entry: 100, exit: 110, days: 10)       // pnl = +10

        let analytics = TradeAnalyticsEngine.compute(trades: [breakEven, win])

        // winRate = 1/2 * 100 = 50 (break-even not counted as win)
        XCTAssertEqual(analytics.winRate, 50, accuracy: 0.001)
        XCTAssertEqual(analytics.avgWin, 10, accuracy: 0.001)
        // No losses at all
        XCTAssertEqual(analytics.avgLoss, 0, accuracy: 0.001)
        XCTAssertEqual(analytics.profitFactor, 0, accuracy: 0.001)
    }
}
