import Foundation

final class PersistenceService {
    private let portfolioFileURL: URL
    private let snapshotsFileURL: URL
    private let watchlistFileURL: URL

    init(directoryURL: URL? = nil) {
        let baseURL = directoryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.portfolioFileURL = baseURL.appendingPathComponent("portfolio.json")
        self.snapshotsFileURL = baseURL.appendingPathComponent("performance-snapshots.json")
        self.watchlistFileURL = baseURL.appendingPathComponent("watchlist.json")
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
}
