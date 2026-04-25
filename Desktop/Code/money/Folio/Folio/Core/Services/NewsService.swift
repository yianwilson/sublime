import Foundation

final class NewsService {

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    func fetchMarketNews() async -> [NewsItem] {
        // Fetch general market news using SPY as a proxy for broad market headlines
        return await fetchNews(for: "SPY")
    }

    func fetchNews(for symbol: String) async -> [NewsItem] {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(encoded)&newsCount=8&quotesCount=0&lang=en-US") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONDecoder().decode(YahooNewsResponse.self, from: data)
            return json.news?.compactMap { item in
                guard let title = item.title, let uuid = item.uuid else { return nil }
                let date = item.providerPublishTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
                let articleURL = item.link.flatMap { URL(string: $0) }
                return NewsItem(
                    id: uuid,
                    title: title,
                    publisher: item.publisher ?? "",
                    publishedAt: date,
                    url: articleURL,
                    summary: item.summary
                )
            } ?? []
        } catch {
            return []
        }
    }
}

// MARK: - Response Models

private struct YahooNewsResponse: Decodable {
    let news: [YahooNewsItem]?
}

private struct YahooNewsItem: Decodable {
    let uuid: String?
    let title: String?
    let publisher: String?
    let providerPublishTime: Int?
    let link: String?
    let summary: String?
}
