import Foundation
import Testing
@testable import LedgerCore

private let sourceMinute = Date(timeIntervalSince1970: 1_790_899_200)

private func sourceBar(_ start: Date, open: Decimal = 10, high: Decimal = 12,
                       low: Decimal = 8, close: Decimal = 11) -> MarketCandle {
    MarketCandle(closeDate: start.addingTimeInterval(60), interval: 60,
        open: open, high: high, low: low, close: close)
}

@Test func minuteReferenceDoesNotFillMissingBarsOrCountTheCurrentMinuteAsMissing() throws {
    let live = MarketCandle(closeDate: sourceMinute.addingTimeInterval(150), interval: 30,
        open: 20, high: 22, low: 18, close: 21, isComplete: false)
    let history = try MarketHistoryClient.minuteHistory(usd: [sourceBar(sourceMinute), live],
        from: sourceMinute, fetchedAt: sourceMinute.addingTimeInterval(150), source: "fixture")
    #expect(history.candles.count == 2)
    #expect(history.warning?.contains("1 个已结束分钟") == true)
    #expect(history.candles.last?.closeDate == history.fetchedAt)
    #expect(history.latestClose(asOf: history.fetchedAt.addingTimeInterval(-1))?.close == 11)
    #expect(history.latestClose(asOf: history.fetchedAt)?.close == 21)
    #expect(try MarketHistoryClient.missingMinutes(candles: history.candles, from: sourceMinute,
        through: sourceMinute.addingTimeInterval(120)) == [sourceMinute.addingTimeInterval(60)])
}

private func coinbaseFixture(_ starts: [Date]) -> Data {
    let rows = starts.map { "[\(Int64($0.timeIntervalSince1970)),8,12,10,11,1]" }
    return Data("[\(rows.joined(separator: ","))]".utf8)
}

@Test func coinbaseReverseOrderInclusive301stBoundaryAndAdjacentPagesAreHandled() throws {
    let end = sourceMinute.addingTimeInterval(18_000)
    let starts = (0...300).map { sourceMinute.addingTimeInterval(Double($0) * 60) }
    let bars = try MarketHistoryClient.decodeCoinbase(data: coinbaseFixture(starts.reversed()),
        from: sourceMinute, through: end, fetchedAt: end)
    #expect(bars.count == 300)
    #expect(bars.first?.startDate == sourceMinute && bars.last?.closeDate == end)
    #expect(bars.allSatisfy { $0.hasOHLC && $0.isComplete && $0.interval == 60 })
    let nextEnd = end.addingTimeInterval(60)
    let next = try MarketHistoryClient.decodeCoinbase(data: coinbaseFixture([end, nextEnd]),
        from: end, through: nextEnd, fetchedAt: nextEnd)
    #expect(Set((bars + next).map(\.startDate)).count == 301)
    let decimal = Data("[[1790899200,8.123456789123,12.987654321987,10.123456789123,11.987654321987,0.00000001]]".utf8)
    let exact = try MarketHistoryClient.decodeCoinbase(data: decimal, from: sourceMinute,
        through: sourceMinute.addingTimeInterval(60), fetchedAt: end)
    #expect(exact.first?.open == Decimal(string: "10.123456789123"))
    #expect(exact.first?.close == Decimal(string: "11.987654321987"))
}

@Test func coinbaseInvalidRecordsAreRejectedAndInconsistentExtremaKeepOnlyGenuineClose() throws {
    let end = sourceMinute.addingTimeInterval(60)
    let invalid = [
        coinbaseFixture([sourceMinute, sourceMinute]),
        Data("[[1790899201,8,12,10,11,1]]".utf8),
        Data("[[1790899200.5,8,12,10,11,1]]".utf8),
        Data("[[1790899200,8,12,10,0,1]]".utf8),
        Data("[[1790899200,8,12,10,null,1]]".utf8),
        Data("[[1790899200,8,12,10,11,-1]]".utf8),
        Data("[[1790899200,8,12,10,11]]".utf8)]
    for data in invalid {
        #expect(throws: MarketHistoryError.invalidResponse) {
            try MarketHistoryClient.decodeCoinbase(data: data, from: sourceMinute, through: end, fetchedAt: end)
        }
    }
    let badHighLow = Data("[[1790899200,11,10,10,12,1]]".utf8)
    let close = try MarketHistoryClient.decodeCoinbase(data: badHighLow, from: sourceMinute, through: end, fetchedAt: end)
    #expect(close.count == 1 && close[0].close == 12 && !close[0].hasOHLC)
    #expect(close[0].open == 12 && close[0].high == 12 && close[0].low == 12)
    #expect(try MarketHistoryClient.decodeCoinbase(data: coinbaseFixture([end]),
        from: sourceMinute, through: end, fetchedAt: end).isEmpty)
    #expect(throws: MarketHistoryError.invalidResponse) {
        try MarketHistoryClient.decodeCoinbase(data: coinbaseFixture([sourceMinute]),
            from: sourceMinute, through: end, fetchedAt: sourceMinute)
    }
}

