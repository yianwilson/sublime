import XCTest
@testable import Folio

@MainActor
final class WatchlistViewModelTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUp() {
        super.setUp()
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

    func testAddInsertsItem() {
        let viewModel = makeViewModel()

        viewModel.add(WatchlistItem(symbol: "NVDA", name: "NVIDIA", assetType: .stock))

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.items.first?.symbol, "NVDA")
    }

    func testDeleteRemovesItem() {
        let viewModel = makeViewModel(items: [
            WatchlistItem(symbol: "NVDA", name: "NVIDIA", assetType: .stock),
            WatchlistItem(symbol: "BTC", name: "Bitcoin", assetType: .crypto)
        ])

        let deletedSymbol = viewModel.items[0].symbol
        viewModel.deleteItems(at: IndexSet(integer: 0))

        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertNotEqual(viewModel.items.first?.symbol, deletedSymbol)
    }

    func testDuplicatePreventionKeepsSingleItem() {
        let viewModel = makeViewModel()
        let item = WatchlistItem(symbol: "ETH", name: "Ethereum", assetType: .crypto)

        viewModel.add(item)
        viewModel.add(item)

        XCTAssertEqual(viewModel.items.count, 1)
    }

    private func makeViewModel(items: [WatchlistItem] = []) -> WatchlistViewModel {
        let persistence = PersistenceService(directoryURL: tempDirectoryURL)
        persistence.saveWatchlist(items)
        return WatchlistViewModel(
            priceService: MockWatchlistPriceService(),
            persistence: persistence
        )
    }
}

private struct MockWatchlistPriceService: PriceServiceProtocol {
    func fetchQuotes(for items: [PriceLookup]) async -> [String: AssetQuote] {
        Dictionary(uniqueKeysWithValues: items.map {
            ($0.symbol, AssetQuote(currentPrice: 100, previousClose: 95, currencyCode: "USD", sector: nil))
        })
    }

    func searchAssets(query: String) async -> [AssetSearchResult] {
        []
    }
}
