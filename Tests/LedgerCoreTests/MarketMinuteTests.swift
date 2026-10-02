import Foundation
import Testing
@testable import LedgerCore

private let minuteStart: Int64 = 1_790_899_200
private let minuteDate = Date(timeIntervalSince1970: Double(minuteStart))
private func minuteFixture(times: [Int64], open: [String], high: [String], low: [String], close: [String],
                           currency: String = "USD", granularity: String = "1m") -> Data {
    Data("""
    {"chart":{"error":null,"result":[{"meta":{"currency":"\(currency)","dataGranularity":"\(granularity)"},"timestamp":[\(times.map(String.init).joined(separator: ","))],"indicators":{"quote":[{"open":[\(open.joined(separator: ","))],"high":[\(high.joined(separator: ","))],"low":[\(low.joined(separator: ","))],"close":[\(close.joined(separator: ","))]}]}}]}}
    """.utf8)
}

@Test func minuteOHLCIsExactAndOffGridLiveQuoteDoesNotBecomeACandle() throws {
    let data = minuteFixture(times: [minuteStart, minuteStart + 60, minuteStart + 119],
        open: ["564032.123456789123", "567362.987654321987", "999999"],
        high: ["570000", "571000", "999999"], low: ["560000", "560001", "999999"],
        close: ["567362.987654321987", "568000", "999999"])
    let history = try MarketHistoryClient.decodeYahooMinutes(data: data, fetchedAt: minuteDate.addingTimeInterval(180))
    #expect(history.period == .minute && history.range == .week)
    #expect(history.candles.count == 2)
    #expect(history.candles[0].open == Decimal(string: "564032.123456789123"))
    #expect(history.candles[0].close == Decimal(string: "567362.987654321987"))
    #expect(history.candles[0].startDate == minuteDate)
    #expect(history.candles[0].closeDate == minuteDate.addingTimeInterval(60))
    #expect(history.candles.allSatisfy { $0.interval == 60 && $0.isComplete && $0.hasOHLC })
    #expect(history.latestClose(asOf: minuteDate.addingTimeInterval(119))?.close == history.candles[0].close)
    #expect(history.latestClose(asOf: minuteDate.addingTimeInterval(120))?.close == 568000)
}

@Test func liveMinuteCloseIsAvailableOnlyAtObservedTimeAndNeverAtAFutureBoundary() throws {
    let fetchedAt = minuteDate.addingTimeInterval(90)
    let data = minuteFixture(times: [minuteStart, minuteStart + 60], open: ["10", "20"],
        high: ["12", "22"], low: ["8", "18"], close: ["11", "21"])
    let history = try MarketHistoryClient.decodeYahooMinutes(data: data, fetchedAt: fetchedAt)
    #expect(history.candles[0].isComplete)
    let live = try #require(history.candles.last)
    #expect(live.startDate == minuteDate.addingTimeInterval(60))
    #expect(live.closeDate == fetchedAt && live.interval == 30)
    #expect(!live.isComplete)
    #expect(history.latestClose(asOf: minuteDate.addingTimeInterval(59)) == nil)
    #expect(history.latestClose(asOf: fetchedAt.addingTimeInterval(-1))?.close == 11)
    #expect(history.latestClose(asOf: fetchedAt)?.close == 21)
    #expect(history.aggregatedCandles(period: .minute, through: fetchedAt.addingTimeInterval(-1)).count == 1)
}

@Test func absentMinutesStayAbsentAndUnusableOHLCOnlyRetainsRealClose() throws {
    let data = minuteFixture(times: [minuteStart, minuteStart + 60, minuteStart + 120, minuteStart + 180],
        open: ["10", "null", "10", "null"], high: ["12", "null", "12", "14"],
        low: ["8", "null", "11", "11"], close: ["11", "null", "12", "13"])
    let history = try MarketHistoryClient.decodeYahooMinutes(data: data, fetchedAt: minuteDate.addingTimeInterval(240))
    #expect(history.candles.map(\.startDate) == [minuteDate, minuteDate.addingTimeInterval(120), minuteDate.addingTimeInterval(180)])
    #expect(history.candles.map(\.close) == [11, 12, 13])
    #expect(history.candles.map(\.hasOHLC) == [true, false, false])
    #expect(history.candles.allSatisfy(MarketHistoryClient.valid))
    #expect(history.source.contains("真实收盘"))
}

@Test func minuteAggregationFiltersRealBarsWithoutSplittingDailyOrReferenceData() throws {
    let data = minuteFixture(times: [minuteStart, minuteStart + 60, minuteStart + 120],
        open: ["10", "20", "30"], high: ["12", "22", "32"],
        low: ["8", "18", "28"], close: ["11", "21", "31"])
    let history = try MarketHistoryClient.decodeYahooMinutes(data: data, fetchedAt: minuteDate.addingTimeInterval(180))
    #expect(history.aggregatedCandles(period: .minute, from: minuteDate.addingTimeInterval(61),
        through: minuteDate.addingTimeInterval(150)) == [history.candles[1]])
    let partialDaily = MarketCandle(closeDate: minuteDate.addingTimeInterval(30), interval: 30,
        open: 10, high: 12, low: 8, close: 11, isComplete: false)
    let daily = MarketHistory(range: .all, fetchedAt: minuteDate.addingTimeInterval(30), candles: [partialDaily])
    #expect(daily.aggregatedCandles(period: .minute).isEmpty)
    #expect(daily.aggregatedCandles(period: .day) == [partialDaily])
}

