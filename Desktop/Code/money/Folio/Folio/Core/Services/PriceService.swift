import Foundation

final class PriceService: PriceServiceProtocol {

    private let cryptoIdMap: [String: String] = [
        "BTC":   "bitcoin",
        "ETH":   "ethereum",
        "SOL":   "solana",
        "ADA":   "cardano",
        "DOT":   "polkadot",
        "AVAX":  "avalanche-2",
        "MATIC": "matic-network",
        "LINK":  "chainlink",
        "XRP":   "ripple",
        "DOGE":  "dogecoin",
        "BNB":   "binancecoin",
        "SHIB":  "shiba-inu",
        "LTC":   "litecoin",
        "UNI":   "uniswap",
        "ATOM":  "cosmos",
        "FTM":   "fantom",
        "NEAR":  "near",
        "ARB":   "arbitrum",
        "OP":    "optimism",
        "SUI":   "sui"
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    // MARK: - PriceServiceProtocol

    func fetchQuotes(for items: [PriceLookup]) async -> [String: AssetQuote] {
        let stocks  = items.filter { $0.assetType == .stock || $0.assetType == .etf }
        let cryptos = items.filter { $0.assetType == .crypto }

        async let stockQuotes  = fetchYahooQuotes(for: stocks)
        async let cryptoQuotes = fetchCryptoQuotes(for: cryptos)

        var result: [String: AssetQuote] = [:]
        let (sp, cp) = await (stockQuotes, cryptoQuotes)
        result.merge(sp) { _, new in new }
        result.merge(cp) { _, new in new }
        return result
    }

    func searchAssets(query: String) async -> [AssetSearchResult] {
        async let stocks  = searchYahoo(query: query)
        async let cryptos = searchCoinGecko(query: query)
        let combined = await stocks + cryptos
        var seen = Set<String>()
        return combined.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Yahoo Finance (stocks & ETFs)

    private func fetchYahooQuotes(for items: [PriceLookup]) async -> [String: AssetQuote] {
        guard !items.isEmpty else { return [:] }
        var quotes: [String: AssetQuote] = [:]
        var sectors: [String: String] = [:]

        await withTaskGroup(of: (String, AssetQuote?, String?).self) { group in
            for item in items {
                group.addTask {
                    async let quote  = self.fetchYahooQuote(symbol: item.symbol)
                    async let sector = self.fetchSector(symbol: item.symbol)
                    return (item.symbol, await quote, await sector)
                }
            }
            for await (symbol, quote, sector) in group {
                if let quote { quotes[symbol] = quote }
                if let sector { sectors[symbol] = sector }
            }
        }

        // Merge sector data into quotes
        var result: [String: AssetQuote] = [:]
        for (symbol, quote) in quotes {
            result[symbol] = AssetQuote(
                currentPrice:  quote.currentPrice,
                previousClose: quote.previousClose,
                currencyCode:  quote.currencyCode,
                sector:        sectors[symbol],
                preMarketPrice: quote.preMarketPrice,
                postMarketPrice: quote.postMarketPrice
            )
        }
        return result
    }

    private func fetchYahooQuote(symbol: String) async -> AssetQuote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=1d") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let response  = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let meta = response.chart.result?.first?.meta,
                  let currentPrice = meta.regularMarketPrice else { return nil }
            return AssetQuote(
                currentPrice:  currentPrice,
                previousClose: meta.previousClose ?? meta.chartPreviousClose,
                currencyCode:  meta.currency ?? "USD",
                sector:        nil,
                preMarketPrice: meta.preMarketPrice,
                postMarketPrice: meta.postMarketPrice
            )
        } catch {
            return nil
        }
    }

    private func fetchSector(symbol: String) async -> String? {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(symbol)?modules=assetProfile") else { return nil }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = (json["quoteSummary"] as? [String: Any])?["result"] as? [[String: Any]],
              let profile = result.first?["assetProfile"] as? [String: Any],
              let sector = profile["sector"] as? String,
              !sector.isEmpty else { return nil }
        return sector
    }

