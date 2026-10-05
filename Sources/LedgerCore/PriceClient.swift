import Foundation

/// The provider does not publish a market timestamp. `fetchedAt` is the time
/// this application successfully received the quote, not the last trade time.
public struct PriceQuote: Codable, Equatable, Sendable {
    public var priceUSD: Decimal
    public var fetchedAt: Date
    public var source: String

    public init(priceUSD: Decimal, fetchedAt: Date = Date(), source: String = "Blockchain.com") {
        self.priceUSD = priceUSD
        self.fetchedAt = fetchedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case priceUSD, fetchedAt, source }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .priceUSD)
        guard text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let price = try? Amounts.decimal(text, maxPlaces: 38),
              price > 0, price <= Decimal(1_000_000_000_000) else {
            throw DecodingError.dataCorruptedError(forKey: .priceUSD, in: container, debugDescription: "Invalid BTC/USD price")
        }
        priceUSD = price
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        source = try container.decode(String.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(NSDecimalNumber(decimal: priceUSD).stringValue, forKey: .priceUSD)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(source, forKey: .source)
    }
}

public enum PriceError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case invalidPrice

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "行情服务返回了无法识别的数据，已保留上次成功价格。"
        case .httpStatus(let status): return "行情服务暂不可用（HTTP \(status)），已保留上次成功价格。"
        case .invalidPrice: return "行情价格无效，已保留上次成功价格。"
        }
    }
}

/// Public, read-only market data. No ledger values or account identifiers are sent.
public struct PriceClient: Sendable {
    private let session: URLSession
    public static let endpoint = URL(string: "https://blockchain.info/ticker")!

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 20
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fetch() async throws -> PriceQuote {
        try Task.checkCancellation()
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw PriceError.invalidResponse }
        guard (200...299).contains(response.statusCode) else {
            if let retryAt = HTTPRetryError.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date()) {
                throw HTTPRetryError(statusCode: response.statusCode, retryAfter: retryAt)
            }
            throw PriceError.httpStatus(response.statusCode)
        }
        return try Self.decode(data: data, fetchedAt: Date())
    }

    public static func fetch() async throws -> PriceQuote {
        try await PriceClient().fetch()
    }

    public static func decode(data: Data, fetchedAt: Date = Date()) throws -> PriceQuote {
        // Decode JSON numbers directly to Foundation Decimal, never through Double.
        struct Ticker: Decodable {
            struct Currency: Decodable { let last: Decimal }
            let USD: Currency
        }
        guard data.count <= 1_000_000 else { throw PriceError.invalidResponse }
        let ticker: Ticker
        do { ticker = try JSONDecoder().decode(Ticker.self, from: data) }
        catch { throw PriceError.invalidResponse }
        guard ticker.USD.last > 0, ticker.USD.last <= Decimal(1_000_000_000_000),
              fetchedAt.timeIntervalSinceReferenceDate.isFinite else { throw PriceError.invalidPrice }
        return PriceQuote(priceUSD: ticker.USD.last, fetchedAt: fetchedAt)
    }
}
