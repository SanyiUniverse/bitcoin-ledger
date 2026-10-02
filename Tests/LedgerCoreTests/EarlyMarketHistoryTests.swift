import Foundation
import Testing
@testable import LedgerCore

private func earlyDate(_ day: String) -> Date {
    ISO8601DateFormatter().date(from: "\(day)T00:00:00Z")!
}

@Test func earlyUSDClosesRemainExactAndBecomeAvailableAtActualClose() throws {
    let prices = Data("""
    {"data":[
      {"asset":"btc","time":"2010-07-18T00:00:00.000000000Z","PriceUSD":"0.08584"},
      {"asset":"btc","time":"2010-07-19T00:00:00.000000000Z","PriceUSD":"0.0808"},
      {"asset":"btc","time":"2010-07-20T00:00:00.000000000Z","PriceUSD":"0.09"}
    ]}
    """.utf8)
    let candles = try EarlyMarketHistoryClient.decode(priceData: prices, cutoff: earlyDate("2010-07-20"))
    #expect(candles.count == 2)
    #expect(candles[0].startDate == earlyDate("2010-07-18"))
    #expect(candles[0].closeDate == earlyDate("2010-07-19"))
    #expect(candles.map(\.close) == [Decimal(string: "0.08584")!, Decimal(string: "0.0808")!])
    #expect(candles.allSatisfy { !$0.hasOHLC })
    let history = MarketHistory(range: .all, fetchedAt: earlyDate("2010-07-20"), candles: candles)
    #expect(history.latestClose(asOf: earlyDate("2010-07-18").addingTimeInterval(43_200)) == nil)
    #expect(history.latestClose(asOf: earlyDate("2010-07-19")) == candles[0])
}

@Test func missingMarketDaysAreNeverFilledWithInventedPrices() throws {
    let prices = Data("""
    {"data":[
      {"asset":"btc","time":"2010-07-18T00:00:00.000000000Z","PriceUSD":"1"},
      {"asset":"btc","time":"2010-07-19T00:00:00.000000000Z","PriceUSD":null},
      {"asset":"btc","time":"2010-07-20T00:00:00.000000000Z","PriceUSD":"2"}
    ]}
    """.utf8)
    let candles = try EarlyMarketHistoryClient.decode(priceData: prices, cutoff: earlyDate("2010-07-21"))
    #expect(candles.map(\.startDate) == [earlyDate("2010-07-18"), earlyDate("2010-07-20")])
    #expect(candles.map(\.close) == [1, 2])
}

@Test func futureDailyCloseNeverLeaksIntoHistoricalUSDState() {
    let prices = Data("""
    {"data":[{"asset":"btc","time":"2010-07-18T00:00:00.000000000Z","PriceUSD":"1"}]}
    """.utf8)
    #expect(throws: MarketHistoryError.emptyHistory) {
        try EarlyMarketHistoryClient.decode(priceData: prices, cutoff: earlyDate("2010-07-18").addingTimeInterval(86_399))
    }
}

@Test func truncatedOrMalformedReferenceDataCannotReplaceCachedHistory() {
    let invalid = [
        "{\"data\":[],\"next_page_url\":\"https://example.invalid/next\"}",
        "{\"data\":[{\"asset\":\"eth\",\"time\":\"2010-07-18T00:00:00.000000000Z\",\"PriceUSD\":\"1\"}]}",
        "{\"data\":[{\"asset\":\"btc\",\"time\":\"2010-07-18T12:00:00.000000000Z\",\"PriceUSD\":\"1\"}]}",
        "{\"data\":[{\"asset\":\"btc\",\"time\":\"2010-07-18T00:00:00.000000000Z\",\"PriceUSD\":\"-1\"}]}"
    ]
    for data in invalid {
        #expect(throws: (any Error).self) {
            try EarlyMarketHistoryClient.decode(priceData: Data(data.utf8), cutoff: earlyDate("2010-07-20"))
        }
    }
}
