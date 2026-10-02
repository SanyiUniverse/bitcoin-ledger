import Foundation
import Testing
@testable import LedgerCore

private func backupFixture() -> BackupDocument {
    let account = Account.defaults[0]
    let date = Date(timeIntervalSince1970: 1_790_830_000.123456)
    let entry = syntheticEntry(date: date, kind: .buy, toAccountID: account.id,
                            receivedSats: 15_324, amountCNY: Decimal(string: "100.01")!, note: "合成数据")
    return BackupDocument(exportedAt: date, accounts: Account.defaults, entries: [entry],
        lastPrice: PriceQuote(priceUSD: Decimal(string: "564693.92")!, fetchedAt: date))
}

@Test func backupRoundTripRetainsExactMoneySatoshisAndTime() throws {
    let fixture = backupFixture()
    let data = try BackupCodec.encode(fixture)
    let restored = try BackupCodec.decode(data)
    #expect(restored == fixture)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try #require(object["entries"] as? [[String: Any]])
    #expect(entries[0]["amountCNY"] as? String == "100.01")
    #expect(entries[0]["receivedSats"] as? Int64 == 15_324)
    #expect(Set(entries[0].keys) == Set(["id", "date", "sequence", "kind", "toAccountID", "amountSats", "receivedSats", "amountCNY", "conversion", "note"]))
    #expect(abs(restored.entries[0].date.timeIntervalSince(fixture.entries[0].date)) < 0.000001)
}
@Test func backupSeedsTwoAccountsAndNoOtherAssets() throws {
    let document = BackupDocument(exportedAt: Date(timeIntervalSince1970: 1_000))
    #expect(document.accounts.map(\.name) == ["欧易", "自有钱包"])
    #expect(EntryKind.allCases == [.buy, .transfer])
    #expect(try BackupCodec.decode(BackupCodec.encode(document)) == document)
}
@Test func backupRejectsFutureVersionBeforeReadingFutureBody() {
    #expect(throws: BackupError.unsupportedSchema(6)) {
        try BackupCodec.decode(Data(#"{"schemaVersion":6,"baseCurrency":{"future":"body"}}"#.utf8))
    }
}
@Test func backupRejectsOversizeAndMalformedFiles() {
    #expect(throws: BackupError.tooLarge) { try BackupCodec.decode(Data(repeating: 0, count: BackupCodec.maximumBytes + 1)) }
    #expect(throws: (any Error).self) { try BackupCodec.decode(Data("not json".utf8)) }
}
@Test func backupRejectsNumericMoneyAndUnknownEvent() throws {
    let object = try #require(JSONSerialization.jsonObject(with: BackupCodec.encode(backupFixture())) as? [String: Any])
    for (key, value) in [("amountCNY", 100 as Any), ("amountCNY", "100malformed"), ("kind", "sell")] {
        var altered = object
        var entries = try #require(altered["entries"] as? [[String: Any]])
        entries[0][key] = value
        altered["entries"] = entries
        #expect(throws: (any Error).self) { try BackupCodec.decode(JSONSerialization.data(withJSONObject: altered)) }
    }
}
@Test func backupRejectsDuplicateIDsMissingAccountsAndInvalidQuote() throws {
    var document = backupFixture()
    document.accounts += [document.accounts[0]]
    #expect(throws: (any Error).self) { try BackupCodec.encode(document) }
    document = backupFixture()
    document.accounts = []
    #expect(throws: (any Error).self) { try BackupCodec.encode(document) }
    document = backupFixture()
    document.lastPrice?.priceUSD = 0
    #expect(throws: (any Error).self) { try BackupCodec.encode(document) }
}
@Test func backupRejectsUnknownAccountingPolicy() {
    #expect(throws: BackupError.unsupportedAccountingPolicy("unknown-method")) {
        try BackupCodec.decode(Data(#"{"schemaVersion":3,"baseCurrency":"CNY","accountingPolicy":"unknown-method"}"#.utf8))
    }
}
@Test func csvContainsOnlyPurchaseAndTransferFields() throws {
    let data = try BackupCodec.csv(backupFixture())
    #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
    let csv = try #require(String(data: data, encoding: .utf8))
    #expect(csv.contains("15324,0.00015324,15324,0.00015324,100.01,100.01,1"))
    #expect(csv.contains("amount_usd,cny_per_usd,fx_date_utc,fx_source,loss_sats,loss_btc,note"))
    #expect(!csv.lowercased().contains("usdt"))
    #expect(!csv.lowercased().contains("fee_"))
    #expect(csv.hasSuffix("\r\n"))
}
@Test func csvEscapesTextAndPreventsSpreadsheetFormulas() throws {
    var document = backupFixture()
    document.accounts[0].name = "=HYPERLINK(\"example\")"
    document.entries[0].note = "@SUM(1,2)\r\n\"test\""
    let csv = try #require(String(data: BackupCodec.csv(document), encoding: .utf8))
    #expect(csv.contains("\"'=HYPERLINK(\"\"example\"\")\""))
    #expect(csv.contains("\"'@SUM(1,2)\r\n\"\"test\"\"\""))
    #expect(try BackupCodec.decode(BackupCodec.encode(document)) == document)
}
