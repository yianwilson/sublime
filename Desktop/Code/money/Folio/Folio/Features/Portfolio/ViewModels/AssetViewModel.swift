import Foundation

@MainActor
final class AssetViewModel: ObservableObject {

    // MARK: - Form State

    @Published var symbol: String = ""
    @Published var name: String = ""
    @Published var assetType: AssetType = .stock
    @Published var transactionType: TransactionType = .buy
    @Published var quantity: String = ""
    @Published var price: String = ""
    @Published var fee: String = ""
    @Published var date: Date = Date()
    @Published var coinGeckoId: String = ""

    // MARK: - Search State

    @Published private(set) var searchResults: [AssetSearchResult] = []
    @Published private(set) var isSearching = false

    private let priceService: PriceServiceProtocol
    private let searchDebounceNanoseconds: UInt64
    private var searchTask: Task<Void, Never>?

    init(
        priceService: PriceServiceProtocol = PriceService(),
        searchDebounceNanoseconds: UInt64 = 350_000_000
    ) {
        self.priceService = priceService
        self.searchDebounceNanoseconds = searchDebounceNanoseconds
    }

    // MARK: - Validation

    var isValid: Bool {
        !symbol.trimmingCharacters(in: .whitespaces).isEmpty &&
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Double(quantity) ?? 0) > 0 &&
        (Double(price) ?? 0) > 0
    }

    // MARK: - Actions

    func search(query: String) {
        searchTask?.cancel()
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            isSearching = true
            searchResults = await priceService.searchAssets(query: trimmedQuery)
            isSearching = false
        }
    }

    func selectResult(_ result: AssetSearchResult) {
        symbol      = result.symbol
        name        = result.name
        assetType   = result.assetType
        coinGeckoId = result.coinGeckoId
        searchResults = []
    }

    func buildTransaction() -> Transaction? {
        guard
            let qty   = Double(quantity), qty > 0,
            let px    = Double(price), px > 0
        else { return nil }

        return Transaction(
            symbol:      symbol.uppercased().trimmingCharacters(in: .whitespaces),
            assetType:   assetType,
            name:        name.trimmingCharacters(in: .whitespaces),
            coinGeckoId: coinGeckoId,
            type:        transactionType,
            quantity:    qty,
            price:       px,
            fee:         Double(fee) ?? 0,
            date:        date
        )
    }

    func reset() {
        symbol = ""; name = ""; quantity = ""; price = ""; fee = ""
        assetType = .stock; transactionType = .buy; coinGeckoId = ""; searchResults = []
        date = Date()
    }
}
