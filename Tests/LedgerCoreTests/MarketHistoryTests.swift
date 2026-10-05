import Foundation
import Testing
@testable import LedgerCore

private let marketTestNow = Date(timeIntervalSince1970: 1_790_899_200)

private func yahooFixture(times: [Int64], open: [String], high: [String], low: [String], close: [String], currency: String = "USD") -> Data {
    Data("""
    {"chart":{"error":null,"result":[{"meta":{"currency":"\(currency)"},"timestamp":[\(times.map(String.init).joined(separator: ","))],"indicators":{"quote":[{"open":[\(open.joined(separator: ","))],"high":[\(high.joined(separator: ","))],"low":[\(low.joined(separator: ","))],"close":[\(close.joined(separator: ","))]}]}}]}}
    """.utf8)
}
private let dailyStart: Int64 = 1_790_726_400

@Test func realUSDOHLCParsingPreservesDecimalsAndDailyCloseTime() throws {
    let data = yahooFixture(times: [dailyStart, dailyStart + 86_400],
        open: ["564032.12345678", "567419"], high: ["571130.3", "569001"],
        low: ["563660.2", "566356"], close: ["567362.01", "568838"])
    let history = try MarketHistoryClient.decodeYahoo(data: data, fetchedAt: marketTestNow)
    #expect(history.candles.count == 2)
    #expect(history.candles[0].open == Decimal(string: "564032.12345678"))
    #expect(history.candles[0].startDate == Date(timeIntervalSince1970: Double(dailyStart)))
    #expect(history.candles[0].closeDate == Date(timeIntervalSince1970: Double(dailyStart + 86_400)))
    #expect(history.candles[0].high == Decimal(string: "571130.3"))
    #expect(history.candles[0].low == Decimal(string: "563660.2"))
    #expect(history.candles.allSatisfy { $0.isComplete })
    #expect(history.range == .all)
}

@Test func rejectMalformedAndNonpositiveDailyDataWithoutReplacingCache() throws {
    let malformed: [Data] = [Data("[]".utf8), Data("{}".utf8),
        yahooFixture(times: [dailyStart], open: ["0"], high: ["12"], low: ["0"], close: ["12"]),
        yahooFixture(times: [dailyStart], open: ["10", "11"], high: ["12"], low: ["8"], close: ["10"]),
        yahooFixture(times: [dailyStart, dailyStart], open: ["10", "10"], high: ["12", "12"], low: ["8", "8"], close: ["9", "9"]),
        yahooFixture(times: [dailyStart + 3 * 86_400], open: ["10"], high: ["12"], low: ["8"], close: ["9"]),
        yahooFixture(times: [dailyStart + 1], open: ["10"], high: ["12"], low: ["8"], close: ["9"]),
        yahooFixture(times: [dailyStart], open: ["10"], high: ["12"], low: ["8"], close: ["9"], currency: "CNY")]
    for fixture in malformed {
        #expect(throws: (any Error).self) { try MarketHistoryClient.decodeYahoo(data: fixture, fetchedAt: marketTestNow) }
    }
}

@Test func inconsistentProviderExtremaKeepOnlyGenuineCloseWithoutRepairingOHLC() throws {
    let history = try MarketHistoryClient.decodeYahoo(data: yahooFixture(times: [dailyStart],
        open: ["10"], high: ["12"], low: ["11"], close: ["12"]), fetchedAt: marketTestNow)
    let candle = try #require(history.candles.first)
    #expect(!candle.hasOHLC)
    #expect(candle.close == 12)
    #expect(candle.open == 12 && candle.high == 12 && candle.low == 12)
    #expect(history.source.contains("真实收盘"))
}

@Test func partialOHLCWithAvailableCloseRemainsARealReferencePoint() throws {
    let history = try MarketHistoryClient.decodeYahoo(data: yahooFixture(times: [dailyStart],
        open: ["null"], high: ["12"], low: ["8"], close: ["11"]), fetchedAt: marketTestNow)
    #expect(history.candles.count == 1)
    #expect(!history.candles[0].hasOHLC)
    #expect(history.candles[0].close == 11)
}

