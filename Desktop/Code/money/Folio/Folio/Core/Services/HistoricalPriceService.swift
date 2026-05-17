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

    private let apiKey = "d84kdcpr01qutij97mc0d84kdcpr01qutij97mcg"
    private let finnhubBase = "https://finnhub.io/api/v1"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
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
                        history = await self.fetchFinnhubHistory(symbol: item.symbol, from: startDate)
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

    // MARK: - Finnhub

    private func finnhubSymbol(for symbol: String) -> String {
        if symbol.uppercased().hasSuffix(".AX") {
            return "ASX:\(String(symbol.dropLast(3)).uppercased())"
        }
        return symbol.uppercased()
    }

    private func fetchFinnhubHistory(symbol: String, from startDate: Date) async -> [Date: Double] {
        guard let bars = await fetchFinnhubCandles(symbol: symbol, from: startDate) else { return [:] }
        var history: [Date: Double] = [:]
        for bar in bars {
            history[bar.id] = bar.close
        }
        return history
    }

    func fetchOHLCHistory(symbol: String, from startDate: Date) async -> [OHLCBar] {
        return await fetchFinnhubCandles(symbol: symbol, from: startDate) ?? []
    }

    private func fetchFinnhubCandles(symbol: String, from startDate: Date) async -> [OHLCBar]? {
        let finnhub = finnhubSymbol(for: symbol)
        let encoded = finnhub.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? finnhub
        let from = Int(startDate.timeIntervalSince1970)
        let to   = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "\(finnhubBase)/stock/candle?symbol=\(encoded)&resolution=D&from=\(from)&to=\(to)&token=\(apiKey)") else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            let response  = try JSONDecoder().decode(FinnhubCandle.self, from: data)
            guard response.s == "ok",
                  let timestamps = response.t,
                  let opens      = response.o,
                  let highs      = response.h,
                  let lows       = response.l,
                  let closes     = response.c
            else { return nil }

            let count = min(timestamps.count, opens.count, highs.count, lows.count, closes.count)
            var bars: [OHLCBar] = []
            for i in 0..<count {
                let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(timestamps[i])))
                bars.append(OHLCBar(id: day, open: opens[i], high: highs[i], low: lows[i], close: closes[i]))
            }
            return bars.sorted { $0.id < $1.id }
        } catch {
            return nil
        }
    }

    // MARK: - CoinGecko

    private func fetchCoinGeckoHistory(geckoId: String, from startDate: Date) async -> [Date: Double] {
        let days = max(90, Int(Date().timeIntervalSince(startDate) / 86400) + 2)
        let encoded = geckoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? geckoId
        guard let url = URL(string: "https://api.coingecko.com/api/v3/coins/\(encoded)/market_chart?vs_currency=usd&days=\(days)") else { return [:] }

        do {
            let (data, _) = try await session.data(from: url)
            let response  = try JSONDecoder().decode(CGMarketChart.self, from: data)
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

// MARK: - Response models

private struct FinnhubCandle: Decodable {
    let s: String
    let t: [Int]?
    let o: [Double]?
    let h: [Double]?
    let l: [Double]?
    let c: [Double]?
}

private struct CGMarketChart: Decodable { let prices: [[Double]] }
