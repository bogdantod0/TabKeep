import Foundation

final class FrankfurterFXService: FXService {
    private let session: URLSession
    private let cache: FXRateCache

    init(session: URLSession = .shared, cache: FXRateCache = FXRateCache(fileURL: FXRateCache.defaultURL())) {
        self.session = session
        self.cache = cache
    }

    func rate(from: String, to: String, on date: Date) async throws -> Decimal {
        let fromCode = from.uppercased()
        let toCode = to.uppercased()
        if fromCode == toCode { return 1 }
        guard SupportedCurrencies.isSupported(fromCode) else { throw FXServiceError.unsupportedCurrency(fromCode) }
        guard SupportedCurrencies.isSupported(toCode) else { throw FXServiceError.unsupportedCurrency(toCode) }

        if let cached = cache.rate(from: fromCode, to: toCode, on: date) {
            return cached
        }

        let datePath = Self.datePathFormatter.string(from: Self.endpointDate(for: date))
        var components = URLComponents(string: "https://api.frankfurter.app/\(datePath)")!
        components.queryItems = [
            URLQueryItem(name: "from", value: fromCode),
            URLQueryItem(name: "to", value: toCode),
        ]
        guard let url = components.url else { throw FXServiceError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw FXServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw FXServiceError.httpError(http.statusCode) }

        let decoder = JSONDecoder()
        let payload = try decoder.decode(FrankfurterResponse.self, from: data)
        guard let rate = payload.rates[toCode] else { throw FXServiceError.missingRate }

        let decimalRate = Decimal(rate)
        cache.store(rate: decimalRate, from: fromCode, to: toCode, on: date)
        return decimalRate
    }

    private static func endpointDate(for date: Date) -> Date {
        let now = Date()
        return date > now ? now : date
    }

    private static let datePathFormatter: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private struct FrankfurterResponse: Decodable {
        let amount: Double
        let base: String
        let date: String
        let rates: [String: Double]
    }
}
