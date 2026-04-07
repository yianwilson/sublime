import Foundation

protocol CurrencyServiceProtocol {
    var cachedAUDPerUSD: Double { get }
    func fetchAUDPerUSD() async throws -> Double
}

final class CurrencyService: CurrencyServiceProtocol {
    private enum Constants {
        static let cachedRateKey = "audPerUSD"
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    var cachedAUDPerUSD: Double {
        let cached = UserDefaults.standard.double(forKey: Constants.cachedRateKey)
        return cached > 0 ? cached : 1.5
    }

    func fetchAUDPerUSD() async throws -> Double {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else {
            throw CurrencyServiceError.invalidURL
        }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(ExchangeRateResponse.self, from: data)
            guard let rate = response.rates["AUD"], rate > 0 else {
                throw CurrencyServiceError.invalidResponse
            }
            UserDefaults.standard.set(rate, forKey: Constants.cachedRateKey)
            return rate
        } catch {
            let cached = cachedAUDPerUSD
            if cached > 0 {
                return cached
            }
            throw error
        }
    }
}

enum CurrencyServiceError: LocalizedError {
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid exchange rate URL."
        case .invalidResponse:
            return "Could not read the AUD exchange rate."
        }
    }
}

private struct ExchangeRateResponse: Decodable {
    let rates: [String: Double]
}
