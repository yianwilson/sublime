import Foundation

final class NewsService {

    private let apiKey = "d84kdcpr01qutij97mc0d84kdcpr01qutij97mcg"
    private let finnhubBase = "https://finnhub.io/api/v1"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    func fetchMarketNews() async -> [NewsItem] {
        guard let url = URL(string: "\(finnhubBase)/news?category=general&token=\(apiKey)") else { return [] }
        return await fetchAndParse(url: url)
    }

    func fetchNews(for symbol: String) async -> [NewsItem] {
        let finnhub = symbol.uppercased().hasSuffix(".AX")
            ? "ASX:\(String(symbol.dropLast(3)).uppercased())"
            : symbol.uppercased()
        let encoded = finnhub.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? finnhub
        let to   = ISO8601DateFormatter().string(from: Date())
        let from = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date())
        let fromDate = String(from.prefix(10))
        let toDate   = String(to.prefix(10))
        guard let url = URL(string: "\(finnhubBase)/company-news?symbol=\(encoded)&from=\(fromDate)&to=\(toDate)&token=\(apiKey)") else { return [] }
        return await fetchAndParse(url: url)
    }

    private func fetchAndParse(url: URL) async -> [NewsItem] {
        do {
            let (data, _) = try await session.data(from: url)
            let items = try JSONDecoder().decode([FinnhubNewsItem].self, from: data)
            return items.prefix(8).compactMap { item in
                guard !item.headline.isEmpty else { return nil }
                return NewsItem(
                    id: String(item.id),
                    title: item.headline,
                    publisher: item.source,
                    publishedAt: Date(timeIntervalSince1970: TimeInterval(item.datetime)),
                    url: URL(string: item.url),
                    summary: item.summary.isEmpty ? nil : item.summary
                )
            }
        } catch {
            return []
        }
    }
}

// MARK: - Response Models

private struct FinnhubNewsItem: Decodable {
    let id: Int
    let headline: String
    let source: String
    let datetime: Int
    let url: String
    let summary: String
}
