import Foundation

protocol EventsServiceProtocol {
    func fetchEvents(ownedSymbols: [String]) async -> [UpcomingEvent]
}

final class EventsService: EventsServiceProtocol {

    // Key market-moving stocks always monitored (regardless of ownership)
    static let keyMovers = ["NVDA", "AAPL", "MSFT", "AMZN", "GOOGL", "META", "TSLA", "JPM"]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    func fetchEvents(ownedSymbols: [String]) async -> [UpcomingEvent] {
        let ownedSet = Set(ownedSymbols.map { $0.uppercased() })
        // Combine owned + key movers, deduplicated
        let allSymbols = Array(ownedSet.union(Set(Self.keyMovers)))

        var events: [UpcomingEvent] = []

        await withTaskGroup(of: UpcomingEvent?.self) { group in
            for symbol in allSymbols {
                group.addTask {
                    await self.fetchEarningsDate(symbol: symbol, isOwned: ownedSet.contains(symbol))
                }
            }
            for await event in group {
                if let event { events.append(event) }
            }
        }

        events.append(contentsOf: fomcEvents())

        let today = Calendar.current.startOfDay(for: Date())
        guard let cutoff = Calendar.current.date(byAdding: .day, value: 60, to: today) else { return [] }

        return events
            .filter { $0.date >= today && $0.date <= cutoff }
            .sorted { $0.date < $1.date }
    }

    private func fetchEarningsDate(symbol: String, isOwned: Bool) async -> UpcomingEvent? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(encoded)?modules=calendarEvents") else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YahooCalendarResponse.self, from: data)
            guard let rawDates = response.quoteSummary?.result?.first?.calendarEvents?.earnings?.earningsDate else { return nil }

            let now = Date()
            let upcomingDates = rawDates.map { Date(timeIntervalSince1970: $0.raw) }.filter { $0 > now }
            guard let next = upcomingDates.min() else { return nil }

            return UpcomingEvent(
                id: "earnings-\(symbol)",
                date: Calendar.current.startOfDay(for: next),
                symbol: symbol,
                name: "\(symbol) Earnings",
                kind: .earnings(isOwned: isOwned)
            )
        } catch {
            return nil
        }
    }

    private func fomcEvents() -> [UpcomingEvent] {
        // 2025–2026 FOMC meeting dates (final day = rate decision announcement)
        let dates = [
            "2025-05-07", "2025-06-18", "2025-07-30", "2025-09-17",
            "2025-10-29", "2025-12-10",
            "2026-01-28", "2026-03-18", "2026-05-06", "2026-06-17",
            "2026-07-29", "2026-09-16"
        ]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")

        return dates.compactMap { s in
            guard let date = fmt.date(from: s) else { return nil }
            return UpcomingEvent(
                id: "fomc-\(s)",
                date: Calendar.current.startOfDay(for: date),
                symbol: nil,
                name: "Fed Rate Decision",
                kind: .fedDecision
            )
        }
    }
}

// MARK: - Decodable helpers

private struct YahooCalendarResponse: Decodable {
    let quoteSummary: YQSummary?
}
private struct YQSummary: Decodable {
    let result: [YQResult]?
}
private struct YQResult: Decodable {
    let calendarEvents: YQCalendarEvents?
}
private struct YQCalendarEvents: Decodable {
    let earnings: YQEarnings?
}
private struct YQEarnings: Decodable {
    let earningsDate: [YQRawDate]?
}
private struct YQRawDate: Decodable {
    let raw: Double
}
