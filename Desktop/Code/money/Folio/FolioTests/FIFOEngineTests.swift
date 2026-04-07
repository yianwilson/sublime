import XCTest
@testable import Folio

final class FIFOEngineTests: XCTestCase {

    // MARK: - Helpers

    private func buy(_ qty: Double, at price: Double, daysAgo: Int = 0) -> Transaction {
        Transaction(symbol: "TEST", assetType: .stock, name: "Test", coinGeckoId: "",
                    type: .buy, quantity: qty, price: price, fee: 0,
                    date: Date().addingTimeInterval(Double(-daysAgo) * 86400))
    }

    private func sell(_ qty: Double, at price: Double, daysAgo: Int = 0) -> Transaction {
        Transaction(symbol: "TEST", assetType: .stock, name: "Test", coinGeckoId: "",
                    type: .sell, quantity: qty, price: price, fee: 0,
                    date: Date().addingTimeInterval(Double(-daysAgo) * 86400))
    }

    // MARK: - Tests

    func testSingleBuyCreatesHolding() {
        let holdings = FIFOEngine.computeHoldings(from: [buy(10, at: 100)])
        XCTAssertEqual(holdings.count, 1)
        XCTAssertEqual(holdings[0].quantity, 10)
        XCTAssertEqual(holdings[0].averageCostBasis, 100)
        XCTAssertEqual(holdings[0].totalCostBasis, 1000)
        XCTAssertEqual(holdings[0].realisedPnL, 0)
    }

    func testFullSellClosesPosition() {
        let txs = [buy(5, at: 100, daysAgo: 1), sell(5, at: 150)]
        let holdings = FIFOEngine.computeHoldings(from: txs)
        XCTAssertTrue(holdings.isEmpty)
    }

    func testPartialSellLeavesOpenLot() {
        let txs = [buy(10, at: 100, daysAgo: 1), sell(4, at: 150)]
        let holdings = FIFOEngine.computeHoldings(from: txs)
        XCTAssertEqual(holdings.count, 1)
        XCTAssertEqual(holdings[0].quantity, 6, accuracy: 1e-9)
        XCTAssertEqual(holdings[0].totalCostBasis, 600, accuracy: 1e-9)
    }

    func testPartialSellRealisedPnL() {
        let txs = [buy(10, at: 100, daysAgo: 1), sell(4, at: 150)]
        let holdings = FIFOEngine.computeHoldings(from: txs)
        // 4 shares sold at 150, bought at 100 → realised = 4 * (150-100) = 200
        XCTAssertEqual(holdings[0].realisedPnL, 200, accuracy: 1e-9)
    }

    func testMultiLotFIFOMatchesOldestFirst() {
        // Two lots: 5 @ 100 (older), 5 @ 200 (newer). Sell 7.
        // FIFO: consume 5 from lot1 + 2 from lot2
        let txs = [
            buy(5, at: 100, daysAgo: 2),
            buy(5, at: 200, daysAgo: 1),
            sell(7, at: 150)
        ]
        let holdings = FIFOEngine.computeHoldings(from: txs)
        XCTAssertEqual(holdings.count, 1)
        XCTAssertEqual(holdings[0].quantity, 3, accuracy: 1e-9)
        // Remaining 3 shares are from lot2 @ 200
        XCTAssertEqual(holdings[0].averageCostBasis, 200, accuracy: 1e-9)
        // Realised: 5*(150-100) + 2*(150-200) = 250 - 100 = 150
        XCTAssertEqual(holdings[0].realisedPnL, 150, accuracy: 1e-9)
    }

    func testMultipleSymbolsProduceIndependentHoldings() {
        let btcBuy = Transaction(symbol: "BTC", assetType: .crypto, name: "Bitcoin", coinGeckoId: "bitcoin",
                                 type: .buy, quantity: 1, price: 50000, fee: 0, date: Date())
        let aaplBuy = Transaction(symbol: "AAPL", assetType: .stock, name: "Apple", coinGeckoId: "",
                                  type: .buy, quantity: 10, price: 150, fee: 0, date: Date())
        let holdings = FIFOEngine.computeHoldings(from: [btcBuy, aaplBuy])
        XCTAssertEqual(holdings.count, 2)
        XCTAssertNotNil(holdings.first(where: { $0.symbol == "BTC" }))
        XCTAssertNotNil(holdings.first(where: { $0.symbol == "AAPL" }))
    }

