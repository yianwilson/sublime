import XCTest
@testable import Folio

@MainActor
final class PortfolioViewModelTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1.0, forKey: "audPerUSD")
        tempDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        super.tearDown()
    }

    func testPortfolioViewModelInit() {
        let viewModel = makeViewModel(snapshots: [])

        XCTAssertEqual(viewModel.totalPortfolioValue, 0)
        XCTAssertTrue(viewModel.performanceSeries.isEmpty)
        XCTAssertTrue(viewModel.insights.contains { $0.title == "No portfolio data yet" })
    }

    func testFullyLiquidatedPositionExcludedFromHoldings() {
        let viewModel = makeViewModel(snapshots: [])
        let buyTx = makeTx(symbol: "ZERO", type: .buy, qty: 1, price: 10, daysAgo: 1)
        let sellTx = makeTx(symbol: "ZERO", type: .sell, qty: 1, price: 15, daysAgo: 0)
        viewModel.addTransaction(buyTx)
        viewModel.addTransaction(sellTx)
        XCTAssertTrue(viewModel.holdings.isEmpty)
    }

    func testPnlPercentReturnsZeroWhenBuyPriceEqualsCurrentPrice() async {
        let viewModel = makeViewModel(
            snapshots: [],
            quotes: ["FLAT": AssetQuote(currentPrice: 50, previousClose: nil, currencyCode: "USD")]
        )
        viewModel.addTransaction(makeTx(symbol: "FLAT", type: .buy, qty: 2, price: 50))
        await viewModel.refreshPrices()

        guard let holding = viewModel.holdings.first(where: { $0.symbol == "FLAT" }) else {
            XCTFail("Expected holding for FLAT"); return
        }
        XCTAssertEqual(viewModel.pnl(for: holding), 0)
        XCTAssertEqual(viewModel.pnlPercent(for: holding), 0)
    }

    func testPnlPercentReturnsNegativeValueWhenPositionIsDown() async {
        let viewModel = makeViewModel(
            snapshots: [],
            quotes: ["LOSS": AssetQuote(currentPrice: 80, previousClose: nil, currencyCode: "USD")]
        )
        viewModel.addTransaction(makeTx(symbol: "LOSS", type: .buy, qty: 2, price: 100))
        await viewModel.refreshPrices()

        guard let holding = viewModel.holdings.first(where: { $0.symbol == "LOSS" }) else {
            XCTFail("Expected holding for LOSS"); return
        }
        XCTAssertEqual(viewModel.pnl(for: holding), -40 * viewModel.audPerUSD, accuracy: 0.0001)
        XCTAssertEqual(viewModel.pnlPercent(for: holding), -20, accuracy: 0.0001)
    }

    func testFilteredPerformanceSeriesForOneWeek() {
        let viewModel = makeViewModel(
            snapshots: makeSnapshots(dayOffsets: [-10, -6, -3, 0], baseDate: referenceDate)
        )

        let filtered = viewModel.filteredPerformanceSeries(range: .oneWeek, referenceDate: referenceDate)

        XCTAssertEqual(filtered.map(\.totalValue), [200, 300, 400])
    }

    func testFilteredPerformanceSeriesForOneMonth() {
        let viewModel = makeViewModel(
            snapshots: makeSnapshots(dayOffsets: [-40, -20, -5, 0], baseDate: referenceDate)
        )

        let filtered = viewModel.filteredPerformanceSeries(range: .oneMonth, referenceDate: referenceDate)

        XCTAssertEqual(filtered.map(\.totalValue), [200, 300, 400])
    }

    func testFilteredPerformanceSeriesForThreeMonths() {
        let viewModel = makeViewModel(
            snapshots: makeSnapshots(dayOffsets: [-120, -70, -10, 0], baseDate: referenceDate)
        )

        let filtered = viewModel.filteredPerformanceSeries(range: .threeMonths, referenceDate: referenceDate)

        XCTAssertEqual(filtered.map(\.totalValue), [200, 300, 400])
    }

    func testFilteredPerformanceSeriesForOneYear() {
        let viewModel = makeViewModel(
            snapshots: makeSnapshots(dayOffsets: [-500, -300, -30, 0], baseDate: referenceDate)
        )

        let filtered = viewModel.filteredPerformanceSeries(range: .oneYear, referenceDate: referenceDate)

        XCTAssertEqual(filtered.map(\.totalValue), [200, 300, 400])
    }

    func testFilteredPerformanceSeriesForAllReturnsEverything() {
        let viewModel = makeViewModel(
            snapshots: makeSnapshots(dayOffsets: [-500, -300, -30, 0], baseDate: referenceDate)
        )

        let filtered = viewModel.filteredPerformanceSeries(range: .all, referenceDate: referenceDate)

        XCTAssertEqual(filtered.map(\.totalValue), [100, 200, 300, 400])
    }

    private var referenceDate: Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
    }

    private func makeViewModel(
        snapshots: [PerformanceSnapshot],
        quotes: [String: AssetQuote] = [:]
    ) -> PortfolioViewModel {
        let persistence = PersistenceService(directoryURL: tempDirectoryURL)
        persistence.saveSnapshots(snapshots)
        return PortfolioViewModel(
            priceService: MockPriceService(quotes: quotes),
            persistence: persistence
        )
    }

    private func makeTx(
        symbol: String,
        type: TransactionType,
        qty: Double,
        price: Double,
        daysAgo: Int = 0
    ) -> Transaction {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return Transaction(
            symbol: symbol, assetType: .stock, name: symbol,
            coinGeckoId: "", type: type,
            quantity: qty, price: price, fee: 0, date: date
        )
    }

    private func makeSnapshots(dayOffsets: [Int], baseDate: Date) -> [PerformanceSnapshot] {
        dayOffsets.enumerated().map { index, dayOffset in
            let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: baseDate) ?? baseDate
            return PerformanceSnapshot(date: date, totalValue: Double((index + 1) * 100))
        }
    }
}

private struct MockPriceService: PriceServiceProtocol {
    var quotes: [String: AssetQuote] = [:]

    init(quotes: [String: AssetQuote] = [:]) {
        self.quotes = quotes
    }

    func fetchQuotes(for items: [PriceLookup]) async -> [String: AssetQuote] {
        quotes
    }

    func searchAssets(query: String) async -> [AssetSearchResult] {
        []
    }
}