    private func searchYahoo(query: String) async -> [AssetSearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(encoded)&quotesCount=8&lang=en-US") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let response  = try JSONDecoder().decode(YahooSearchResponse.self, from: data)
            return response.quotes.compactMap { quote in
                guard let symbol    = quote.symbol,
                      let name      = quote.shortname ?? quote.longname,
                      let quoteType = quote.quoteType,
                      quoteType == "EQUITY" || quoteType == "ETF"
                else { return nil }
                let type: AssetType = quoteType == "ETF" ? .etf : .stock
                return AssetSearchResult(symbol: symbol, name: name, assetType: type, coinGeckoId: "", market: quote.exchDisp, marketRank: nil)
            }
        } catch { return [] }
    }

    // MARK: - CoinGecko (crypto)

    private func fetchCryptoQuotes(for items: [PriceLookup]) async -> [String: AssetQuote] {
        guard !items.isEmpty else { return [:] }

        var geckoIdToSymbol: [String: String] = [:]
        for item in items {
            let geckoId = item.coinGeckoId.isEmpty
                ? (cryptoIdMap[item.symbol.uppercased()] ?? item.symbol.lowercased())
                : item.coinGeckoId
            geckoIdToSymbol[geckoId] = item.symbol
        }

        let ids = geckoIdToSymbol.keys.joined(separator: ",")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd&include_24hr_change=true") else { return [:] }

        do {
            let (data, _) = try await session.data(from: url)
            let decoded   = try JSONDecoder().decode([String: CoinGeckoPrice].self, from: data)
            var result: [String: AssetQuote] = [:]
            for (geckoId, priceMap) in decoded {
                guard let symbol = geckoIdToSymbol[geckoId], let price = priceMap.usd else { continue }
                let previousClose: Double? = priceMap.usd24hChange.map { price / (1 + $0 / 100) }
                result[symbol] = AssetQuote(currentPrice: price, previousClose: previousClose, currencyCode: "USD", sector: nil, preMarketPrice: nil, postMarketPrice: nil)
            }
            return result
        } catch { return [:] }
    }

    private func searchCoinGecko(query: String) async -> [AssetSearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.coingecko.com/api/v3/search?query=\(encoded)") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let response  = try JSONDecoder().decode(CoinGeckoSearchResponse.self, from: data)
            return response.coins
                .sorted { ($0.marketCapRank ?? .max) < ($1.marketCapRank ?? .max) }
                .prefix(5)
                .map { AssetSearchResult(symbol: $0.symbol.uppercased(), name: $0.name, assetType: .crypto, coinGeckoId: $0.id, market: nil, marketRank: $0.marketCapRank) }
        } catch { return [] }
    }
}

// MARK: - Response Models

private struct YahooChartResponse: Decodable { let chart: YahooChart }
private struct YahooChart: Decodable { let result: [YahooChartResult]? }
private struct YahooChartResult: Decodable { let meta: YahooMeta }
private struct YahooMeta: Decodable {
    let regularMarketPrice: Double?
    let previousClose: Double?
    let chartPreviousClose: Double?
    let currency: String?
    let preMarketPrice: Double?
    let postMarketPrice: Double?
}
private struct YahooSearchResponse: Decodable { let quotes: [YahooQuote] }
private struct YahooQuote: Decodable {
    let symbol: String?; let shortname: String?; let longname: String?
    let quoteType: String?; let exchDisp: String?
}
private struct CoinGeckoSearchResponse: Decodable { let coins: [CoinGeckoCoin] }
private struct CoinGeckoCoin: Decodable {
    let id: String; let symbol: String; let name: String; let marketCapRank: Int?
    private enum CodingKeys: String, CodingKey { case id, symbol, name; case marketCapRank = "market_cap_rank" }
}
private struct CoinGeckoPrice: Decodable {
    let usd: Double?; let usd24hChange: Double?
    private enum CodingKeys: String, CodingKey { case usd; case usd24hChange = "usd_24h_change" }
}