@Test func scatteredMinuteGapsHaveAtMost34BoundedCoinbaseRequests() throws {
    let end = sourceMinute.addingTimeInterval(7 * 86_400)
    let missing = try MarketHistoryClient.missingMinutes(candles: [], from: sourceMinute, through: end)
    #expect(missing.count == 10_080)
    let pages = MarketHistoryClient.coinbaseRepairPages(missing: missing, from: sourceMinute, through: end)
    #expect(pages.count == 34)
    #expect(pages.first?.start == sourceMinute && pages.last?.end == end)
    #expect(pages.allSatisfy { $0.end.timeIntervalSince($0.start) <= 18_000 })
    #expect(MarketHistoryClient.coinbaseRepairPages(missing: [missing[1234]], from: sourceMinute, through: end).count == 1)
    #expect(MarketHistoryClient.coinbaseRepairPages(missing: [], from: sourceMinute, through: end).isEmpty)
    #expect(throws: MarketHistoryError.invalidResponse) {
        try MarketHistoryClient.missingMinutes(candles: [], from: sourceMinute, through: end.addingTimeInterval(1))
    }
}

private final class MinuteRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private enum MinuteFixtureMode { case gap, outage, repairUnavailable, noGap }
private class MinuteSourceProtocol: URLProtocol, @unchecked Sendable {
    class var mode: MinuteFixtureMode { .gap }
    class var log: MinuteRequestLog { PrimaryMinuteProtocol.recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        type(of: self).log.append(request)
        let url = request.url!
        let params = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        var status = 200
        var data = Data()
        if url.host == "query1.finance.yahoo.com", url.path == "/v8/finance/chart/BTC-USD" {
            if type(of: self).mode == .outage { status = 503 }
            else {
                let start = Int64(params["period1"] ?? "") ?? 0
                let end = Int64(params["period2"] ?? "") ?? 0
                let times = stride(from: start, through: (end - 1) / 60 * 60, by: 60).map { $0 }
                let count = times.count
                let prices: ([String], String) -> String = { values, value in
                    values.enumerated().map { index, _ in
                        type(of: self).mode != .noGap && index == values.count - 120 ? "null" : value
                    }.joined(separator: ",")
                }
                let placeholders = Array(repeating: "", count: count)
                data = Data("""
                {"chart":{"error":null,"result":[{"meta":{"currency":"USD","dataGranularity":"1m"},"timestamp":[\(times.map(String.init).joined(separator: ","))],"indicators":{"quote":[{"open":[\(prices(placeholders,"10"))],"high":[\(prices(placeholders,"12"))],"low":[\(prices(placeholders,"8"))],"close":[\(prices(placeholders,"11"))]}]}}]}}
                """.utf8)
            }
        } else if url.host == "api.exchange.coinbase.com", url.path == "/products/BTC-USD/candles" {
            if type(of: self).mode == .repairUnavailable { status = 429 }
            else {
                let formatter = ISO8601DateFormatter()
                let start = formatter.date(from: params["start"] ?? "")!
                let end = formatter.date(from: params["end"] ?? "")!
                let times = stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: 60)
                    .map { Date(timeIntervalSince1970: $0) }
                data = coinbaseFixture(times.reversed())
            }
        } else { status = 400 }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class PrimaryMinuteProtocol: MinuteSourceProtocol, @unchecked Sendable {
    static let recorded = MinuteRequestLog()
}
private final class OutageMinuteProtocol: MinuteSourceProtocol, @unchecked Sendable {
    static let recorded = MinuteRequestLog()
    override class var mode: MinuteFixtureMode { .outage }
    override class var log: MinuteRequestLog { recorded }
}
private final class UnavailableRepairProtocol: MinuteSourceProtocol, @unchecked Sendable {
    static let recorded = MinuteRequestLog()
    override class var mode: MinuteFixtureMode { .repairUnavailable }
    override class var log: MinuteRequestLog { recorded }
}
private final class NoGapMinuteProtocol: MinuteSourceProtocol, @unchecked Sendable {
    static let recorded = MinuteRequestLog()
    override class var mode: MinuteFixtureMode { .noGap }
    override class var log: MinuteRequestLog { recorded }
}

private func sourceSession(_ protocolClass: AnyClass) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return URLSession(configuration: configuration)
}

