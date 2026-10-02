import Foundation
import Testing
@testable import LedgerCore

private let legacyTime: Double = 1_790_830_000_000
private let oldExchange = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let oldWallet = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private func legacyRecord(_ number: Int, kind: String = "buy", cny: String = "100", sats: Int64 = 10_000) -> [String: Any] {
    ["id": String(format: "20000000-0000-0000-0000-%012d", number), "date": legacyTime + Double(number * 1_000),
     "sequence": number, "kind": kind, "toAccountID": oldExchange.uuidString,
     "amountSats": sats, "receivedSats": 0, "amountCNY": cny,
     "feeCurrency": "cny", "feeSats": 0, "feeCNY": "0", "feePriceCNY": "0",
     "feeCNYEquivalent": "0", "feeCategory": "trading", "note": "合成旧记录",
     "settlementCurrency": "cny", "amountUSDT": "0", "receivedUSDT": "0", "feeUSDT": "0",
     "feeValuationSource": "manualPrice"]
}
private func funding(_ number: Int, cny: String, received: String) -> [String: Any] {
    var entry = legacyRecord(number, kind: "buyUSDT", cny: cny, sats: 0)
    entry.removeValue(forKey: "toAccountID")
    entry["receivedUSDT"] = received
    return entry
}
private func intermediateBuy(_ number: Int, debit: String, sats: Int64) -> [String: Any] {
    var entry = legacyRecord(number, cny: "0", sats: sats)
    entry["settlementCurrency"] = "usdt"
    entry["amountUSDT"] = debit
    return entry
}
private func legacyBytes(version: Int = 3, entries: [[String: Any]], accounts: [[String: Any]]? = nil) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "schemaVersion": version, "baseCurrency": "CNY", "accountingPolicy": "cny-principal-moving-average-v1",
        "exportedAt": legacyTime, "accounts": accounts ?? [
            ["id": oldExchange.uuidString, "name": "OKX", "kind": "exchange", "isArchived": false],
            ["id": oldWallet.uuidString, "name": "个人冷钱包", "kind": "selfCustody", "isArchived": false]
        ], "entries": entries
    ], options: [.sortedKeys])
}

func legacyV1Bytes() -> Data {
    var entry = legacyRecord(1, cny: "70000", sats: 100_000_000)
    for key in ["settlementCurrency", "amountUSDT", "receivedUSDT", "feeUSDT", "feeValuationSource"] { entry.removeValue(forKey: key) }
    return try! legacyBytes(version: 1, entries: [entry])
}
func legacyV2Bytes() -> Data { try! legacyBytes(version: 2, entries: [legacyRecord(1)]) }

