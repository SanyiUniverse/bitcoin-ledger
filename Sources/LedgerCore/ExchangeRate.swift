import Foundation

public enum ExchangeRateError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "历史汇率数据无效，尚未保存购买。"
        case .httpStatus(let status): "历史汇率服务暂不可用（HTTP \(status)），请稍后重试。"
        case .unavailable: "购买时间前没有可用且未超过 7 天的已公布 USD/CNY 参考汇率。"
        }
    }
}

/// Only the public reference date and fixed currency pair are sent. The rate
/// becomes available the following UTC day because publication times are absent.
public struct ExchangeRateClient: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 20
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }
    public func rate(asOf date: Date) async throws -> USDExchangeRate {
        guard date.timeIntervalSince1970.isFinite else { throw ExchangeRateError.invalidResponse }
        try Task.checkCancellation()
        var request = URLRequest(url: USDReferenceRates.endpoint(
            from: UTCDateText.string(date.addingTimeInterval(-8 * 86_400)), through: date))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ExchangeRateError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw ExchangeRateError.httpStatus(http.statusCode) }
        return try Self.decode(data: data, asOf: date)
    }
    public static func rate(asOf date: Date) async throws -> USDExchangeRate {
        try await ExchangeRateClient().rate(asOf: date)
    }
    public static func decode(data: Data, asOf date: Date) throws -> USDExchangeRate {
        guard date.timeIntervalSince1970.isFinite else { throw ExchangeRateError.invalidResponse }
        let rates: [USDReferenceRate]
        do { rates = try USDReferenceRates.decode(data) }
        catch { throw ExchangeRateError.invalidResponse }
        guard let rate = rates.last(where: { $0.day.addingTimeInterval(86_400) <= date
            && date.timeIntervalSince($0.day) <= 7 * 86_400 }) else { throw ExchangeRateError.unavailable }
        let value = Amounts.rounded(rate.value)
        guard value > 0, value < 1000 else { throw ExchangeRateError.invalidResponse }
        return USDExchangeRate(date: rate.day, cnyPerUSD: value,
            source: "ECB 经 Frankfurter · USD/CNY 每日参考汇率")
    }
}

struct USDReferenceRate: Sendable {
    let day: Date
    let value: Decimal
}

/// Validated purchase conversion rates and strict UTC date parsing.
enum USDReferenceRates {
    static func endpoint(from: String, through: Date) -> URL {
        var components = URLComponents(string: "https://api.frankfurter.dev/v2/providers/ecb/rates")!
        components.queryItems = [URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: UTCDateText.string(through)), URLQueryItem(name: "base", value: "USD"),
            URLQueryItem(name: "quotes", value: "CNY")]
        return components.url!
    }

    static func decode(_ data: Data) throws -> [USDReferenceRate] {
        guard data.count <= 4_000_000 else { throw ExchangeRateError.invalidResponse }
        let rows: [ExchangeRow]
        do { rows = try JSONDecoder().decode([ExchangeRow].self, from: data) }
        catch { throw ExchangeRateError.invalidResponse }
        guard rows.count <= 10_000 else { throw ExchangeRateError.invalidResponse }
        var seen = Set<Date>()
        return try rows.map { row in
            guard row.base == "USD", row.quote == "CNY", row.rate > 0, row.rate < 1000,
                  let day = UTCDateText.date(row.date), seen.insert(day).inserted else {
                throw ExchangeRateError.invalidResponse
            }
            return USDReferenceRate(day: day, value: row.rate)
        }.sorted { $0.day < $1.day }
    }
}

enum UTCDateText {
    static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(_ text: String) -> Date? {
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

private struct ExchangeRow: Decodable {
    let date: String
    let base: String
    let quote: String
    let rate: Decimal
}
