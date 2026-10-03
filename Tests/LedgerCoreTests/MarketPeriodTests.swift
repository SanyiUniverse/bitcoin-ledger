import Foundation
import Testing
@testable import LedgerCore

private func periodDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func periodBars(from start: Date, count: Int, seconds: TimeInterval) -> [MarketCandle] {
    (0..<count).map { index in
        MarketCandle(closeDate: start.addingTimeInterval(Double(index + 1) * seconds), interval: seconds,
            open: Decimal(10 + index), high: Decimal(30 + index), low: Decimal(1 + index), close: Decimal(11 + index))
    }
}

@Test func allCommonPeriodsHaveStableTitlesAndNativeIntradayGranularities() {
    #expect(MarketPeriod.allCases.count == 17)
    #expect(MarketPeriod.allCases.filter(\.isIntraday).count == 11)
    #expect(MarketPeriod.allCases.map(\.nominalSeconds) == [60, 180, 300, 900, 1800, 3600, 7200, 14_400,
        21_600, 28_800, 43_200, 86_400, 259_200, 604_800, 2_592_000, 7_776_000, 31_536_000])
    let requested: [MarketPeriod] = [.minute, .minute3, .minute5, .minute15, .minute30, .hour, .hour2, .hour4, .hour6, .hour8, .hour12]
    #expect(requested.map { MarketHistoryClient.nativeGranularity(period: $0) } == [60, 60, 300, 900, 900, 3600, 3600, 3600, 21_600, 3600, 21_600])
}

@Test func everyIntradayPeriodAggregatesRealMinuteOpenHighLowAndLastClose() throws {
    let start = periodDate("2026-09-21T00:00:00Z")
    for period in MarketPeriod.allCases.filter(\.isIntraday) {
        let count = Int(period.nominalSeconds / 60)
        let bars = periodBars(from: start, count: count, seconds: 60)
        let history = MarketHistory(range: .week, period: .minute,
            fetchedAt: start.addingTimeInterval(period.nominalSeconds), candles: bars)
        let aggregate = try #require(history.aggregatedCandles(period: period).first)
        #expect(aggregate.startDate == start && aggregate.interval == period.nominalSeconds)
        #expect(aggregate.open == 10 && aggregate.high == Decimal(29 + count))
        #expect(aggregate.low == 1 && aggregate.close == Decimal(10 + count))
        #expect(aggregate.hasOHLC && aggregate.isComplete)
    }
}

@Test func missingOrReferenceBaseBarsNeverBecomeCompleteAggregatedOHLC() throws {
    let start = periodDate("2026-09-21T00:00:00Z")
    let bars = periodBars(from: start, count: 3, seconds: 60)
    let missing = MarketHistory(range: .week, period: .minute, fetchedAt: start.addingTimeInterval(180),
        candles: [bars[0], bars[2]])
    let gap = try #require(missing.aggregatedCandles(period: .minute3).first)
    #expect(!gap.hasOHLC && !gap.isComplete && gap.close == bars[2].close)
    #expect(gap.open == gap.close && gap.high == gap.close && gap.low == gap.close)
    let reference = MarketCandle(closeDate: bars[1].closeDate, interval: 60,
        open: 99, high: 99, low: 99, close: 99, hasOHLC: false)
    let mixed = MarketHistory(range: .week, period: .minute, fetchedAt: missing.fetchedAt,
        candles: [bars[0], reference, bars[2]])
    let point = try #require(mixed.aggregatedCandles(period: .minute3).first)
    #expect(!point.hasOHLC && !point.isComplete && point.close == bars[2].close)
    #expect(mixed.aggregatedCandles(period: .minute)[1].isComplete == false)
    let emptyLeading = MarketHistory(range: .week, period: .minute, fetchedAt: missing.fetchedAt, candles: [bars[1], bars[2]])
    #expect(emptyLeading.aggregatedCandles(period: .minute3).first?.hasOHLC == false)
}

@Test func ongoingAggregatedBarEndsAtRealObservationAndNeverBorrowsFutureClose() throws {
    let start = periodDate("2026-09-21T00:00:00Z")
    let complete = periodBars(from: start, count: 2, seconds: 60)
    let live = MarketCandle(closeDate: start.addingTimeInterval(150), interval: 30,
        open: 12, high: 32, low: 3, close: 13, isComplete: false)
    let history = MarketHistory(range: .week, period: .minute, fetchedAt: live.closeDate, candles: complete + [live])
    let bar = try #require(history.aggregatedCandles(period: .minute3).first)
    #expect(bar.hasOHLC && !bar.isComplete && bar.closeDate == live.closeDate && bar.interval == 150)
    let result = MarketHistory(range: .week, period: .minute3, fetchedAt: history.fetchedAt, candles: [bar])
    #expect(result.latestClose(asOf: live.closeDate.addingTimeInterval(-1)) == nil)
    #expect(result.aggregatedCandles(period: .minute3) == [bar])
}