@Test func historicalPriceNeverUsesFutureDailyClose() throws {
    let prior = MarketCandle(closeDate: marketTestNow.addingTimeInterval(-86_400), interval: 86_400, open: 100, high: 120, low: 90, close: 110)
    let future = MarketCandle(closeDate: marketTestNow, interval: 86_400, open: 110, high: 150, low: 105, close: 140)
    let history = MarketHistory(range: .all, fetchedAt: marketTestNow, candles: [prior, future])
    #expect(history.latestClose(asOf: prior.closeDate.addingTimeInterval(-1)) == nil)
    #expect(history.latestClose(asOf: prior.closeDate) == prior)
    #expect(history.latestClose(asOf: marketTestNow.addingTimeInterval(-43_200)) == prior)
    #expect(history.latestClose(asOf: marketTestNow) == future)
}

@Test func historyCacheRoundTripPreservesOHLCAndCurrencyDecimals() throws {
    let history = try MarketHistoryClient.decodeYahoo(data: yahooFixture(times: [dailyStart], open: ["10.12345678"], high: ["12"], low: ["8"], close: ["9.99999999"]), fetchedAt: marketTestNow)
    #expect(try JSONDecoder().decode(MarketHistory.self, from: JSONEncoder().encode(history)) == history)
    let endpoint = MarketHistoryClient.yahooEndpoint(through: marketTestNow)
    #expect(endpoint.host == "query1.finance.yahoo.com")
    #expect(endpoint.path == "/v8/finance/chart/BTC-USD")
    #expect(endpoint.query == "interval=1d&period1=0&period2=1790899201")
}

@Test func currentDayPartialOHLCNeverPretendsItsFutureCloseIsKnown() throws {
    let currentStart = Int64(marketTestNow.timeIntervalSince1970)
    let fetchedAt = marketTestNow.addingTimeInterval(43_200)
    let history = try MarketHistoryClient.decodeYahoo(data: yahooFixture(times: [currentStart], open: ["10"], high: ["12"], low: ["8"], close: ["11"]), fetchedAt: fetchedAt)
    let candle = try #require(history.candles.first)
    #expect(candle.startDate == marketTestNow)
    #expect(candle.closeDate == fetchedAt)
    #expect(candle.interval == 43_200)
    #expect(!candle.isComplete)
    #expect(history.latestClose(asOf: fetchedAt.addingTimeInterval(-1)) == nil)
    #expect(history.latestClose(asOf: fetchedAt)?.close == 11)
}

@Test func nullMarketDayRemainsAGapInsteadOfAnInventedCandle() throws {
    let data = yahooFixture(times: [dailyStart, dailyStart + 86_400, dailyStart + 2 * 86_400],
        open: ["10", "null", "12"], high: ["12", "null", "15"], low: ["8", "null", "10"], close: ["11", "null", "14"])
    let history = try MarketHistoryClient.decodeYahoo(data: data, fetchedAt: marketTestNow.addingTimeInterval(43_200))
    #expect(history.candles.count == 2)
    #expect(!history.candles.contains { $0.startDate == Date(timeIntervalSince1970: Double(dailyStart + 86_400)) })
}

@Test func fullTimelineStartsAtGenesisWithoutFabricatingPricesBeforeFirstMarket() {
    #expect(MarketRange.all.startDate(today: marketTestNow) == Date(timeIntervalSince1970: 1_230_940_800))
    #expect(MarketRange.all.days > 6_000)
    #expect(MarketRange.allCases.map(\.title) == ["1 小时", "1 天", "7 天", "30 天", "90 天", "180 天", "1 年", "3 年", "全部"])
    #expect(MarketPeriod.allCases.map(\.title) == ["1 分钟", "3 分钟", "5 分钟", "15 分钟", "30 分钟", "1 小时", "2 小时", "4 小时", "6 小时", "8 小时", "12 小时", "日 K", "3 日", "周 K", "月 K", "3 月", "年 K"])
}

private func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T00:00:00Z")! }
private func dailyCandle(_ start: Date, open: Decimal, high: Decimal, low: Decimal, close: Decimal, hasOHLC: Bool = true) -> MarketCandle {
    MarketCandle(closeDate: start.addingTimeInterval(86_400), interval: 86_400, open: open, high: high, low: low, close: close, hasOHLC: hasOHLC)
}

@Test func weeklyAggregationUsesRealOpenHighLowLastCloseAndMondayBoundaries() throws {
    let monday = day("2026-09-21")
    let candles: [MarketCandle] = (0..<7).map { offset in
        let candleStart = monday.addingTimeInterval(Double(offset) * 86_400)
        let open = Decimal(10 + offset)
        let high = Decimal(20 + offset)
        let low = Decimal(5 + offset)
        let close = Decimal(11 + offset)
        return dailyCandle(candleStart, open: open, high: high, low: low, close: close)
    }
    let fetchedAt = monday.addingTimeInterval(7 * 86_400)
    let history = MarketHistory(range: .all, fetchedAt: fetchedAt, candles: candles)
    let week = try #require(history.aggregatedCandles(period: .week).first)
    #expect(week.startDate == monday)
    #expect(week.interval == 7 * 86_400)
    #expect(week.open == 10)
    #expect(week.high == 26)
    #expect(week.low == 5)
    #expect(week.close == 17)
    #expect(week.isComplete)
    #expect(week.missingDays == 0)
    #expect(week.hasOHLC)
}