@Test func minuteCacheRoundTripPreservesPeriodAndOldDailyCacheKeepsItsMeaning() throws {
    let history = try MarketHistoryClient.decodeYahooMinutes(data: minuteFixture(times: [minuteStart],
        open: ["10.123456789123"], high: ["12"], low: ["8"], close: ["11"]),
        fetchedAt: minuteDate.addingTimeInterval(30))
    #expect(try JSONDecoder().decode(MarketHistory.self, from: JSONEncoder().encode(history)) == history)
    let oldDaily = MarketHistory(range: .all, fetchedAt: minuteDate, candles: [])
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldDaily)) as? [String: Any])
    legacy.removeValue(forKey: "period")
    let decoded = try JSONDecoder().decode(MarketHistory.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded == oldDaily)
    #expect(decoded.period == .day)
    #expect(MarketRange.hour.startDate(today: minuteDate) == minuteDate.addingTimeInterval(-3600))
    #expect(MarketRange.day.startDate(today: minuteDate) == minuteDate.addingTimeInterval(-86_400))
}

@Test func malformedOrMislabeledMinuteResponsesCannotReplaceSuccessfulHistory() throws {
    let malformed = [
        minuteFixture(times: [minuteStart], open: ["10"], high: ["12"], low: ["8"], close: ["0"]),
        minuteFixture(times: [minuteStart], open: ["10", "20"], high: ["12"], low: ["8"], close: ["11"]),
        minuteFixture(times: [minuteStart, minuteStart], open: ["10", "10"], high: ["12", "12"], low: ["8", "8"], close: ["11", "11"]),
        minuteFixture(times: [minuteStart + 180], open: ["10"], high: ["12"], low: ["8"], close: ["11"]),
        minuteFixture(times: [minuteStart + 1, minuteStart + 60], open: ["10", "20"], high: ["12", "22"], low: ["8", "18"], close: ["11", "21"]),
        minuteFixture(times: [minuteStart], open: ["10"], high: ["12"], low: ["8"], close: ["11"], currency: "CNY"),
        minuteFixture(times: [minuteStart], open: ["10"], high: ["12"], low: ["8"], close: ["11"], granularity: "1d")]
    for data in malformed {
        #expect(throws: MarketHistoryError.invalidResponse) {
            try MarketHistoryClient.decodeYahooMinutes(data: data, fetchedAt: minuteDate.addingTimeInterval(120))
        }
    }
    #expect(throws: MarketHistoryError.emptyHistory) {
        try MarketHistoryClient.decodeYahooMinutes(data: minuteFixture(times: [minuteStart],
            open: ["null"], high: ["null"], low: ["null"], close: ["null"]), fetchedAt: minuteDate.addingTimeInterval(60))
    }
    #expect(throws: MarketHistoryError.emptyHistory) {
        try MarketHistoryClient.decodeYahooMinutes(data: minuteFixture(times: [minuteStart],
            open: ["10"], high: ["12"], low: ["8"], close: ["11"]), fetchedAt: minuteDate)
    }
}

@Test func minuteResponseLimitsBoundMemoryAndRows() throws {
    let count = 16_000
    let times = (0..<count).map { minuteStart + Int64($0) * 60 }
    let prices = Array(repeating: "11", count: count)
    let data = minuteFixture(times: times, open: prices, high: prices, low: prices, close: prices)
    let fetchedAt = minuteDate.addingTimeInterval(Double(count) * 60)
    #expect(try MarketHistoryClient.decodeYahooMinutes(data: data, fetchedAt: fetchedAt).candles.count == count)
    let oversized = minuteFixture(times: times + [minuteStart + Int64(count) * 60],
        open: prices + ["11"], high: prices + ["11"], low: prices + ["11"], close: prices + ["11"])
    #expect(throws: MarketHistoryError.invalidResponse) {
        try MarketHistoryClient.decodeYahooMinutes(data: oversized, fetchedAt: fetchedAt.addingTimeInterval(60))
    }
    let excessiveBytes = data + Data(repeating: 32, count: max(0, 4_000_001 - data.count))
    #expect(throws: MarketHistoryError.invalidResponse) {
        try MarketHistoryClient.decodeYahooMinutes(data: excessiveBytes, fetchedAt: fetchedAt)
    }
}

@Test func minuteEndpointUsesPublicUSDAndAnAlignedSevenDayWindow() throws {
    let date = minuteDate.addingTimeInterval(37)
    let endpoint = MarketHistoryClient.yahooMinutesEndpoint(through: date)
    #expect(endpoint.host == "query1.finance.yahoo.com")
    #expect(endpoint.path == "/v8/finance/chart/BTC-USD")
    #expect(endpoint.query == "interval=1m&period1=1790294400&period2=1790899238")
}
