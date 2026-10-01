import Foundation
import Testing
@testable import LedgerCore

private let backupTestDate = Date(timeIntervalSince1970: 1_790_830_000)

private func backupFixture() -> BackupDocument {
    let account = Account(name: "个人交易所", kind: .exchange)
    let entry = LedgerEntry(date: backupTestDate, sequence: 0, kind: .buy,
                            toAccountID: account.id, amountSats: 15_324,
                            amountCNY: 100, feeCurrency: .btc, feeSats: 1,
                            feePriceCNY: 650_000, feeCategory: .trading, note: "合成数据")
    return BackupDocument(exportedAt: backupTestDate, accounts: [account], entries: [entry],
                          lastPrice: PriceQuote(priceCNY: Decimal(string: "564693.92")!, fetchedAt: backupTestDate))
}

@Test func backupRoundTripPreservesExactSatoshisDecimalAndFields() throws {
    let fixture = backupFixture()
    let data = try BackupCodec.encode(fixture)
    let restored = try BackupCodec.decode(data)
    #expect(restored == fixture)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try #require(object["entries"] as? [[String: Any]])
    #expect(entries[0]["amountCNY"] as? String == "100")
    #expect(entries[0]["feePriceCNY"] as? String == "650000")
    #expect(entries[0]["amountSats"] as? Int64 == 15_324)
    #expect(entries[0]["receivedSats"] as? Int64 == 0)
    let price = try #require(object["lastPrice"] as? [String: Any])
    #expect(price["priceCNY"] as? String == "564693.92")
}

@Test func backupRetainsFractionalTimeWithoutMillisecondTruncation() throws {
    var fixture = backupFixture()
    fixture.entries[0].date = Date(timeIntervalSince1970: 1_790_830_000.123456)
    let restored = try BackupCodec.decode(BackupCodec.encode(fixture))
    #expect(abs(restored.entries[0].date.timeIntervalSince(fixture.entries[0].date)) < 0.000001)
}

@Test func backupEmptyDocumentWorks() throws {
    let fixture = BackupDocument(exportedAt: backupTestDate)
    #expect(try BackupCodec.decode(BackupCodec.encode(fixture)) == fixture)
}

@Test func backupRejectsUnsupportedSchemaBeforeImport() throws {
    let data = try BackupCodec.encode(backupFixture())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 2
    let altered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: BackupError.unsupportedSchema(2)) { try BackupCodec.decode(altered) }
}

@Test func backupRejectsOversizeAndMalformedFiles() {
    #expect(throws: BackupError.tooLarge) {
        try BackupCodec.decode(Data(repeating: 0, count: BackupCodec.maximumBytes + 1))
    }
    #expect(throws: (any Error).self) { try BackupCodec.decode(Data("not json".utf8)) }
}

@Test func backupRejectsDuplicateIDsAndMissingAccounts() throws {
    let data = try BackupCodec.encode(backupFixture())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let accounts = try #require(object["accounts"] as? [[String: Any]])
    object["accounts"] = accounts + accounts
    let duplicate = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try BackupCodec.decode(duplicate) }
    object["accounts"] = []
    let missing = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try BackupCodec.decode(missing) }
}

@Test func backupRejectsNumericMoneyAndNoncanonicalDecimal() throws {
    let data = try BackupCodec.encode(backupFixture())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var entries = try #require(object["entries"] as? [[String: Any]])
    entries[0]["amountCNY"] = 100
    object["entries"] = entries
    let numeric = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try BackupCodec.decode(numeric) }
    entries[0]["amountCNY"] = "100malformed"
    object["entries"] = entries
    let malformed = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try BackupCodec.decode(malformed) }
}

@Test func backupRejectsInvalidCachedQuote() {
    var fixture = backupFixture()
    fixture.lastPrice?.priceCNY = 0
    #expect(throws: (any Error).self) { try BackupCodec.encode(fixture) }
}

@Test func csvPreservesSatsFeeSnapshotNamesTypesAndDate() throws {
    let data = try BackupCodec.csv(backupFixture())
    #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
    let csv = try #require(String(data: data, encoding: .utf8))
    #expect(csv.contains("fee_price_cny_per_btc,fee_cny_equivalent"))
    #expect(csv.contains("个人交易所,exchange"))
    #expect(csv.contains("15324,0.00015324"))
    #expect(csv.contains("1,0.00000001,0,650000,0.0065"))
    #expect(csv.contains(".000Z"))
    #expect(csv.hasSuffix("\r\n"))
}

@Test func csvEscapesQuotesCommaAndNewlineAndBlocksFormulas() throws {
    var fixture = backupFixture()
    fixture.accounts[0].name = "=HYPERLINK(\"example\")"
    fixture.entries[0].note = "@SUM(1,2)\r\n\"test\""
    let csv = try #require(String(data: BackupCodec.csv(fixture), encoding: .utf8))
    #expect(csv.contains("\"'=HYPERLINK(\"\"example\"\")\""))
    #expect(csv.contains("\"'@SUM(1,2)\r\n\"\"test\"\"\""))
    // Formula sanitization changes the view export only, never the JSON source.
    let restored = try BackupCodec.decode(BackupCodec.encode(fixture))
    #expect(restored.accounts[0].name == fixture.accounts[0].name)
    #expect(restored.entries[0].note == fixture.entries[0].note)
}

@Test func csvBlocksLeadingWhitespaceFormulasAndControls() throws {
    for value in [" +1", "-2", "\ttext", "\rtext", "\ntext"] {
        var fixture = backupFixture()
        fixture.entries[0].note = value
        let csv = try #require(String(data: BackupCodec.csv(fixture), encoding: .utf8))
        #expect(csv.contains("'" + value))
    }
}

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