@Test func monthlyAggregationUsesCalendarMonthsInsteadOfThirtyDayBuckets() throws {
    let start = day("2024-02-01")
    let candles: [MarketCandle] = (0..<29).map { offset in
        let candleStart = start.addingTimeInterval(Double(offset) * 86_400)
        let open = Decimal(100 + offset)
        let high = Decimal(120 + offset)
        let low = Decimal(90 + offset)
        let close = Decimal(110 + offset)
        return dailyCandle(candleStart, open: open, high: high, low: low, close: close)
    }
    let history = MarketHistory(range: .all, fetchedAt: day("2024-03-01"), candles: candles)
    let month = try #require(history.aggregatedCandles(period: .month).first)
    #expect(month.startDate == start)
    #expect(month.interval == 29 * 86_400)
    #expect(month.open == 100)
    #expect(month.high == 148)
    #expect(month.low == 90)
    #expect(month.close == 138)
    #expect(month.isComplete)
}

@Test func weeklyGapsAreReportedAndIncompletePeriodsDoNotInventData() throws {
    let monday = day("2026-09-21")
    let candles = [dailyCandle(monday, open: 10, high: 12, low: 8, close: 11),
                   dailyCandle(monday.addingTimeInterval(2 * 86_400), open: 11, high: 15, low: 10, close: 14)]
    let history = MarketHistory(range: .all, fetchedAt: monday.addingTimeInterval(7 * 86_400), candles: candles)
    let week = try #require(history.aggregatedCandles(period: .week).first)
    #expect(week.missingDays == 5)
    #expect(!week.isComplete)
    #expect(history.aggregatedCandles(period: .day).count == 2)
}

@Test func midnightCutoffNeverCountsTheNewUnobservedDayAsMissing() throws {
    let monday = day("2026-09-21")
    let candles = (0..<3).map { dailyCandle(monday.addingTimeInterval(Double($0) * 86_400), open: 10, high: 12, low: 8, close: 11) }
    let history = MarketHistory(range: .all, fetchedAt: monday.addingTimeInterval(3 * 86_400), candles: candles)
    let week = try #require(history.aggregatedCandles(period: .week).first)
    #expect(week.missingDays == 0)
    #expect(!week.isComplete)
}

@Test func mixedReferenceAndOHLCPeriodIsAReferenceLineRatherThanFabricatedK() throws {
    let monday = day("2026-09-21")
    let reference = dailyCandle(monday, open: 10, high: 10, low: 10, close: 10, hasOHLC: false)
    let real = dailyCandle(monday.addingTimeInterval(86_400), open: 11, high: 15, low: 10, close: 14)
    let history = MarketHistory(range: .all, fetchedAt: monday.addingTimeInterval(7 * 86_400), candles: [reference, real])
    let week = try #require(history.aggregatedCandles(period: .week).first)
    #expect(!week.hasOHLC)
    #expect(week.open == 14 && week.high == 14 && week.low == 14 && week.close == 14)
}

@Test func sourceMergePrioritizesRealOHLCAndUsesReferenceOnlyForMissingDays() throws {
    let first = day("2014-09-16")
    let second = first.addingTimeInterval(86_400)
    let third = second.addingTimeInterval(86_400)
    let references = [dailyCandle(first, open: 3, high: 3, low: 3, close: 3, hasOHLC: false),
        dailyCandle(second, open: 4, high: 4, low: 4, close: 4, hasOHLC: false),
        dailyCandle(third, open: 5, high: 5, low: 5, close: 5, hasOHLC: false)]
    let yahoo = dailyCandle(second, open: 10, high: 12, low: 8, close: 11)
    let merged = try MarketHistoryClient.combine(early: references,
        daily: MarketHistory(range: .all, fetchedAt: third.addingTimeInterval(86_400), candles: [yahoo], source: "Yahoo Finance"))
    #expect(merged.candles.count == 3)
    #expect(merged.candles[1] == yahoo)
    #expect(!merged.candles[0].hasOHLC && !merged.candles[2].hasOHLC)
    #expect(merged.source.contains("CoinMetrics PriceUSD"))
}

