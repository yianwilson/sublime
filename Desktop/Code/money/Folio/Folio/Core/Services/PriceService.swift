import Foundation

final class PriceService: PriceServiceProtocol {

    private let apiKey = "d84kdcpr01qutij97mc0d84kdcpr01qutij97mcg"
    private let finnhubBase = "https://finnhub.io/api/v1"

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
        return URLSession(configuration: config)
    }()

    // MARK: - PriceServiceProtocol

    func fetchQuotes(for items: [PriceLookup]) async -> [String: AssetQuote] {
        let stocks  = items.filter { $0.assetType == .stock || $0.assetType == .etf }
        let cryptos = items.filter { $0.assetType == .crypto }

        async let stockQuotes  = fetchFinnhubQuotes(for: stocks)
        async let cryptoQuotes = fetchCryptoQuotes(for: cryptos)

        var result: [String: AssetQuote] = [:]
        let (sp, cp) = await (stockQuotes, cryptoQuotes)
        result.merge(sp) { _, new in new }
        result.merge(cp) { _, new in new }
        return result
    }

    func searchAssets(query: String) async -> [AssetSearchResult] {
        async let stocks  = searchFinnhub(query: query)
        async let cryptos = searchCoinGecko(query: query)
        let combined = await stocks + cryptos
        var seen = Set<String>()
        return combined.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Finnhub (stocks & ETFs)

    /// Converts stored symbol to Finnhub format.
    /// Yahoo-style "BHP.AX" → Finnhub "ASX:BHP"; US symbols pass through unchanged.
    private func finnhubSymbol(for symbol: String) -> (finnhub: String, currency: String) {
        if symbol.uppercased().hasSuffix(".AX") {
            let base = String(symbol.dropLast(3)).uppercased()
            return ("ASX:\(base)", "AUD")
        }
        return (symbol.uppercased(), "USD")
    }

    private func fetchFinnhubQuotes(for items: [PriceLookup]) async -> [String: AssetQuote] {
        guard !items.isEmpty else { return [:] }
        var result: [String: AssetQuote] = [:]
        await withTaskGroup(of: (String, AssetQuote?).self) { group in
            for item in items {
                group.addTask {
                    (item.symbol, await self.fetchFinnhubQuote(symbol: item.symbol))
                }
            }
            for await (symbol, quote) in group {
                if let quote { result[symbol] = quote }
            }
        }
        return result
    }

    private func fetchFinnhubQuote(symbol: String) async -> AssetQuote? {
        let (finnhub, currency) = finnhubSymbol(for: symbol)
        let encoded = finnhub.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? finnhub
        guard let url = URL(string: "\(finnhubBase)/quote?symbol=\(encoded)&token=\(apiKey)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let q = try JSONDecoder().decode(FinnhubQuote.self, from: data)
            guard q.c > 0 else { return nil }
            return AssetQuote(
                currentPrice:   q.c,
                previousClose:  q.pc > 0 ? q.pc : nil,
                currencyCode:   currency,
                sector:         nil,
                preMarketPrice: nil,
                postMarketPrice: nil
            )
        } catch {
            return nil
        }
    }

    private func searchFinnhub(query: String) async -> [AssetSearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(finnhubBase)/search?q=\(encoded)&token=\(apiKey)") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let response  = try JSONDecoder().decode(FinnhubSearchResponse.self, from: data)
            return response.result.prefix(8).compactMap { item in
                guard item.type == "Common Stock" || item.type == "ETP" else { return nil }
                let assetType: AssetType = item.type == "ETP" ? .etf : .stock
                let isASX = item.displaySymbol.contains(".")
                    && item.displaySymbol.uppercased().hasSuffix(".AX")
                let market: String? = isASX ? "ASX" : nil
                return AssetSearchResult(
                    symbol: item.displaySymbol,
                    name: item.description,
                    assetType: assetType,
                    coinGeckoId: "",
                    market: market,
                    marketRank: nil
                )
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
                result[symbol] = AssetQuote(
                    currentPrice:   price,
                    previousClose:  previousClose,
                    currencyCode:   "USD",
                    sector:         nil,
                    preMarketPrice: nil,
                    postMarketPrice: nil
                )
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
                .map {
                    AssetSearchResult(
                        symbol: $0.symbol.uppercased(),
                        name: $0.name,
                        assetType: .crypto,
                        coinGeckoId: $0.id,
                        market: nil,
                        marketRank: $0.marketCapRank
                    )
                }
        } catch { return [] }
    }
}

// MARK: - Response models

private struct FinnhubQuote: Decodable {
    let c: Double   // current price
    let pc: Double  // previous close
}

private struct FinnhubSearchResponse: Decodable {
    let result: [FinnhubSearchItem]
}

private struct FinnhubSearchItem: Decodable {
    let description: String
    let displaySymbol: String
    let type: String
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
