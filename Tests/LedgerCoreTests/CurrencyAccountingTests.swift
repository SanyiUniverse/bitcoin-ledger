import Foundation
import Testing
@testable import LedgerCore

private let currencyDay = Date(timeIntervalSince1970: 1_790_812_800)

private func dollarPurchase(cny: Decimal, rate: Decimal, sats: Int64 = 100_000_000,
                            date: Date = currencyDay.addingTimeInterval(86_400 + 12_345)) throws -> LedgerEntry {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let fx = USDExchangeRate(date: calendar.startOfDay(for: date).addingTimeInterval(-86_400),
                             cnyPerUSD: rate, source: "Synthetic daily reference")
    return LedgerEntry(date: date, kind: .buy, toAccountID: Account.defaults[0].id,
        receivedSats: sats, amountCNY: cny, conversion: try .make(amountCNY: cny, rate: fx))
}

@Test func dollarInvestmentAddsEachHistoricalConversionAndIncludesTransferLoss() throws {
    let first = try dollarPurchase(cny: 700, rate: 7)
    let second = try dollarPurchase(cny: 800, rate: 8, date: first.date.addingTimeInterval(1))
    let transfer = LedgerEntry(date: first.date.addingTimeInterval(2), kind: .transfer,
        fromAccountID: Account.defaults[0].id, toAccountID: Account.defaults[1].id,
        amountSats: 100_000_000, receivedSats: 90_000_000)
    let entries = [transfer, second, first]
    let prior = try LedgerEngine.calculate(accounts: Account.defaults, entries: entries, asOf: second.date)
    #expect(prior.totalInvestedUSD == 200)
    #expect(prior.averageCostUSD == 100)
    let after = try LedgerEngine.calculate(accounts: Account.defaults, entries: entries)
    #expect(after.totalInvestedUSD == 200)
    #expect(after.totalPurchasedSats == 200_000_000)
    #expect(after.totalLossSats == 10_000_000)
    #expect(after.totalSats == 190_000_000)
    #expect(after.balances.values.reduce(0, +) == after.totalSats)
    #expect(after.averageCostUSD == Amounts.rounded(200 / Decimal(string: "1.9")!))
    #expect(after.value(price: 120) == 228)
    #expect(after.profit(price: 120) == 28)
    #expect(after.profitRatio(price: 120) == Decimal(string: "0.14"))
}

@Test func missingHistoricalRatePreservesBTCAndDoesNotInventDollarCost() throws {
    var first = try dollarPurchase(cny: 700, rate: 7)
    first.conversion = nil
    let second = try dollarPurchase(cny: 800, rate: 8, date: first.date.addingTimeInterval(1))
    let snapshot = try LedgerEngine.calculate(accounts: Account.defaults, entries: [first, second])
    #expect(snapshot.totalSats == 200_000_000)
    #expect(snapshot.totalInvestedUSD == nil)
    #expect(snapshot.averageCostUSD == nil)
    #expect(snapshot.profit(price: 120) == nil)
    #expect(snapshot.profitRatio(price: 120) == nil)
    #expect(snapshot.value(price: 120) == 240)
}

@Test func purchaseConversionUsesDecimalAndPersistsReferenceAndSecondsExactly() throws {
    let entry = try dollarPurchase(cny: Decimal(string: "101.23")!, rate: Decimal(string: "7.12345678")!)
    #expect(entry.amountUSD == Amounts.rounded(Decimal(string: "101.23")! / Decimal(string: "7.12345678")!))
    let doc = BackupDocument(accounts: Account.defaults, entries: [entry])
    let bytes = try BackupCodec.encode(doc)
    let restored = try BackupCodec.decode(bytes)
    #expect(restored.entries == [entry])
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let rows = try #require(object["entries"] as? [[String: Any]])
    let conversion = try #require(rows[0]["conversion"] as? [String: Any])
    #expect(conversion["amountUSD"] as? String == Amounts.string(try #require(entry.amountUSD)))
    let rate = try #require(conversion["rate"] as? [String: Any])
    #expect(rate["cnyPerUSD"] as? String == "7.12345678")
    let before = try LedgerEngine.calculate(accounts: Account.defaults, entries: [entry], asOf: entry.date.addingTimeInterval(-1))
    #expect(before.totalSats == 0)
    let at = try LedgerEngine.calculate(accounts: Account.defaults, entries: [entry], asOf: entry.date)
    #expect(at.totalSats == entry.receivedSats)
}