private final class HistoryFailureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"error\":\"rate limited\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func historicalNetworkFailuresAreExplicit() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HistoryFailureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    await #expect(throws: MarketHistoryError.httpStatus(429)) {
        try await MarketHistoryClient(session: session).fetch(range: .month)
    }
}

@Test func minuteNetworkFailuresAreExplicit() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HistoryFailureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    await #expect(throws: MarketHistoryError.httpStatus(429)) {
        try await MarketHistoryClient(session: session).fetchMinutes()
    }
}

@Test func dynamicCostIncludesEverySameDayEventAndUsesCutoffLedgerState() throws {
    let exchange = Account(name: "欧易")
    let wallet = Account(name: "自有钱包")
    let firstDate = marketTestNow.addingTimeInterval(-14_400)
    let secondDate = firstDate.addingTimeInterval(3600)
    let transferDate = secondDate.addingTimeInterval(3600)
    let purchase = syntheticEntry(date: firstDate, sequence: 1, kind: .buy, toAccountID: exchange.id, amountSats: 1_000_000, amountCNY: 1000)
    let second = syntheticEntry(date: secondDate, sequence: 2, kind: .buy, toAccountID: exchange.id, amountSats: 1_000_000, amountCNY: 2000)
    let transfer = syntheticEntry(date: transferDate, sequence: 3, kind: .transfer, fromAccountID: exchange.id, toAccountID: wallet.id, amountSats: 1_000_000, receivedSats: 995_000)
    let accounts = [exchange, wallet]
    let entries = [transfer, second, purchase]
    let old = try LedgerEngine.calculate(accounts: accounts, entries: entries, asOf: firstDate.addingTimeInterval(1))
    #expect(old.totalInvestedUSD == 1000)
    #expect(old.totalSats == 1_000_000)
    #expect(old.totalLossSats == 0)
    #expect(old.profit(price: 200_000) == 1000)
    let points = try LedgerChartHistory.costPoints(accounts: accounts, entries: entries, from: firstDate.addingTimeInterval(-1), through: marketTestNow)
    #expect(points.filter { $0.date == secondDate }.map(\.costUSD) == [100_000, 150_000])
    let transferred = try LedgerEngine.calculate(accounts: accounts, entries: entries, asOf: transferDate)
    #expect(points.filter { $0.date == transferDate }.map(\.costUSD) == [150_000, transferred.averageCostUSD!])
    #expect(transferred.totalLossSats == 5000)
    #expect(transferred.totalSats == 1_995_000)
    #expect(transferred.averageCostUSD! > 150_000)
}

@Test func everyEventHasMarkerEvenWhenHoldingIsExhaustedBeforeFirstClose() throws {
    let exchange = Account(name: "欧易")
    let wallet = Account(name: "自有钱包")
    let candle = MarketCandle(closeDate: marketTestNow, interval: 345_600, open: 100_000, high: 120_000, low: 90_000, close: 110_000)
    let purchase = syntheticEntry(date: candle.startDate.addingTimeInterval(3600), sequence: 1, kind: .buy,
                               toAccountID: exchange.id, amountSats: 1_000_000, amountCNY: 1000)
    let loss = syntheticEntry(date: purchase.date.addingTimeInterval(3600), sequence: 2, kind: .transfer,
                          fromAccountID: exchange.id, toAccountID: wallet.id, amountSats: 1_000_000, receivedSats: 0)
    let history = MarketHistory(range: .year, fetchedAt: marketTestNow, candles: [candle])
    let markers = try LedgerChartHistory.events(accounts: [exchange, wallet], entries: [purchase, loss],
                                               history: history, from: candle.startDate, through: candle.closeDate)
    #expect(markers.map(\.id) == [purchase.id, loss.id])
    #expect(markers[1].markerPriceUSD == 100_000)
    #expect(history.latestClose(asOf: loss.date) == nil)
}

