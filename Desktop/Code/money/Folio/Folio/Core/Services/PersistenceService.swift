import Foundation

final class PersistenceService {
    private let portfolioFileURL: URL
    private let portfoliosFileURL: URL
    private let snapshotsFileURL: URL
    private let watchlistFileURL: URL
    private let alertsFileURL: URL

    init(directoryURL: URL? = nil) {
        let baseURL = directoryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.portfolioFileURL = baseURL.appendingPathComponent("portfolio.json")
        self.portfoliosFileURL = baseURL.appendingPathComponent("portfolios.json")
        self.snapshotsFileURL = baseURL.appendingPathComponent("performance-snapshots.json")
        self.watchlistFileURL = baseURL.appendingPathComponent("watchlist.json")
        self.alertsFileURL = baseURL.appendingPathComponent("alerts.json")
    }

    func loadTransactions() -> [Transaction] {
        guard
            let data = try? Data(contentsOf: portfolioFileURL),
            let portfolio = try? JSONDecoder().decode(Portfolio.self, from: data)
        else { return [] }
        return portfolio.transactions
    }

    func saveTransactions(_ transactions: [Transaction]) {
        guard let data = try? JSONEncoder().encode(Portfolio(transactions: transactions)) else { return }
        try? data.write(to: portfolioFileURL, options: .atomic)
    }

    // MARK: - Multi-portfolio

    func loadNamedPortfolios() -> [NamedPortfolio] {
        if let data = try? Data(contentsOf: portfoliosFileURL),
           let portfolios = try? JSONDecoder().decode([NamedPortfolio].self, from: data),
           !portfolios.isEmpty {
            return portfolios
        }
        // First launch or migration: wrap existing transactions into a default portfolio
        let txs = loadTransactions()
        var p = NamedPortfolio(name: "My Portfolio")
        p.transactions = txs
        return [p]
    }

    func saveNamedPortfolios(_ portfolios: [NamedPortfolio]) {
        guard let data = try? JSONEncoder().encode(portfolios) else { return }
        try? data.write(to: portfoliosFileURL, options: .atomic)
    }

    func loadTransactions(for portfolioId: UUID, from portfolios: [NamedPortfolio]) -> [Transaction] {
        portfolios.first { $0.id == portfolioId }?.transactions ?? []
    }

    func saveTransactions(_ transactions: [Transaction], for portfolioId: UUID, in portfolios: inout [NamedPortfolio]) {
        guard let idx = portfolios.firstIndex(where: { $0.id == portfolioId }) else { return }
        portfolios[idx].transactions = transactions
        saveNamedPortfolios(portfolios)
    }

    func loadSnapshots() -> [PerformanceSnapshot] {
        guard
            let data = try? Data(contentsOf: snapshotsFileURL),
            let snapshots = try? JSONDecoder().decode([PerformanceSnapshot].self, from: data)
        else { return [] }
        return snapshots.sorted { $0.date < $1.date }
    }

    func saveSnapshots(_ snapshots: [PerformanceSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: snapshotsFileURL, options: .atomic)
    }

    func upsertDailySnapshot(totalValue: Double, on date: Date = Date()) -> [PerformanceSnapshot] {
        let day = Calendar.current.startOfDay(for: date)
        var snapshots = loadSnapshots()

        if let index = snapshots.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            snapshots[index] = PerformanceSnapshot(date: day, totalValue: totalValue)
        } else {
            snapshots.append(PerformanceSnapshot(date: day, totalValue: totalValue))
        }

        snapshots.sort { $0.date < $1.date }
        saveSnapshots(snapshots)
        return snapshots
    }

    func loadWatchlist() -> [WatchlistItem] {
        guard
            let data = try? Data(contentsOf: watchlistFileURL),
            let items = try? JSONDecoder().decode([WatchlistItem].self, from: data)
        else { return [] }
        return items.sorted { $0.symbol < $1.symbol }
    }

    func saveWatchlist(_ items: [WatchlistItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: watchlistFileURL, options: .atomic)
    }

    func loadAlerts() -> [PriceAlert] {
        guard let data = try? Data(contentsOf: alertsFileURL),
              let alerts = try? JSONDecoder().decode([PriceAlert].self, from: data)
        else { return [] }
        return alerts
    }

    func saveAlerts(_ alerts: [PriceAlert]) {
        guard let data = try? JSONEncoder().encode(alerts) else { return }
        try? data.write(to: alertsFileURL, options: .atomic)
    }
}
