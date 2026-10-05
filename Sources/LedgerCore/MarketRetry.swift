import Foundation

/// A public market service may ask the caller to wait longer than local backoff.
public struct HTTPRetryError: LocalizedError, Equatable, Sendable {
    public let statusCode: Int
    public let retryAfter: Date?
    public init(statusCode: Int, retryAfter: Date?) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }
    public var errorDescription: String? { MarketHistoryError.httpStatus(statusCode).localizedDescription }

    public static func retryAfter(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(text), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text), date.timeIntervalSince1970.isFinite else { return nil }
        return max(now, date)
    }
}

public enum MarketRetryPolicy {
    /// Only temporary service/transport failures retry. Bad ranges, absent
    /// history, invalid payloads and user cancellation need no request loop.
    public static func deadline(for error: Error, failureCount: Int, now: Date) -> Date? {
        guard !(error is CancellationError) else { return nil }
        var status: Int?
        var serverDeadline: Date?
        if let http = error as? HTTPRetryError {
            status = http.statusCode; serverDeadline = http.retryAfter
        } else if case .httpStatus(let code) = error as? MarketHistoryError {
            status = code
        } else if case .httpStatus(let code) = error as? PriceError {
            status = code
        } else if let url = error as? URLError {
            switch url.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable, .cannotLoadFromNetwork:
                break
            default: return nil
            }
        } else { return nil }
        if let status, status != 408 && status != 429 && !(500...599).contains(status) { return nil }
        let firstDelay: TimeInterval = status == 429 ? 120 : 60
        let exponent = min(5, max(1, failureCount)) - 1
        let local = now.addingTimeInterval(min(900, firstDelay * pow(2, Double(exponent))))
        return max(local, serverDeadline ?? .distantPast)
    }
}
