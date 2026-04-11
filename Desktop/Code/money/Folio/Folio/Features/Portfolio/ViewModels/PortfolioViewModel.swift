import Foundation
import Combine

enum PerformanceRange: String, CaseIterable, Identifiable {
    case oneWeek = "1W"
    case oneMonth = "1M"
    case threeMonths = "3M"
    case oneYear = "1Y"
    case all = "All"

    var id: String { rawValue }
}

@MainActor
final class PortfolioViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var transactions: [Transaction] = []
    @Published private(set) var quotes: [String: AssetQuote] = [:]
    @Published private(set) var audPerUSD: Double
    @Published private(set) var snapshots: [PerformanceSnapshot] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var upcomingEvents: [UpcomingEvent] = []
    @Published private(set) var reconstructedSeries: [PerformanceSnapshot] = []
    @Published private(set) var isReconstructing = false

    // MARK: - Dependencies

    private let priceService: PriceServiceProtocol
    private let persistence: PersistenceService
    private let insightsService: PortfolioInsightsService
    private let currencyService: CurrencyServiceProtocol
    private let eventsService: EventsServiceProtocol
    private let historicalPriceService = HistoricalPriceService()

    init(
        priceService: PriceServiceProtocol = PriceService(),
        persistence: PersistenceService = PersistenceService(),
        insightsService: PortfolioInsightsService = PortfolioInsightsService(),
        currencyService: CurrencyServiceProtocol = CurrencyService(),
        eventsService: EventsServiceProtocol = EventsService()
    ) {
        self.priceService = priceService
        self.persistence = persistence
        self.insightsService = insightsService
        self.currencyService = currencyService
        self.eventsService = eventsService
        self.audPerUSD = currencyService.cachedAUDPerUSD
        self.transactions = persistence.loadTransactions()
        self.snapshots = persistence.loadSnapshots()
    }

    // MARK: - Derived Holdings

    var holdings: [Holding] {
        FIFOEngine.computeHoldings(from: transactions)
    }

    // MARK: - Trade Analytics

    var tradeAnalytics: TradeAnalytics {
        let allTrades = holdings.flatMap { FIFOEngine.closedTrades(from: $0.transactions) }
        return TradeAnalyticsEngine.compute(trades: allTrades)
    }

    // MARK: - Computed Portfolio Metrics

    var baseCurrencyCode: String {
        "AUD"
    }

    var insights: [Insight] {
        insightsService.generateInsights(holdings: holdings, quotes: quotes)
    }

    var totalPortfolioValue: Double {
        holdings.reduce(0) { $0 + currentValue(for: $1) }
    }

    var totalCostBasis: Double {
        holdings.reduce(0) { $0 + costBasis(for: $1) }
    }

    var totalPnL: Double {
        totalPortfolioValue - totalCostBasis
    }

    var totalPnLPercent: Double {
        guard totalCostBasis > 0 else { return 0 }
        return (totalPnL / totalCostBasis) * 100
    }

    var totalDailyChange: Double {
        holdings.reduce(0) { $0 + dailyChangeValue(for: $1) }
    }

    var totalDailyChangePercent: Double {
        let previousValue = holdings.reduce(0.0) { sum, holding in
            guard let prev = quotes[holding.symbol]?.previousClose else { return sum + currentValue(for: holding) }
            return sum + audValue(prev * holding.quantity)
        }
        guard previousValue > 0 else { return 0 }
        return (totalDailyChange / previousValue) * 100
    }

    var allocationByType: [(AssetType, Double)] {
        guard totalPortfolioValue > 0 else { return [] }
        let grouped = Dictionary(grouping: holdings, by: \.assetType)
        return AssetType.allCases.compactMap { type in
            let value = grouped[type]?.reduce(0.0) { $0 + currentValue(for: $1) } ?? 0
            guard value > 0 else { return nil }
            return (type, value / totalPortfolioValue * 100)
        }.sorted { $0.1 > $1.1 }
    }

    var performanceSeries: [PerformanceSnapshot] {
        snapshots
    }

    func filteredPerformanceSeries(
        range: PerformanceRange,
        series: [PerformanceSnapshot]? = nil,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [PerformanceSnapshot] {
        let source = series ?? performanceSeries
        guard range != .all else { return source }

        let startOfReferenceDay = calendar.startOfDay(for: referenceDate)
        let cutoff: Date?

        switch range {
        case .oneWeek:
            cutoff = calendar.date(byAdding: .day, value: -6, to: startOfReferenceDay)
        case .oneMonth:
            cutoff = calendar.date(byAdding: .month, value: -1, to: startOfReferenceDay)
        case .threeMonths:
            cutoff = calendar.date(byAdding: .month, value: -3, to: startOfReferenceDay)
        case .oneYear:
            cutoff = calendar.date(byAdding: .year, value: -1, to: startOfReferenceDay)
        case .all:
            cutoff = nil
        }

        guard let cutoff else { return source }
        return source.filter { $0.date >= cutoff && $0.date <= referenceDate }
    }

    // MARK: - Actions

    func addTransaction(_ transaction: Transaction) {
        transactions.append(transaction)
        persistence.saveTransactions(transactions)
        Task {
            await refreshPrices()
        }
    }

    func deleteHolding(_ holding: Holding) {
        transactions.removeAll { $0.symbol == holding.symbol && $0.assetType == holding.assetType }
        persistence.saveTransactions(transactions)
        recordSnapshot()
    }

    func refreshPrices() async {
        isLoading = true
        errorMessage = nil

        let lookups = holdings.map {
            PriceLookup(symbol: $0.symbol, assetType: $0.assetType, coinGeckoId: $0.coinGeckoId)
        }

        async let fetchedQuotes = priceService.fetchQuotes(for: lookups)
        async let fetchedRate = fetchAUDRateResult()

        let (latestQuotes, rateResult) = await (fetchedQuotes, fetchedRate)

        if !latestQuotes.isEmpty {
            quotes.merge(latestQuotes) { _, new in new }
        } else if !holdings.isEmpty {
            appendError("Could not fetch live prices. Check your connection.")
        }

        switch rateResult {
        case .success(let rate):
            audPerUSD = rate
        case .failure:
            appendError("Using cached AUD conversion rate.")
        }

        recordSnapshot()
        let stockSymbols = holdings.filter { $0.assetType == .stock || $0.assetType == .etf }.map(\.symbol)
        upcomingEvents = await eventsService.fetchEvents(ownedSymbols: stockSymbols)
        isLoading = false

        // Rebuild time series in background — doesn't block UI
        Task { await buildTimeSeries() }
    }

    func buildTimeSeries() async {
        guard !transactions.isEmpty else { return }
        isReconstructing = true

        let lookups = holdings.map {
            PriceLookup(symbol: $0.symbol, assetType: $0.assetType, coinGeckoId: $0.coinGeckoId)
        }
        let startDate = transactions.min(by: { $0.date < $1.date })?.date ?? Date()

        let priceHistory = await historicalPriceService.fetchPriceHistory(for: lookups, from: startDate)
        let seriesUSD = TimeSeriesEngine.computeDailySeries(transactions: transactions, priceHistory: priceHistory)

        // Convert to AUD using current rate
        reconstructedSeries = seriesUSD.map {
            PerformanceSnapshot(date: $0.date, totalValue: $0.totalValue * audPerUSD)
        }
        isReconstructing = false
    }

    func importCSV(from url: URL) async {
        errorMessage = nil

        do {
            let imported = try parseCSV(from: url)
            guard !imported.isEmpty else {
                errorMessage = "CSV did not contain any valid asset rows."
                return
            }

            transactions.append(contentsOf: imported)
            persistence.saveTransactions(transactions)
            await refreshPrices()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Holding Values

    func livePrice(for holding: Holding) -> Double {
        quotes[holding.symbol]?.currentPrice ?? holding.averageCostBasis
    }

    func dailyChangePercent(for holding: Holding) -> Double {
        quotes[holding.symbol]?.dailyChangePercent ?? 0
    }

    func dailyChangeValue(for holding: Holding) -> Double {
        guard let previousClose = quotes[holding.symbol]?.previousClose else { return 0 }
        let currentPrice = livePrice(for: holding)
        return audValue((currentPrice - previousClose) * holding.quantity)
    }

    func currentValue(for holding: Holding) -> Double {
        audValue(holding.currentValue(price: livePrice(for: holding)))
    }

    func costBasis(for holding: Holding) -> Double {
        audValue(holding.totalCostBasis)
    }

    func pnl(for holding: Holding) -> Double {
        currentValue(for: holding) - costBasis(for: holding)
    }

    func pnlPercent(for holding: Holding) -> Double {
        let basis = costBasis(for: holding)
        guard basis > 0 else { return 0 }
        return (pnl(for: holding) / basis) * 100
    }

    // MARK: - Persistence

    private func recordSnapshot() {
        snapshots = persistence.upsertDailySnapshot(totalValue: totalPortfolioValue)
    }

    // MARK: - Helpers

    private func fetchAUDRateResult() async -> Result<Double, Error> {
        do {
            return .success(try await currencyService.fetchAUDPerUSD())
        } catch {
            return .failure(error)
        }
    }

    private func audValue(_ usdValue: Double) -> Double {
        usdValue * audPerUSD
    }

    private func appendError(_ message: String) {
        if let errorMessage, !errorMessage.isEmpty {
            self.errorMessage = "\(errorMessage) \(message)"
        } else {
            errorMessage = message
        }
    }

    private func parseCSV(from url: URL) throws -> [Transaction] {
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let header = lines.first?.lowercased(),
              header == "symbol,quantity,price,type,date,assettype" else {
            throw CSVImportError.invalidHeader
        }

        var imported: [Transaction] = []

        for (index, line) in lines.dropFirst().enumerated() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard columns.count == 6 else {
                throw CSVImportError.invalidRow(index + 2)
            }

            let rawType = columns[3].lowercased()
            let transactionType: TransactionType
            switch rawType {
            case "buy":
                transactionType = .buy
            case "sell":
                transactionType = .sell
            default:
                throw CSVImportError.invalidRow(index + 2)
            }

            guard
                !columns[0].isEmpty,
                let quantity = Double(columns[1]), quantity > 0,
                let price = Double(columns[2]), price > 0,
                let date = parseDate(columns[4]),
                let assetType = parseAssetType(columns[5])
            else {
                throw CSVImportError.invalidRow(index + 2)
            }

            let symbol = columns[0].uppercased()
            imported.append(
                Transaction(
                    symbol:      symbol,
                    assetType:   assetType,
                    name:        symbol,
                    coinGeckoId: "",
                    type:        transactionType,
                    quantity:    quantity,
                    price:       price,
                    fee:         0,
                    date:        date
                )
            )
        }

        return imported
    }

    private func parseDate(_ value: String) -> Date? {
        let formatters = [
            { () -> DateFormatter in
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
            }(),
            { () -> DateFormatter in
                let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy"; f.locale = Locale(identifier: "en_US_POSIX"); return f
            }()
        ]
        return formatters.compactMap { $0.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) }.first
    }

    private func parseAssetType(_ value: String) -> AssetType? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "stock", "stocks":
            return .stock
        case "etf", "etfs":
            return .etf
        case "crypto", "cryptocurrency":
            return .crypto
        default:
            return nil
        }
    }
}

enum CSVImportError: LocalizedError {
    case invalidHeader
    case invalidRow(Int)

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "CSV header must be: symbol,quantity,price,type,date,assetType"
        case .invalidRow(let row):
            return "Invalid CSV data on row \(row)."
        }
    }
}
