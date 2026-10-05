import Foundation
import Testing
@testable import LedgerCore

@Test func marketRetryBackoffAndTerminalFailures() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let delays: [TimeInterval] = [60, 120, 240, 480, 900, 900]
    for (index, delay) in delays.enumerated() {
        for error in [URLError(.notConnectedToInternet), URLError(.timedOut)] {
            #expect(MarketRetryPolicy.deadline(for: error, failureCount: index + 1, now: now) == now.addingTimeInterval(delay))
        }
        #expect(MarketRetryPolicy.deadline(for: MarketHistoryError.httpStatus(503), failureCount: index + 1, now: now) == now.addingTimeInterval(delay))
        #expect(MarketRetryPolicy.deadline(for: PriceError.httpStatus(408), failureCount: index + 1, now: now) == now.addingTimeInterval(delay))
    }
    for (index, delay) in [120.0, 240, 480, 900, 900].enumerated() {
        #expect(MarketRetryPolicy.deadline(for: MarketHistoryError.httpStatus(429), failureCount: index + 1, now: now) == now.addingTimeInterval(delay))
    }
    let terminal: [Error] = [CancellationError(), URLError(.cancelled), URLError(.badURL),
        URLError(.serverCertificateUntrusted), MarketHistoryError.invalidRange,
        MarketHistoryError.rangeTooLarge, MarketHistoryError.emptyHistory, MarketHistoryError.invalidResponse,
        PriceError.invalidPrice, PriceError.invalidResponse, MarketHistoryError.httpStatus(400),
        MarketHistoryError.httpStatus(401), MarketHistoryError.httpStatus(403), MarketHistoryError.httpStatus(404)]
    for error in terminal { #expect(MarketRetryPolicy.deadline(for: error, failureCount: 1, now: now) == nil) }
}

@Test func marketRetryHonorsServerDeadlineAndHeaderParsing() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(HTTPRetryError.retryAfter("180", now: now) == now.addingTimeInterval(180))
    #expect(HTTPRetryError.retryAfter("Wed, 15 Nov 2023 00:13:20 GMT", now: now) == now.addingTimeInterval(7200))
    #expect(HTTPRetryError.retryAfter("Tue, 14 Nov 2023 20:13:20 GMT", now: now) == now)
    #expect(HTTPRetryError.retryAfter("-1", now: now) == nil)
    #expect(HTTPRetryError.retryAfter("nan", now: now) == nil)
    #expect(HTTPRetryError.retryAfter("unavailable", now: now) == nil)
    #expect(HTTPRetryError.retryAfter(nil, now: now) == nil)
    #expect(MarketRetryPolicy.deadline(for: HTTPRetryError(statusCode: 429, retryAfter: now.addingTimeInterval(1800)), failureCount: 1, now: now) == now.addingTimeInterval(1800))
    #expect(MarketRetryPolicy.deadline(for: HTTPRetryError(statusCode: 503, retryAfter: now.addingTimeInterval(10)), failureCount: 1, now: now) == now.addingTimeInterval(60))
    #expect(MarketRetryPolicy.deadline(for: HTTPRetryError(statusCode: 403, retryAfter: now.addingTimeInterval(60)), failureCount: 1, now: now) == nil)
}