@Test func sharedLedgerReplayPreservesInclusiveCutoffAndZeroHoldingGaps() throws {
    let exchange = Account(name: "欧易")
    let wallet = Account(name: "自有钱包")
    let firstDate = marketTestNow.addingTimeInterval(-10_800)
    let lossDate = firstDate.addingTimeInterval(3600)
    let rebuyDate = lossDate.addingTimeInterval(3600)
    let first = syntheticEntry(date: firstDate, sequence: 1, kind: .buy, toAccountID: exchange.id,
                              amountSats: 1_000_000, amountCNY: 1000)
    let sameInstant = syntheticEntry(date: firstDate, sequence: 2, kind: .buy, toAccountID: exchange.id,
                                    amountSats: 1_000_000, amountCNY: 2000)
    let exhausted = syntheticEntry(date: lossDate, sequence: 3, kind: .transfer,
                                  fromAccountID: exchange.id, toAccountID: wallet.id,
                                  amountSats: 2_000_000, receivedSats: 0)
    let rebuy = syntheticEntry(date: rebuyDate, sequence: 4, kind: .buy, toAccountID: exchange.id,
                              amountSats: 1_000_000, amountCNY: 500)
    let future = syntheticEntry(date: rebuyDate.addingTimeInterval(1), sequence: 5, kind: .buy,
                               toAccountID: exchange.id, amountSats: 1_000_000, amountCNY: 500)
    let accounts = [exchange, wallet]
    let entries = [future, rebuy, exhausted, sameInstant, first]
    let replay = try LedgerEngine.history(accounts: accounts, entries: entries)
    let costs = LedgerChartHistory.costPoints(ledgerHistory: replay, from: firstDate, through: rebuyDate)
    #expect(costs == (try LedgerChartHistory.costPoints(accounts: accounts, entries: entries,
                                                       from: firstDate, through: rebuyDate)))
    #expect(costs.map(\.costUSD) == [150_000, 150_000, 350_000, 350_000])
    #expect(costs.map(\.segment) == [0, 0, 1, 1])
    #expect(!costs.contains { $0.date > rebuyDate })
    #expect(LedgerChartHistory.costPoints(ledgerHistory: replay, from: firstDate, through: firstDate)
        .map(\.costUSD) == [150_000, 150_000])
    #expect(LedgerChartHistory.costPoints(ledgerHistory: replay, from: firstDate.addingTimeInterval(-1),
                                        through: firstDate.addingTimeInterval(-1)).isEmpty)
    #expect(LedgerChartHistory.costPoints(ledgerHistory: replay, from: rebuyDate, through: firstDate).isEmpty)
    let candle = MarketCandle(closeDate: marketTestNow, interval: 14_400,
                             open: 100_000, high: 120_000, low: 90_000, close: 110_000)
    let market = MarketHistory(range: .day, fetchedAt: marketTestNow, candles: [candle])
    let events = LedgerChartHistory.events(entries: entries, ledgerHistory: replay, history: market,
                                          from: firstDate, through: rebuyDate)
    #expect(events == (try LedgerChartHistory.events(accounts: accounts, entries: entries, history: market,
                                                     from: firstDate, through: rebuyDate)))
    #expect(events.map(\.id) == [first.id, sameInstant.id, exhausted.id, rebuy.id])
    #expect(events.map(\.markerPriceUSD) == [100_000, 150_000, 150_000, 350_000])
}

private final class EarlyFailureWithValidYahooProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isDaily = request.url?.host == "query1.finance.yahoo.com"
        let response = HTTPURLResponse(url: request.url!, statusCode: isDaily ? 200 : 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = isDaily
            ? yahooFixture(times: [dailyStart], open: ["10"], high: ["12"], low: ["8"], close: ["11"])
            : Data("{\"error\":\"historical reference unavailable\"}".utf8)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func unavailableEarlyReferenceDoesNotDiscardAvailableModernDailyHistory() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EarlyFailureWithValidYahooProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let history = try await MarketHistoryClient(session: session).fetch(range: .all)
    #expect(history.candles.count == 1)
    #expect(history.candles[0].hasOHLC)
    #expect(history.candles[0].close == 11)
    #expect(history.source.contains("Yahoo"))
    #expect(history.warning?.contains("早期参考历史暂不可用") == true)
}

@Test func cachedEarlierHistoryCanSurviveReferenceFailureWhileModernPricesRefresh() throws {
    let first = day("2010-07-18")
    let early = dailyCandle(first, open: 1, high: 1, low: 1, close: 1, hasOHLC: false)
    let modern = dailyCandle(day("2026-09-30"), open: 10, high: 12, low: 8, close: 11)
    let fetched = MarketHistory(range: .all, fetchedAt: marketTestNow, candles: [modern],
        source: "Yahoo Finance", warning: "早期参考历史暂不可用")
    let combined = try MarketHistoryClient.combine(early: [early], daily: fetched)
    #expect(combined.candles == [early, modern])
    #expect(combined.warning == fetched.warning)
}
