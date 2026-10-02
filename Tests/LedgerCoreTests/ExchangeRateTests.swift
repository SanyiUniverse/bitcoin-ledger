import Foundation
import Testing
@testable import LedgerCore

private func fxDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func fxFixture(_ rows: [(String, String)]) -> Data {
    Data("[\(rows.map { "{\"date\":\"\($0.0)\",\"base\":\"USD\",\"quote\":\"CNY\",\"rate\":\($0.1)}" }.joined(separator: ","))]".utf8)
}

@Test func purchaseRateUsesOnlyPublishedPriorDayAndPreservesExactDecimal() throws {
    let data = fxFixture([("2026-09-20", "7.123456789123"), ("2026-09-21", "99")])
    let asOf = fxDate("2026-09-21T08:30:00Z")
    let rate = try ExchangeRateClient.decode(data: data, asOf: asOf)
    #expect(rate.date == fxDate("2026-09-20T00:00:00Z"))
    #expect(rate.availableAt == fxDate("2026-09-21T00:00:00Z") && rate.availableAt <= asOf)
    #expect(rate.cnyPerUSD == Decimal(string: "7.123456789123"))
    #expect(rate.source.contains("ECB") && rate.source.contains("每日参考"))
    #expect(try JSONDecoder().decode(USDExchangeRate.self, from: JSONEncoder().encode(rate)) == rate)
}

@Test func weekendAndShanghaiPurchaseTimeUseLatestAvailableReferenceDay() throws {
    let data = fxFixture([("2026-09-17", "7"), ("2026-09-18", "7.1"), ("2026-09-21", "8")])
    // Monday 00:30 in Shanghai is still Sunday UTC; Friday remains the latest rate.
    let asOf = fxDate("2026-09-20T16:30:00Z")
    let rate = try ExchangeRateClient.decode(data: data, asOf: asOf)
    #expect(rate.date == fxDate("2026-09-18T00:00:00Z"))
    #expect(rate.cnyPerUSD == Decimal(string: "7.1"))
    #expect(rate.availableAt <= asOf)
}

@Test func higherPrecisionProviderRateIsRoundedToPersistableTwelvePlaces() throws {
    let rate = try ExchangeRateClient.decode(data: fxFixture([("2026-09-20", "7.1234567891236")]),
        asOf: fxDate("2026-09-21T00:00:00Z"))
    #expect(rate.cnyPerUSD == Decimal(string: "7.123456789124"))
    #expect(try JSONDecoder().decode(USDExchangeRate.self, from: JSONEncoder().encode(rate)) == rate)
}

@Test func purchaseRatePublicationBoundaryAndSevenDayStalenessAreStrict() throws {
    let data = fxFixture([("2026-09-18", "7")])
    #expect(throws: ExchangeRateError.unavailable) {
        try ExchangeRateClient.decode(data: data, asOf: fxDate("2026-09-18T23:59:59Z"))
    }
    #expect(try ExchangeRateClient.decode(data: data, asOf: fxDate("2026-09-19T00:00:00Z")).cnyPerUSD == 7)
    #expect(try ExchangeRateClient.decode(data: data, asOf: fxDate("2026-09-25T00:00:00Z")).cnyPerUSD == 7)
    #expect(throws: ExchangeRateError.unavailable) {
        try ExchangeRateClient.decode(data: data, asOf: fxDate("2026-09-25T00:00:01Z"))
    }
    #expect(throws: ExchangeRateError.unavailable) {
        try ExchangeRateClient.decode(data: Data("[]".utf8), asOf: fxDate("2026-09-25T00:00:00Z"))
    }
}

@Test func malformedOrAmbiguousPurchaseRatesCannotBeSaved() {
    let invalid = [
        fxFixture([("2026-09-18", "0")]), fxFixture([("2026-09-18", "-1")]),
        fxFixture([("2026-09-18", "1000")]), fxFixture([("2026-02-30", "7")]),
        fxFixture([("2026-09-18", "7"), ("2026-09-18", "8")]),
        Data("[{\"date\":\"2026-09-18\",\"base\":\"EUR\",\"quote\":\"CNY\",\"rate\":7}]".utf8),
        Data("{}".utf8)]
    for data in invalid {
        #expect(throws: ExchangeRateError.invalidResponse) {
            try ExchangeRateClient.decode(data: data, asOf: fxDate("2026-09-21T00:00:00Z"))
        }
    }
}

private final class PurchaseFXProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let params = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            .map { ($0.name, $0.value ?? "") })
        let valid = request.url?.host == "api.frankfurter.dev" && request.url?.path == "/v2/providers/ecb/rates"
            && params == ["from": "2026-09-13", "to": "2026-09-21", "base": "USD", "quotes": "CNY"]
            && request.httpBody == nil && request.value(forHTTPHeaderField: "Authorization") == nil
            && request.value(forHTTPHeaderField: "Cookie") == nil
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 400, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fxFixture([("2026-09-18", "7")]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func purchaseFXRequestContainsOnlyPublicDatesAndFixedCurrencyPair() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PurchaseFXProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let rate = try await ExchangeRateClient(session: session).rate(asOf: fxDate("2026-09-21T08:30:00Z"))
    #expect(rate.cnyPerUSD == 7)
    let conversion = try PurchaseConversion.make(amountCNY: 500, rate: rate)
    #expect(conversion.amountUSD == Decimal(string: "71.428571428571"))
}