@Test func conversionRejectsChangedCashFutureStaleAndInvalidReferences() throws {
    let valid = try dollarPurchase(cny: 700, rate: 7)
    var altered = valid
    altered.amountCNY = 701
    #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: Account.defaults, entries: [altered]) }
    altered = valid
    altered.conversion?.rate.date = currencyDay.addingTimeInterval(2 * 86_400)
    #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: Account.defaults, entries: [altered]) }
    altered = valid
    altered.conversion?.rate.date = currencyDay.addingTimeInterval(-8 * 86_400)
    #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: Account.defaults, entries: [altered]) }
    altered = valid
    altered.conversion?.rate.date = currencyDay.addingTimeInterval(1)
    #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: Account.defaults, entries: [altered]) }
    altered = valid
    altered.conversion?.rate.source = " "
    #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: Account.defaults, entries: [altered]) }
    #expect(throws: LedgerError.self) { try PurchaseConversion.make(amountCNY: 1, rate: USDExchangeRate(date: currencyDay, cnyPerUSD: 0, source: "test")) }
    #expect(throws: LedgerError.self) { try PurchaseConversion.make(amountCNY: 1, rate: USDExchangeRate(date: currencyDay, cnyPerUSD: Decimal(string: "7.1234567890123")!, source: "test")) }
}

func previousCNYOnlyBytes() throws -> Data {
    var entry = try dollarPurchase(cny: 700, rate: 7)
    entry.conversion = nil
    let current = try BackupCodec.encode(BackupDocument(accounts: Account.defaults, entries: [entry]))
    var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
    object["schemaVersion"] = 4
    object["baseCurrency"] = "CNY"
    object["accountingPolicy"] = "cny-invested-net-btc-v1"
    object["lastPrice"] = ["priceCNY": "700000", "fetchedAt": entry.date.timeIntervalSince1970 * 1000, "source": "Old CNY quote"]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

@Test func schemaFourMigrationKeepsOriginalInputsAndDropsCNYQuote() throws {
    let original = try previousCNYOnlyBytes()
    let old = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    let oldRows = try #require(old["entries"] as? [[String: Any]])
    let converted = try BackupCodec.decode(original)
    #expect(converted.schemaVersion == 5)
    #expect(converted.baseCurrency == "USD")
    #expect(converted.lastPrice == nil)
    #expect(converted.accounts == Account.defaults)
    #expect(converted.entries.count == 1)
    #expect(converted.entries[0].id.uuidString == oldRows[0]["id"] as? String)
    #expect(converted.entries[0].amountCNY == 700)
    #expect(converted.entries[0].receivedSats == 100_000_000)
    #expect(converted.entries[0].conversion == nil)
}

@Test func schemaFourNeverTrustsDollarConversionFieldsFromAnUnknownSchema() throws {
    let entry = try dollarPurchase(cny: 700, rate: 7)
    let bytes = try BackupCodec.encode(BackupDocument(accounts: Account.defaults, entries: [entry]))
    var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    old["schemaVersion"] = 4
    old["baseCurrency"] = "CNY"
    old["accountingPolicy"] = "cny-invested-net-btc-v1"
    let restored = try BackupCodec.decode(JSONSerialization.data(withJSONObject: old))
    #expect(restored.entries[0].amountCNY == 700)
    #expect(restored.entries[0].receivedSats == entry.receivedSats)
    #expect(restored.entries[0].conversion == nil)
    #expect(try LedgerEngine.calculate(accounts: restored.accounts, entries: restored.entries).totalInvestedUSD == nil)
}

@Test @MainActor func schemaFourFirstSaveKeepsRawBackupAcrossCurrencyCompletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("USD-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("ledger.json")
    let original = try previousCNYOnlyBytes()
    try original.write(to: url)
    let repo = try LedgerRepository(url: url)
    var migrated = try repo.load()
    #expect(try Data(contentsOf: url) == original)
    try repo.save(migrated)
    migrated.entries[0].conversion = try PurchaseConversion.make(amountCNY: 700,
        rate: USDExchangeRate(date: currencyDay, cnyPerUSD: 7, source: "Synthetic daily reference"))
    try repo.save(migrated)
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("ledger.before-upgrade-v4-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
    #expect(try repo.load().entries[0].amountUSD == 100)
}
