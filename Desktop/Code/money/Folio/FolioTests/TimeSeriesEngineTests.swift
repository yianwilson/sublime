import XCTest
@testable import Folio

final class TimeSeriesEngineTests: XCTestCase {

    private let cal = Calendar.current

    private func day(_ offset: Int) -> Date {
        cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)
    }

    private func tx(type: TransactionType, daysAgo: Int, qty: Double, price: Double) -> Transaction {
        Transaction(symbol: "AAPL", assetType: .stock, name: "Apple", coinGeckoId: "",
                    type: type, quantity: qty, price: price, fee: 0,
                    date: day(-daysAgo))
    }

    // MARK: - Tests

    func testEmptyTransactionsReturnsEmpty() {
        let result = TimeSeriesEngine.computeDailySeries(transactions: [], priceHistory: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleBuyProducesSnapshotsFromThatDay() {
        let txs = [tx(type: .buy, daysAgo: 3, qty: 2, price: 100)]
        let prices: [String: [Date: Double]] = [
            "AAPL": [
                day(-3): 100,
                day(-2): 110,
                day(-1): 120,
                day(0):  130
            ]
        ]
        let series = TimeSeriesEngine.computeDailySeries(transactions: txs, priceHistory: prices)

        XCTAssertFalse(series.isEmpty)
        // First snapshot should be on the buy day
        XCTAssertEqual(series.first?.date, day(-3))
        // Value on buy day = 2 * 100 = 200
        XCTAssertEqual(series.first?.totalValue ?? 0, 200, accuracy: 0.01)
    }

    func testValueReflectsCurrentPrice() {
        let txs = [tx(type: .buy, daysAgo: 2, qty: 5, price: 50)]
        let prices: [String: [Date: Double]] = [
            "AAPL": [day(-2): 50, day(-1): 60, day(0): 70]
        ]
        let series = TimeSeriesEngine.computeDailySeries(transactions: txs, priceHistory: prices)
        let today = series.last

        XCTAssertEqual(today?.totalValue ?? 0, 5 * 70, accuracy: 0.01)
    }

    func testFullSellProducesNoValueAfterExit() {
        let txs = [
            tx(type: .buy,  daysAgo: 4, qty: 3, price: 100),
            tx(type: .sell, daysAgo: 2, qty: 3, price: 150)
        ]
        let prices: [String: [Date: Double]] = [
            "AAPL": [day(-4): 100, day(-3): 110, day(-2): 150, day(-1): 160, day(0): 170]
        ]
        let series = TimeSeriesEngine.computeDailySeries(transactions: txs, priceHistory: prices)

        // After sell day, no holdings → no snapshots beyond sell day
        let afterSell = series.filter { $0.date > day(-2) }
        XCTAssertTrue(afterSell.isEmpty)
    }

    func testSkipsDayWithMissingPriceAndCarriesForward() {
        let txs = [tx(type: .buy, daysAgo: 3, qty: 1, price: 100)]
        let prices: [String: [Date: Double]] = [
            // day(-2) is missing (e.g. weekend)
            "AAPL": [day(-3): 100, day(-1): 120, day(0): 130]
        ]
        let series = TimeSeriesEngine.computeDailySeries(transactions: txs, priceHistory: prices)

        // day(-2) should carry forward price from day(-3)
        let missing = series.first { cal.isDate($0.date, inSameDayAs: day(-2)) }
        XCTAssertNotNil(missing)
        XCTAssertEqual(missing?.totalValue ?? 0, 100, accuracy: 0.01)
    }
}
