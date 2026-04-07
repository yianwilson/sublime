import XCTest
@testable import Folio

@MainActor
final class AssetViewModelTests: XCTestCase {
    func testSearchIgnoresQueriesShorterThanTwoCharacters() async {
        let store = SearchCallStore()
        let viewModel = AssetViewModel(
            priceService: MockAssetSearchPriceService(store: store),
            searchDebounceNanoseconds: 20_000_000
        )

        viewModel.search(query: "A")
        try? await Task.sleep(nanoseconds: 60_000_000)

        let queries = await store.queries
        XCTAssertTrue(queries.isEmpty)
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testSearchDebouncesAndKeepsOnlyLatestQuery() async {
        let store = SearchCallStore()
        let viewModel = AssetViewModel(
            priceService: MockAssetSearchPriceService(store: store),
            searchDebounceNanoseconds: 50_000_000
        )

        viewModel.search(query: "AA")
        viewModel.search(query: "AAPL")
        try? await Task.sleep(nanoseconds: 150_000_000)

        let queries = await store.queries
        XCTAssertEqual(queries, ["AAPL"])
        XCTAssertEqual(viewModel.searchResults.first?.symbol, "AAPL")
    }
}

private actor SearchCallStore {
    private(set) var queries: [String] = []

    func record(_ query: String) {
        queries.append(query)
    }
}

private struct MockAssetSearchPriceService: PriceServiceProtocol {
    let store: SearchCallStore

    func fetchQuotes(for items: [PriceLookup]) async -> [String: AssetQuote] {
        [:]
    }

    func searchAssets(query: String) async -> [AssetSearchResult] {
        await store.record(query)
        return [
            AssetSearchResult(
                symbol: query.uppercased(),
                name: "\(query.uppercased()) Inc.",
                assetType: .stock,
                coinGeckoId: "",
                market: "NASDAQ",
                marketRank: nil
            )
        ]
    }
}
