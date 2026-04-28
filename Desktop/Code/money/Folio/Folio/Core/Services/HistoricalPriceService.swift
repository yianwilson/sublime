import Foundation

// MARK: - OHLC Model

struct OHLCBar: Identifiable {
    let id: Date  // start of day
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    var isGain: Bool { close >= open }
}

/// Fetches daily close-price history per symbol.
/// Returns [symbol: [startOfDay → closePrice (USD)]]
final class HistoricalPriceService {

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    func fetchPriceHistory(
        for items: [PriceLookup],
        from startDate: Date
    ) async -> [String: [Date: Double]] {
        var result: [String: [Date: Double]] = [:]

        await withTaskGroup(of: (String, [Date: Double]).self) { group in
            for item in items {
                group.addTask {
                    let history: [Date: Double]
                    switch item.assetType {
                    case .stock, .etf:
                        history = await self.fetchYahooHistory(symbol: item.symbol, from: startDate)
                    case .crypto:
                        let id = item.coinGeckoId.isEmpty ? item.symbol.lowercased() : item.coinGeckoId
                        history = await self.fetchCoinGeckoHistory(geckoId: id, from: startDate)
                    }
                    return (item.symbol, history)
                }
            }
            for await (symbol, history) in group {
                if !history.isEmpty { result[symbol] = history }
            }
        }

        return result
    }

    // MARK: - Yahoo Finance

    private func fetchYahooHistory(symbol: String, from startDate: Date) async -> [Date: Double] {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        let period1 = Int(startDate.timeIntervalSince1970)
        let period2 = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?period1=\(period1)&period2=\(period2)&interval=1d") else { return [:] }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YHChartResponse.self, from: data)
            guard let result = response.chart.result?.first,
                  let timestamps = result.timestamp,
                  let closes = result.indicators.quote.first?.close
            else { return [:] }

            var history: [Date: Double] = [:]
            for (ts, close) in zip(timestamps, closes) {
                guard let close else { continue }
                let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
                history[day] = close
            }
            return history
        } catch {
            return [:]
        }
    }

    // MARK: - OHLC (Yahoo Finance)

    func fetchOHLCHistory(symbol: String, from startDate: Date) async -> [OHLCBar] {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        let period1 = Int(startDate.timeIntervalSince1970)
        let period2 = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?period1=\(period1)&period2=\(period2)&interval=1d") else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(YHOHLCChartResponse.self, from: data)
            guard let result = response.chart.result?.first,
                  let timestamps = result.timestamp,
                  let quote = result.indicators.quote.first,
                  let opens = quote.open,
                  let highs = quote.high,
                  let lows = quote.low,
                  let closes = quote.close
            else { return [] }

            var bars: [OHLCBar] = []
            let count = min(timestamps.count, opens.count, highs.count, lows.count, closes.count)
            for i in 0..<count {
                guard let o = opens[i], let h = highs[i], let l = lows[i], let c = closes[i] else { continue }
                let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(timestamps[i])))
                bars.append(OHLCBar(id: day, open: o, high: h, low: l, close: c))
            }
            return bars.sorted { $0.id < $1.id }
        } catch {
            return []
        }
    }

    // MARK: - CoinGecko

    private func fetchCoinGeckoHistory(geckoId: String, from startDate: Date) async -> [Date: Double] {
        let days = max(90, Int(Date().timeIntervalSince(startDate) / 86400) + 2)
        let encoded = geckoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? geckoId
        guard let url = URL(string: "https://api.coingecko.com/api/v3/coins/\(encoded)/market_chart?vs_currency=usd&days=\(days)") else { return [:] }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(CGMarketChart.self, from: data)
            var history: [Date: Double] = [:]
            for point in response.prices {
                guard point.count == 2 else { continue }
                let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: point[0] / 1000))
                if history[day] == nil { history[day] = point[1] }
            }
            return history
        } catch {
            return [:]
        }
    }
}

// MARK: - Private Response Models

private struct YHChartResponse: Decodable { let chart: YHChart }
private struct YHChart: Decodable { let result: [YHResult]? }
private struct YHResult: Decodable {
    let timestamp: [Int]?
    let indicators: YHIndicators
}
private struct YHIndicators: Decodable { let quote: [YHQuote] }
private struct YHQuote: Decodable { let close: [Double?] }
private struct CGMarketChart: Decodable { let prices: [[Double]] }

// MARK: - OHLC Response Models

private struct YHOHLCChartResponse: Decodable { let chart: YHOHLCChart }
private struct YHOHLCChart: Decodable { let result: [YHOHLCResult]? }
private struct YHOHLCResult: Decodable {
    let timestamp: [Int]?
    let indicators: YHOHLCIndicators
}
private struct YHOHLCIndicators: Decodable { let quote: [YHOHLCQuote] }
private struct YHOHLCQuote: Decodable {
    let open: [Double?]?
    let high: [Double?]?
    let low: [Double?]?
    let close: [Double?]?
}