    // MARK: - openLots

    func testOpenLotsReturnsSingleLotAfterPartialSell() {
        let txs = [buy(10, at: 100, daysAgo: 2), sell(4, at: 150)]
        let lots = FIFOEngine.openLots(from: txs)
        XCTAssertEqual(lots.count, 1)
        XCTAssertEqual(lots[0].quantity, 6, accuracy: 1e-9)
        XCTAssertEqual(lots[0].price, 100)
    }

    func testOpenLotsEmptyAfterFullSell() {
        let txs = [buy(5, at: 100, daysAgo: 1), sell(5, at: 120)]
        let lots = FIFOEngine.openLots(from: txs)
        XCTAssertTrue(lots.isEmpty)
    }

    func testOpenLotsMultipleLotsPreserved() {
        let txs = [buy(3, at: 100, daysAgo: 2), buy(4, at: 200, daysAgo: 1)]
        let lots = FIFOEngine.openLots(from: txs)
        XCTAssertEqual(lots.count, 2)
        XCTAssertEqual(lots[0].quantity, 3)
        XCTAssertEqual(lots[1].quantity, 4)
    }

    // MARK: - closedTrades

    func testClosedTradesEmptyWithNoBuysOrSells() {
        let lots = FIFOEngine.closedTrades(from: [buy(5, at: 100)])
        XCTAssertTrue(lots.isEmpty)
    }

    func testClosedTradesOneTradeAfterFullSell() {
        let txs = [buy(5, at: 100, daysAgo: 10), sell(5, at: 150)]
        let trades = FIFOEngine.closedTrades(from: txs)
        XCTAssertEqual(trades.count, 1)
        XCTAssertEqual(trades[0].quantity, 5)
        XCTAssertEqual(trades[0].entryPrice, 100)
        XCTAssertEqual(trades[0].exitPrice, 150)
        XCTAssertEqual(trades[0].pnl, 250, accuracy: 1e-9)
    }

    func testClosedTradesPnLNegativeWhenSoldBelow() {
        let txs = [buy(10, at: 200, daysAgo: 5), sell(10, at: 150)]
        let trades = FIFOEngine.closedTrades(from: txs)
        XCTAssertEqual(trades[0].pnl, -500, accuracy: 1e-9)
    }

    func testClosedTradesMultiLotSellProducesMultipleTrades() {
        // Two lots consumed by one sell
        let txs = [buy(3, at: 100, daysAgo: 3), buy(2, at: 120, daysAgo: 2), sell(5, at: 150)]
        let trades = FIFOEngine.closedTrades(from: txs)
        XCTAssertEqual(trades.count, 2)
        let total = trades.reduce(0) { $0 + $1.pnl }
        // (3*(150-100)) + (2*(150-120)) = 150 + 60 = 210
        XCTAssertEqual(total, 210, accuracy: 1e-9)
    }

    func testFeeAttributedProportionallyOnSell() {
        // Buy 10 @ 100, sell 5 @ 150 with fee 10
        // Attributed fee = 10 * (5/5) = 10 (full fee, full sell)
        // Realised PnL = 5*(150-100) - 10 = 240
        let txs: [Transaction] = [
            Transaction(symbol: "TEST", assetType: .stock, name: "Test", coinGeckoId: "",
                        type: .buy, quantity: 10, price: 100, fee: 0, date: Date().addingTimeInterval(-86400)),
            Transaction(symbol: "TEST", assetType: .stock, name: "Test", coinGeckoId: "",
                        type: .sell, quantity: 5, price: 150, fee: 10, date: Date())
        ]
        let holdings = FIFOEngine.computeHoldings(from: txs)
        XCTAssertEqual(holdings[0].realisedPnL, 240, accuracy: 1e-9)
    }
}