@Test func migrationV1RetainsCashNetBTCDateIDAndAccountIDs() throws {
    let document = try BackupCodec.decode(legacyV1Bytes())
    #expect(document.schemaVersion == 4)
    #expect(document.accounts.map(\.id) == [oldExchange, oldWallet])
    #expect(document.accounts.map(\.name) == ["欧易", "自有钱包"])
    #expect(document.entries[0].date == Date(timeIntervalSince1970: (legacyTime + 1_000) / 1_000))
    #expect(document.entries[0].receivedSats == 100_000_000)
    #expect(document.entries[0].amountCNY == 70_000)
    #expect(document.migrationReport?.issues.isEmpty == true)
    #expect(try BackupCodec.decode(BackupCodec.encode(document)) == document)
}
@Test func migrationUsesActualNetBTCWithoutDeductingLegacyBTCFeeAgain() throws {
    var entry = legacyRecord(1, cny: "500", sats: 99_800)
    entry["feeCurrency"] = "btc"
    entry["feeSats"] = 200
    entry["feePriceCNY"] = "500000"
    entry["feeCNYEquivalent"] = "1"
    let document = try BackupCodec.decode(legacyBytes(entries: [entry]))
    let snapshot = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
    #expect(snapshot.totalPurchasedSats == 99_800)
    #expect(snapshot.totalSats == 99_800)
    #expect(snapshot.totalLossSats == 0)
    #expect(snapshot.totalInvestedCNY == 500)
}
@Test func migrationCNYBuyIncludesActuallyPaidCNYFee() throws {
    var entry = legacyRecord(1, cny: "500.01", sats: 100_000)
    entry["feeCNY"] = "2.34"
    let document = try BackupCodec.decode(legacyBytes(entries: [entry]))
    #expect(document.entries[0].amountCNY == Decimal(string: "502.35")!)
}
@Test func migrationTwoExactFundingChainsAbsorbFinalUnusedConversionAmount() throws {
    let firstFunding = funding(1, cny: "180.25", received: "25.5")
    var firstBuy = intermediateBuy(2, debit: "25.5", sats: 27_000)
    firstBuy["toAccountID"] = oldWallet.uuidString
    let secondFunding = funding(3, cny: "310.10", received: "44.75")
    let secondBuy = intermediateBuy(4, debit: "44.74999876", sats: 70_000)
    let document = try BackupCodec.decode(legacyBytes(entries: [firstFunding, firstBuy, secondFunding, secondBuy]))
    let snapshot = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
    #expect(document.entries.count == 2)
    #expect(snapshot.totalInvestedCNY == Decimal(string: "490.35")!)
    #expect(snapshot.totalPurchasedSats == 97_000)
    #expect(snapshot.totalSats == 97_000)
    #expect(snapshot.totalLossSats == 0)
    #expect(snapshot.balances[oldExchange] == 70_000)
    #expect(snapshot.balances[oldWallet] == 27_000)
    let report = try #require(document.migrationReport)
    #expect(report.issues.isEmpty)
    #expect(report.sourceEntryCount == 4)
    #expect(report.migratedCount == 2)
    #expect(report.mappings[0].sourceEntryIDs.count == 2)
    #expect(report.mappings[0].sourceDates == [Date(timeIntervalSince1970: (legacyTime + 1_000) / 1_000), document.entries[0].date])
    #expect(report.mappings[0].targetEntryID == document.entries[0].id)
    #expect(document.entries[0].id.uuidString == firstBuy["id"] as? String)
    let cleanData = try BackupCodec.encode(document)
    let object = try #require(JSONSerialization.jsonObject(with: cleanData) as? [String: Any])
    let events = try #require(object["entries"] as? [[String: Any]])
    #expect(!events[0].keys.contains("amountUSDT"))
    #expect(!events[0].keys.contains("feeCurrency"))
    #expect(object["entryValuations"] == nil)
}
@Test func migrationFinalIsolatedFundingKeepsFullCashAsRequestedConversionCost() throws {
    let document = try BackupCodec.decode(legacyBytes(entries: [funding(1, cny: "500", received: "100"),
                                                             intermediateBuy(2, debit: "70", sats: 100_000)]))
    #expect(document.entries.count == 1)
    #expect(document.entries[0].amountCNY == 500)
    #expect(document.migrationReport?.issues.isEmpty == true)
}
@Test func migrationFundingFeeIsAlreadyInTotalPaymentAndBTCTradeCNYFeeIsExtra() throws {
    var deposit = funding(1, cny: "500", received: "70")
    deposit["feeCNY"] = "5"
    var purchase = intermediateBuy(2, debit: "70", sats: 100_000)
    purchase["feeCNY"] = "2"
    let document = try BackupCodec.decode(legacyBytes(entries: [deposit, purchase]))
    #expect(document.entries[0].amountCNY == 502)
}
@Test func migrationNeverAllocatesIntermediatePartialFundingToMultiplePurchases() throws {
    let records = [funding(1, cny: "500", received: "100"), intermediateBuy(2, debit: "70", sats: 100_000),
                   funding(3, cny: "200", received: "30"), intermediateBuy(4, debit: "30", sats: 50_000)]
    let document = try BackupCodec.decode(legacyBytes(entries: records))
    #expect(document.entries.isEmpty)
    #expect(document.migrationReport?.issues.count == 4)
}
@Test func migrationMultipleFundingSourcesRemainUnresolved() throws {
    let records = [funding(1, cny: "100", received: "10"), funding(2, cny: "200", received: "20"),
                   intermediateBuy(3, debit: "30", sats: 50_000)]
    let document = try BackupCodec.decode(legacyBytes(entries: records))
    #expect(document.entries.isEmpty)
    #expect(document.migrationReport?.issues.count == 3)
}
@Test func migrationAdjustmentOrSaleNeverInventsFundingAttribution() throws {
    var adjustment = legacyRecord(1, kind: "adjustUSDT", cny: "0", sats: 0)
    adjustment.removeValue(forKey: "toAccountID")
    adjustment["receivedUSDT"] = "10"
    let document = try BackupCodec.decode(legacyBytes(entries: [adjustment, funding(2, cny: "100", received: "10"),
                                                             intermediateBuy(3, debit: "10", sats: 50_000)]))
    #expect(document.entries.isEmpty)
    #expect(document.migrationReport?.issues.count == 3)
}
@Test func migrationRetainsTransfersAndTheirExactBTCQuantityLoss() throws {
    var movement = legacyRecord(2, kind: "transfer", cny: "0", sats: 100_000)
    movement["fromAccountID"] = oldExchange.uuidString
    movement["toAccountID"] = oldWallet.uuidString
    movement["receivedSats"] = 99_800
    movement["feeCurrency"] = "btc"
    movement["feeSats"] = 200
    let document = try BackupCodec.decode(legacyBytes(entries: [legacyRecord(1, sats: 100_000), movement]))
    let snapshot = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
    #expect(snapshot.totalLossSats == 200)
    #expect(snapshot.balances[oldWallet] == 99_800)
    #expect(document.entries[1].id.uuidString == movement["id"] as? String)
    #expect(document.migrationReport?.issues.isEmpty == true)
}
@Test func migrationTransferDependingOnUnresolvedBuyIsReportedWithoutNegativeBalance() throws {
    var movement = legacyRecord(2, kind: "transfer", cny: "0", sats: 50_000)
    movement["fromAccountID"] = oldExchange.uuidString
    movement["toAccountID"] = oldWallet.uuidString
    movement["receivedSats"] = 50_000
    let document = try BackupCodec.decode(legacyBytes(entries: [intermediateBuy(1, debit: "10", sats: 50_000), movement]))
    #expect(document.entries.isEmpty)
    #expect(document.migrationReport?.issues.count == 2)
}
@Test func migrationUnusableMergedCandidateReportsBothFundingAndPurchaseSources() throws {
    var purchase = intermediateBuy(2, debit: "10", sats: 50_000)
    purchase["toAccountID"] = UUID().uuidString
    let document = try BackupCodec.decode(legacyBytes(entries: [funding(1, cny: "100", received: "10"), purchase]))
    #expect(document.entries.isEmpty)
    #expect(document.migrationReport?.issues.count == 2)
    #expect(document.migrationReport?.mappings.isEmpty == true)
}
@Test func migrationPreservesNecessaryAdditionalAccountsAndNames() throws {
    let thirdID = UUID()
    let originalAccounts: [[String: Any]] = [
        ["id": oldExchange.uuidString, "name": "OKX", "kind": "exchange"],
        ["id": oldWallet.uuidString, "name": "历史钱包一", "kind": "selfCustody"],
        ["id": thirdID.uuidString, "name": "历史钱包二", "kind": "selfCustody"]
    ]
    var purchase = legacyRecord(1)
    purchase["toAccountID"] = thirdID.uuidString
    let document = try BackupCodec.decode(legacyBytes(entries: [purchase], accounts: originalAccounts))
    #expect(document.accounts.contains(Account(id: thirdID, name: "历史钱包二")))
    #expect(document.accounts.contains(Account(id: oldWallet, name: "历史钱包一")))
    #expect(document.entries[0].toAccountID == thirdID)
}
@Test func migrationMissingV2SemanticsFailsSafelyRatherThanAssumingCNY() throws {
    var entry = legacyRecord(1)
    entry.removeValue(forKey: "settlementCurrency")
    #expect(throws: (any Error).self) { try BackupCodec.decode(legacyBytes(version: 2, entries: [entry])) }
}
@Test func migrationUnknownOldEventsStayInReportWithoutNewRuntimeKinds() throws {
    let document = try BackupCodec.decode(legacyBytes(entries: [legacyRecord(1), legacyRecord(2, kind: "sell")]))
    #expect(document.entries.count == 1)
    #expect(document.migrationReport?.issues.count == 1)
    #expect(document.migrationReport?.issues[0].kind == "sell")
}