@Test func threeDayUsesEpochAndQuarterYearUseNaturalUTCLeapCalendar() throws {
    let day = periodDate("2024-01-01T00:00:00Z")
    let triple = MarketPeriod.day3.bucket(containing: day)
    #expect(triple.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 259_200) == 0)
    let tripleHistory = MarketHistory(range: .all, fetchedAt: triple.end,
        candles: periodBars(from: triple.start, count: 3, seconds: 86_400))
    #expect(tripleHistory.aggregatedCandles(period: .day3).first?.interval == 259_200)
    for (period, count, end) in [(MarketPeriod.quarter, 91, "2024-04-01T00:00:00Z"), (.year, 366, "2025-01-01T00:00:00Z")] {
        let history = MarketHistory(range: .all, fetchedAt: periodDate(end),
            candles: periodBars(from: day, count: count, seconds: 86_400))
        let result = try #require(history.aggregatedCandles(period: period).first)
        #expect(result.startDate == day && result.closeDate == periodDate(end))
        #expect(result.interval == Double(count) * 86_400 && result.hasOHLC && result.isComplete)
    }
    #expect(MarketPeriod.quarter.bucket(containing: periodDate("2024-05-31T12:00:00Z")).start == periodDate("2024-04-01T00:00:00Z"))
}

@Test func dailyAndCoarserBarsCannotBeSplitIntoIntradayPeriods() {
    let start = periodDate("2026-09-21T00:00:00Z")
    let history = MarketHistory(range: .all, fetchedAt: start.addingTimeInterval(86_400),
        candles: periodBars(from: start, count: 1, seconds: 86_400))
    #expect(MarketPeriod.allCases.filter(\.isIntraday).allSatisfy { history.aggregatedCandles(period: $0).isEmpty })
    let five = MarketHistory(range: .week, period: .minute5, fetchedAt: start.addingTimeInterval(300),
        candles: periodBars(from: start, count: 1, seconds: 300))
    #expect(five.aggregatedCandles(period: .minute3).isEmpty)
}

@Test func historicalIntradayRangeAlignsRequestedBucketsAndNeverClampsToRecentWeek() throws {
    let start = periodDate("2015-01-01T00:07:00Z")
    let end = periodDate("2015-01-02T08:03:00Z")
    let now = periodDate("2026-10-02T00:00:00Z")
    let plan = try MarketHistoryClient.intradayPlan(period: .hour2, from: start, through: end, now: now)
    #expect(plan.start == periodDate("2015-01-01T00:00:00Z"))
    #expect(plan.end == periodDate("2015-01-02T08:00:00Z"))
    #expect(plan.end <= end)
    #expect(plan.granularity == 3600 && plan.nativeCount == 32)
    let pages = MarketHistoryClient.coinbasePages(from: plan.start, through: plan.end, granularity: plan.granularity)
    #expect(pages.count == 1 && pages.first?.end == plan.end)
}

@Test func shortViewportWithCoarseIntradayPeriodUsesRealFinerSourceObservations() throws {
    let now = periodDate("2026-10-02T08:15:00Z")
    let start = now.addingTimeInterval(-3600)
    for period in [MarketPeriod.hour6, .hour12] {
        let plan = try MarketHistoryClient.intradayPlan(period: period, from: start, through: now, now: now)
        #expect(plan.granularity == 3600)
        #expect(plan.end == periodDate("2026-10-02T08:00:00Z"))
        #expect(plan.end >= start && plan.end <= now)
        let bars = periodBars(from: plan.start, count: plan.nativeCount, seconds: Double(plan.granularity))
        let source = MarketHistory(range: .hour, period: .hour, fetchedAt: now, candles: bars)
        let aggregated = source.aggregatedCandles(period: period, through: plan.end)
        let history = MarketHistory(range: .hour, period: period, fetchedAt: now, candles: aggregated)
        let observed = try #require(history.aggregatedCandles(period: period, from: start, through: now).last)
        #expect(observed.hasOHLC && !observed.isComplete)
        #expect(observed.closeDate == plan.end && observed.closeDate >= start && observed.closeDate <= now)
        #expect(observed.close == bars.last?.close)
    }
    for period in MarketPeriod.allCases where period.isIntraday {
        let plan = try MarketHistoryClient.intradayPlan(period: period, from: start, through: now, now: now)
        #expect(Double(plan.granularity) <= now.timeIntervalSince(start))
        #expect(Int(period.nominalSeconds) % plan.granularity == 0)
        #expect(plan.end >= start && plan.end <= now)
    }
    #expect(try MarketHistoryClient.intradayPlan(period: .hour12,
        from: now.addingTimeInterval(-86400), through: now, now: now).granularity == 21600)
}