private func assertPublicMinuteRequests(_ requests: [URLRequest]) {
    for request in requests {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0")
        #expect(["query1.finance.yahoo.com", "api.exchange.coinbase.com"].contains(request.url!.host!))
        let params = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            .map { ($0.name, $0.value ?? "") })
        switch request.url!.host! {
        case "query1.finance.yahoo.com":
            #expect(request.url!.path == "/v8/finance/chart/BTC-USD")
            #expect(Set(params.keys) == ["interval", "period1", "period2"] && params["interval"] == "1m")
            #expect(Int64(params["period1"]!)! % 60 == 0)
        default:
            #expect(request.url!.path == "/products/BTC-USD/candles")
            #expect(Set(params.keys) == ["granularity", "start", "end"] && params["granularity"] == "60")
            let formatter = ISO8601DateFormatter()
            #expect(formatter.date(from: params["end"]!)!.timeIntervalSince(formatter.date(from: params["start"]!)!) <= 18_000)
        }
    }
}

@Test func yahooUSDNullMinuteIsRepairedByGenuineCoinbaseOHLCInTwoPublicRequests() async throws {
    let session = sourceSession(PrimaryMinuteProtocol.self)
    defer { session.invalidateAndCancel() }
    let history = try await MarketHistoryClient(session: session).fetchMinutes()
    let complete = history.candles.filter(\.isComplete)
    #expect(complete.count == 10_080 && complete.allSatisfy { $0.close == 11 && $0.hasOHLC })
    #expect(history.warning == nil)
    #expect(history.source.contains("Yahoo Finance / Coinbase") && history.source.contains("美元"))
    #expect(PrimaryMinuteProtocol.recorded.requests.count == 2)
    assertPublicMinuteRequests(PrimaryMinuteProtocol.recorded.requests)
}

@Test func completeYahooMinutesNeedNoCoinbaseRequestsOrCurrentMinuteFilling() async throws {
    let session = sourceSession(NoGapMinuteProtocol.self)
    defer { session.invalidateAndCancel() }
    let history = try await MarketHistoryClient(session: session).fetchMinutes()
    #expect(history.candles.filter(\.isComplete).count == 10_080)
    #expect(history.warning == nil && !history.source.contains("Coinbase"))
    #expect(NoGapMinuteProtocol.recorded.requests.count == 1)
    #expect(try #require(history.candles.last).closeDate <= history.fetchedAt)
    assertPublicMinuteRequests(NoGapMinuteProtocol.recorded.requests)
}

@Test func unavailableCoinbaseStopsAfterOneRequestAndReportsActualRemainingGap() async throws {
    let session = sourceSession(UnavailableRepairProtocol.self)
    defer { session.invalidateAndCancel() }
    let history = try await MarketHistoryClient(session: session).fetchMinutes()
    #expect(history.candles.filter(\.isComplete).count == 10_079)
    #expect(history.warning?.contains("1 个已结束分钟") == true)
    #expect(!history.source.contains("Coinbase"))
    #expect(UnavailableRepairProtocol.recorded.requests.count == 2)
    assertPublicMinuteRequests(UnavailableRepairProtocol.recorded.requests)
}

@Test func yahooOutageFallsBackTo34BoundedCoinbasePagesWithoutSyntheticBars() async throws {
    let session = sourceSession(OutageMinuteProtocol.self)
    defer { session.invalidateAndCancel() }
    let history = try await MarketHistoryClient(session: session).fetchMinutes()
    #expect(history.candles.count == 10_080)
    #expect(history.candles.allSatisfy { $0.isComplete && $0.hasOHLC && $0.close == 11 })
    #expect(history.warning == nil && history.source.contains("Coinbase") && !history.source.contains("Yahoo Finance"))
    #expect(OutageMinuteProtocol.recorded.requests.count == 35)
    assertPublicMinuteRequests(OutageMinuteProtocol.recorded.requests)
}
