import Foundation
import Testing
@testable import LedgerCore

private let backupTestDate = Date(timeIntervalSince1970: 1_790_830_000)

@Test func priceDecodesDecimalDirectlyAndUsesFetchTime() throws {
    let json = Data(#"{"CNY":{"last":564693.92,"15m":1},"USD":{"last":1}}"#.utf8)
    let quote = try PriceClient.decode(data: json, fetchedAt: backupTestDate)
    #expect(quote.priceCNY == Decimal(string: "564693.92")!)
    #expect(quote.fetchedAt == backupTestDate)
    #expect(quote.source == "Blockchain.com")
}

@Test func priceRejectsMissingMalformedAndNonpositiveData() {
    for value in [#"{}"#, #"{"CNY":{"last":null}}"#, #"{"CNY":{"last":"oops"}}"#,
                  #"{"CNY":{"last":0}}"#, #"{"CNY":{"last":-1}}"#, #"{"CNY":{"last":1000000000001}}"#] {
        #expect(throws: (any Error).self) { try PriceClient.decode(data: Data(value.utf8)) }
    }
}

@Test func priceQuoteJSONUsesDecimalString() throws {
    let quote = PriceQuote(priceCNY: Decimal(string: "0.123456789123456789")!, fetchedAt: backupTestDate)
    let data = try JSONEncoder().encode(quote)
    #expect(String(decoding: data, as: UTF8.self).contains("\"0.123456789123456789\""))
    #expect(try JSONDecoder().decode(PriceQuote.self, from: data) == quote)
}

@Test func priceQuoteRejectsMoreSignificantDigitsThanDecimalCanPreserve() {
    let data = Data(#"{"priceCNY":"1.12345678901234567890123456789012345678","fetchedAt":0,"source":"x"}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(PriceQuote.self, from: data) }
}

private final class UnavailablePriceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"CNY":{"last":100}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func priceRejectsHTTPErrorEvenWithValidLookingBody() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UnavailablePriceProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = PriceClient(session: session)
    await #expect(throws: PriceError.httpStatus(503)) { try await client.fetch() }
}

private final class OfflinePriceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

@Test func pricePropagatesOfflineFailureForCachePreservation() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflinePriceProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = PriceClient(session: session)
    do {
        _ = try await client.fetch()
        Issue.record("Offline request unexpectedly succeeded")
    } catch let error as URLError {
        #expect(error.code == .notConnectedToInternet)
    }
}