@Test func historicalShortCoarsePeriodStillExcludesUnobservedFutureClose() throws {
    let now = periodDate("2026-10-02T08:15:00Z")
    let end = periodDate("2015-01-01T08:15:00Z")
    let start = end.addingTimeInterval(-3600)
    let plan = try MarketHistoryClient.intradayPlan(period: .hour12, from: start, through: end, now: now)
    #expect(plan.granularity == 3600 && plan.end == periodDate("2015-01-01T08:00:00Z"))
    let bars = periodBars(from: plan.start, count: plan.nativeCount, seconds: 3600)
    let source = MarketHistory(range: .hour, period: .hour, fetchedAt: now, candles: bars)
    let aggregated = source.aggregatedCandles(period: .hour12, through: plan.end)
    let history = MarketHistory(range: .hour, period: .hour12, fetchedAt: now, candles: aggregated)
    let observed = try #require(history.aggregatedCandles(period: .hour12, from: start, through: end).last)
    #expect(observed.closeDate == periodDate("2015-01-01T08:00:00Z"))
    #expect(observed.closeDate <= end && !observed.isComplete && observed.hasOHLC)
    #expect(observed.close == bars[7].close)
    #expect(history.latestClose(asOf: observed.closeDate.addingTimeInterval(-1)) == nil)
}

@Test func intradayOutputAndNativeLimitsAreExplicitBeforeAnyRequests() throws {
    let start = periodDate("2015-01-01T00:00:00Z")
    let now = periodDate("2026-10-02T00:00:00Z")
    #expect(try MarketHistoryClient.intradayPlan(period: .minute, from: start,
        through: start.addingTimeInterval(16_000 * 60), now: now).nativeCount == 16_000)
    #expect(throws: MarketHistoryError.rangeTooLarge) {
        try MarketHistoryClient.intradayPlan(period: .minute, from: start,
            through: start.addingTimeInterval(16_001 * 60), now: now)
    }
    #expect(throws: MarketHistoryError.rangeTooLarge) {
        try MarketHistoryClient.intradayPlan(period: .hour8, from: start,
            through: start.addingTimeInterval(12_501 * 28_800), now: now)
    }
    #expect(throws: MarketHistoryError.rangeTooLarge) {
        try MarketHistoryClient.intradayPlan(period: .minute, from: MarketRange.genesisDate, through: now, now: now)
    }
    #expect(MarketHistoryError.rangeTooLarge.localizedDescription.contains("更长"))
}

@Test func futureInvalidRangesAndCurrentUnclosedNativeBarAreNeverFetched() throws {
    let now = periodDate("2026-10-02T00:00:30Z")
    let start = now.addingTimeInterval(-86_400)
    for (period, from, through) in [(MarketPeriod.minute, start, now.addingTimeInterval(1)),
        (.day, start, now), (.minute, now, start)] {
        #expect(throws: MarketHistoryError.invalidRange) {
            try MarketHistoryClient.intradayPlan(period: period, from: from, through: through, now: now)
        }
    }
    #expect(throws: MarketHistoryError.emptyHistory) {
        try MarketHistoryClient.intradayPlan(period: .minute, from: now.addingTimeInterval(-20), through: now, now: now)
    }
    let plan = try MarketHistoryClient.intradayPlan(period: .hour2, from: start, through: now, now: now)
    #expect(plan.end <= now && plan.end == periodDate("2026-10-02T00:00:00Z"))
}

private final class IntradayRequestLog: @unchecked Sendable {
    let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}
