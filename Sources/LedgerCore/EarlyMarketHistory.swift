import Foundation

/// Coin Metrics labels PriceUSD with the beginning of the UTC day whose close
/// it represents. These genuine closes become usable at the next midnight;
/// without OHLC they remain reference points, never invented K bars.
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
        URL(string: "https://community-api.coinmetrics.io/v4/timeseries/asset-metrics?assets=btc&metrics=PriceUSD&frequency=1d&start_time=2009-01-03&end_time=\(UTCDateText.string(cutoff))&page_size=10000")!
    }
    public func fetch(cutoff: Date) async throws -> [MarketCandle] {
        var request = URLRequest(url: Self.priceEndpoint(cutoff: cutoff))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BitcoinLedger/3.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MarketHistoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw MarketHistoryError.httpStatus(http.statusCode) }
        return try Self.decode(priceData: data, cutoff: cutoff)
    }
    public static func decode(priceData: Data, cutoff: Date) throws -> [MarketCandle] {
        guard priceData.count <= 4_000_000, cutoff.timeIntervalSinceReferenceDate.isFinite else {
            throw MarketHistoryError.invalidResponse
        }
        let response: PriceResponse
        do { response = try JSONDecoder().decode(PriceResponse.self, from: priceData) }
        catch { throw MarketHistoryError.invalidResponse }
        guard response.next_page_url == nil, response.data.count <= 10_000 else { throw MarketHistoryError.invalidResponse }
        var seen = Set<Date>()
        var candles: [MarketCandle] = []
        for row in response.data {
            guard row.asset == "btc", row.time.hasSuffix("Z"), row.time.count >= 20,
                  String(row.time.dropFirst(10).prefix(9)) == "T00:00:00",
                  let start = UTCDateText.date(String(row.time.prefix(10))), seen.insert(start).inserted else {
                throw MarketHistoryError.invalidResponse
            }
            guard let text = row.PriceUSD else { continue }
            guard let usd = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                  usd > 0, usd <= Amounts.maximumPrice else { throw MarketHistoryError.invalidResponse }
            let close = start.addingTimeInterval(86_400)
            guard close <= cutoff else { continue }
            candles.append(MarketCandle(closeDate: close, interval: 86_400,
                open: usd, high: usd, low: usd, close: usd, hasOHLC: false))
        }
        guard !candles.isEmpty else { throw MarketHistoryError.emptyHistory }
        return candles.sorted { $0.startDate < $1.startDate }
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
