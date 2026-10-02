import Foundation

/// Daily reference closes for the period without a complete BTC/CNY OHLC feed.
/// Coin Metrics labels PriceUSD with the start of its UTC day, but the value
/// represents that day's close. It becomes usable only at the following midnight.
/// ECB rates are historical reference rates; non-publication days use the most
/// recent published rate. These observations must be drawn as a line, never K bars.
public struct EarlyMarketHistoryClient: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 30
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public static func priceEndpoint(cutoff: Date) -> URL {
        URL(string: "https://community-api.coinmetrics.io/v4/timeseries/asset-metrics?assets=btc&metrics=PriceUSD&frequency=1d&start_time=2009-01-03&end_time=\(dayText(cutoff))&page_size=10000")!
    }

    public static func exchangeEndpoint(cutoff: Date) -> URL {
        URL(string: "https://api.frankfurter.dev/v2/providers/ecb/rates?from=2010-07-01&to=\(dayText(cutoff))&base=USD&quotes=CNY")!
    }

    public func fetch(cutoff: Date) async throws -> [MarketCandle] {
        async let prices = read(Self.priceEndpoint(cutoff: cutoff))
        async let rates = read(Self.exchangeEndpoint(cutoff: cutoff))
        return try await Self.decode(priceData: prices, exchangeData: rates, cutoff: cutoff)
    }

    private func read(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BitcoinLedger/3.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MarketHistoryError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw MarketHistoryError.httpStatus(response.statusCode) }
        guard data.count <= 4_000_000 else { throw MarketHistoryError.invalidResponse }
        return data
    }

    public static func decode(priceData: Data, exchangeData: Data, cutoff: Date) throws -> [MarketCandle] {
        guard priceData.count <= 4_000_000, exchangeData.count <= 4_000_000,
              cutoff.timeIntervalSinceReferenceDate.isFinite else { throw MarketHistoryError.invalidResponse }
        let prices: PriceResponse
        let exchange: [ExchangeRow]
        do {
            prices = try JSONDecoder().decode(PriceResponse.self, from: priceData)
            exchange = try JSONDecoder().decode([ExchangeRow].self, from: exchangeData)
        } catch { throw MarketHistoryError.invalidResponse }
        guard prices.next_page_url == nil, prices.data.count <= 10_000, exchange.count <= 10_000 else {
            throw MarketHistoryError.invalidResponse
        }
        var rates: [(Date, Decimal)] = []
        var seenRates = Set<Date>()
        for row in exchange {
            guard row.base == "USD", row.quote == "CNY", row.rate > 0, row.rate < 1000,
                  let date = dayDate(row.date), seenRates.insert(date).inserted else {
                throw MarketHistoryError.invalidResponse
            }
            rates.append((date, row.rate))
        }
        rates.sort { $0.0 < $1.0 }
        var observations: [(Date, Decimal)] = []
        var seenPrices = Set<Date>()
        for row in prices.data {
            guard row.asset == "btc", row.time.hasSuffix("Z"), row.time.count >= 20,
                  String(row.time.dropFirst(10).prefix(9)) == "T00:00:00",
                  let date = dayDate(String(row.time.prefix(10))), seenPrices.insert(date).inserted else {
                throw MarketHistoryError.invalidResponse
            }
            guard let text = row.PriceUSD else { continue }
            guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                  value > 0, value <= Decimal(1_000_000_000_000 as Int64) else {
                throw MarketHistoryError.invalidResponse
            }
            observations.append((date, value))
        }
        observations.sort { $0.0 < $1.0 }
        var result: [MarketCandle] = []
        var rateIndex = 0
        var latestRate: (Date, Decimal)?
        for (date, usd) in observations {
            let closeDate = date.addingTimeInterval(86_400)
            guard closeDate <= cutoff else { continue }
            while rateIndex < rates.count, rates[rateIndex].0 <= date {
                latestRate = rates[rateIndex]
                rateIndex += 1
            }
            // A missing source or abnormally stale FX observation stays a gap.
            guard let latestRate, date.timeIntervalSince(latestRate.0) <= 7 * 86_400 else { continue }
            let cny = usd * latestRate.1
            let candle = MarketCandle(closeDate: closeDate, interval: 86_400,
                                      open: cny, high: cny, low: cny, close: cny, hasOHLC: false)
            guard MarketHistoryClient.valid(candle) else { throw MarketHistoryError.invalidResponse }
            result.append(candle)
        }
        guard !result.isEmpty else { throw MarketHistoryError.emptyHistory }
        return result
    }

    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func dayDate(_ text: String) -> Date? {
        guard text.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}

private struct PriceResponse: Decodable {
    let data: [PriceRow]
    let next_page_url: String?
}
private struct PriceRow: Decodable {
    let asset: String
    let time: String
    let PriceUSD: String?
}
private struct ExchangeRow: Decodable {
    let date: String
    let base: String
    let quote: String
    let rate: Decimal
}