private class IntradaySourceProtocol: URLProtocol, @unchecked Sendable {
    class var log: IntradayRequestLog { IntradayHourProtocol.recorded }
    class var hasGap: Bool { false }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        type(of: self).log.append(request)
        let params = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            .map { ($0.name, $0.value ?? "") })
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: params["start"] ?? "")!
        let end = formatter.date(from: params["end"] ?? "")!
        let granularity = Int(params["granularity"] ?? "")!
        let valid = request.url?.host == "api.exchange.coinbase.com" && request.url?.path == "/products/BTC-USD/candles"
            && end.timeIntervalSince(start) <= Double(granularity * 300)
            && request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil
            && request.httpBody == nil
        let missing = periodDate("2015-01-01T01:00:00Z").timeIntervalSince1970
        let rows = stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: Double(granularity))
            .filter { !type(of: self).hasGap || $0 != missing }
            .map { "[\(Int64($0)),8,12,10,11,1]" }.reversed()
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 400, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[\(rows.joined(separator: ","))]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class IntradayHourProtocol: IntradaySourceProtocol, @unchecked Sendable { static let recorded = IntradayRequestLog() }
private final class IntradayMinuteProtocol: IntradaySourceProtocol, @unchecked Sendable {
    static let recorded = IntradayRequestLog()
    override class var log: IntradayRequestLog { recorded }
}
private final class IntradayGapProtocol: IntradaySourceProtocol, @unchecked Sendable {
    static let recorded = IntradayRequestLog()
    override class var log: IntradayRequestLog { recorded }
    override class var hasGap: Bool { true }
}
private final class IntradayShortProtocol: IntradaySourceProtocol, @unchecked Sendable {
    static let recorded = IntradayRequestLog()
    override class var log: IntradayRequestLog { recorded }
}
private func intradaySession(_ protocolClass: AnyClass) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return URLSession(configuration: configuration)
}

@Test func customHistoricalHoursFetchOnlyNativeUSDWithoutFXOrRecentWindowClamp() async throws {
    let session = intradaySession(IntradayHourProtocol.self)
    defer { session.invalidateAndCancel() }
    let history = try await MarketHistoryClient(session: session).fetchIntraday(period: .hour2,
        from: periodDate("2015-01-01T00:07:00Z"), through: periodDate("2015-01-02T08:03:00Z"))
    #expect(history.period == .hour2 && history.candles.count == 16)
    #expect(history.candles.allSatisfy { $0.isComplete && $0.hasOHLC && $0.interval == 7200 && $0.close == 11 })
    #expect(history.candles.first?.startDate == periodDate("2015-01-01T00:00:00Z"))
    #expect(history.warning == nil && history.source.contains("美元") && !history.source.contains("ECB"))
    #expect(IntradayHourProtocol.recorded.requests.count == 1)
}

@Test func historicalShortWindowFetchesPartialCoarsePeriodBeforeExactCutoff() async throws {
    let session = intradaySession(IntradayShortProtocol.self)
    defer { session.invalidateAndCancel() }
    let start = periodDate("2015-01-01T07:15:00Z")
    let end = periodDate("2015-01-01T08:15:00Z")
    for period in [MarketPeriod.hour6, .hour12] {
        let history = try await MarketHistoryClient(session: session).fetchIntraday(period: period, from: start, through: end)
        let visible = history.aggregatedCandles(period: period, from: start, through: end)
        let candle = try #require(visible.last)
        #expect(history.period == period && visible.count == 1)
        #expect(candle.hasOHLC && !candle.isComplete)
        #expect(candle.closeDate == periodDate("2015-01-01T08:00:00Z"))
        #expect(candle.closeDate >= start && candle.closeDate <= end)
        #expect(history.warning == nil)
    }
    #expect(IntradayShortProtocol.recorded.requests.count == 2)
    #expect(IntradayShortProtocol.recorded.requests.allSatisfy { request in
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains {
            $0.name == "granularity" && $0.value == "3600"
        }
    })
}

@Test func customThreeMinuteHistoryPagesAreHalfOpenAndNoBoundaryIsDuplicated() async throws {
    let session = intradaySession(IntradayMinuteProtocol.self)
    defer { session.invalidateAndCancel() }
    let history = try await MarketHistoryClient(session: session).fetchIntraday(period: .minute3,
        from: periodDate("2015-01-01T00:00:00Z"), through: periodDate("2015-01-01T10:00:00Z"))
    #expect(history.period == .minute3 && history.candles.count == 200)
    #expect(Set(history.candles.map(\.startDate)).count == 200)
    #expect(history.candles.allSatisfy { $0.interval == 180 && $0.hasOHLC && $0.isComplete })
    #expect(IntradayMinuteProtocol.recorded.requests.count == 2)
    #expect(history.warning == nil)
}

@Test func customHistoricalNativeGapMakesAffectedAggregateARealCloseReference() async throws {
    let session = intradaySession(IntradayGapProtocol.self)
    defer { session.invalidateAndCancel() }
    let history = try await MarketHistoryClient(session: session).fetchIntraday(period: .hour2,
        from: periodDate("2015-01-01T00:00:00Z"), through: periodDate("2015-01-01T04:00:00Z"))
    #expect(history.candles.count == 2)
    #expect(history.candles.first?.hasOHLC == false && history.candles.first?.isComplete == false)
    #expect(history.candles.last?.hasOHLC == true && history.candles.last?.isComplete == true)
    #expect(history.warning?.contains("1 个 1 小时来源时段") == true)
}
