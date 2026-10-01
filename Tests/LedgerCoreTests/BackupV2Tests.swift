import Foundation
import Testing
@testable import LedgerCore

/// Literal pre-v2 JSON: no archive flag, settlement currency, USDT fields,
/// valuation source, base currency, accounting policy, or replay projections.
func legacyV1Bytes() -> Data {
    Data(#"""
    {
      "schemaVersion": 1,
      "exportedAt": 1790830000000,
      "accounts": [{"id":"00000000-0000-0000-0000-000000000001","name":"旧版合成账户","kind":"exchange"}],
      "entries": [{
        "id":"00000000-0000-0000-0000-000000000002",
        "date":1790830000000,"sequence":1,"kind":"buy",
        "toAccountID":"00000000-0000-0000-0000-000000000001",
        "amountSats":100000000,"receivedSats":0,"amountCNY":"70000",
        "feeCurrency":"btc","feeSats":1000,"feeCNY":"0",
        "feePriceCNY":"70000","feeCNYEquivalent":"0.7",
        "feeCategory":"trading","note":"原始 v1 字节应完整保留"}
      ]
    }
    """#.utf8)
}

private func v2USDTFixture() -> BackupDocument {
    let account = Account(name: "USDT 合成测试账户", kind: .exchange)
    let date = Date(timeIntervalSince1970: 1_790_830_000)
    let deposit = LedgerEntry(date: date, sequence: 1, kind: .buyUSDT,
                              amountCNY: 7_000, receivedUSDT: 1_000)
    let buy = LedgerEntry(date: date.addingTimeInterval(1), sequence: 2, kind: .buy,
                          toAccountID: account.id, amountSats: 1_000_000,
                          feeCurrency: .usdt, settlementCurrency: .usdt,
                          amountUSDT: 801, feeUSDT: 1, feeValuationSource: .costBasis)
    return BackupDocument(exportedAt: date, accounts: [account], entries: [deposit, buy])
}

@Test func literalV1BackupUpgradesWithoutInventingUSDTOrRevaluingLegacyFees() throws {
    let upgraded = try BackupCodec.decode(legacyV1Bytes())
    #expect(upgraded.schemaVersion == 2)
    #expect(upgraded.baseCurrency == "CNY")
    #expect(upgraded.accountingPolicy == BackupDocument.supportedAccountingPolicy)
    #expect(upgraded.accounts[0].isArchived == false)
    #expect(upgraded.entries[0].settlementCurrency == .cny)
    #expect(upgraded.entries[0].amountUSDT == 0)
    #expect(upgraded.entries[0].receivedUSDT == 0)
    #expect(upgraded.entries[0].feeUSDT == 0)
    #expect(upgraded.entries[0].feeValuationSource == .manualPrice)
    let state = try LedgerEngine.calculate(accounts: upgraded.accounts, entries: upgraded.entries)
    #expect(state.totalSats == 100_000_000)
    #expect(state.usdtBalance == 0)
    #expect(state.totalFeeCNY == Decimal(string: "0.7")!)
    #expect(try BackupCodec.schemaVersion(in: BackupCodec.encode(upgraded)) == 2)
}

@Test func unknownSchemaAndPolicyAreRejectedBeforeUnknownBodyDecoding() {
    #expect(throws: BackupError.unsupportedSchema(3)) {
        try BackupCodec.decode(Data(#"{"schemaVersion":3,"accounts":"future format","baseCurrency":{"future":"object"}}"#.utf8))
    }
    #expect(throws: BackupError.unsupportedAccountingPolicy("market-value-reset")) {
        try BackupCodec.decode(Data(#"{"schemaVersion":2,"baseCurrency":"CNY","accountingPolicy":"market-value-reset","entries":"future format"}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        try BackupCodec.decode(Data(#"{"schemaVersion":2,"baseCurrency":"USD","accountingPolicy":"cny-principal-moving-average-v1"}"#.utf8))
    }
}

@Test func v2RequiresExplicitSettlementAndFeeSemanticsEvenForLegacyCNYEntries() throws {
    let upgraded = try BackupCodec.decode(legacyV1Bytes())
    let data = try BackupCodec.encode(upgraded)
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["settlementCurrency", "amountUSDT", "receivedUSDT", "feeUSDT", "feeValuationSource"] {
        var object = original
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: key)
        object["entries"] = entries
        let altered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try BackupCodec.decode(altered) }
    }
}

@Test func v2BackupContainsOriginalUSDTValuesAndReplayValuationsAsDecimalStrings() throws {
    let document = v2USDTFixture()
    let data = try BackupCodec.encode(document)
    #expect(try BackupCodec.decode(data) == document)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try #require(object["entries"] as? [[String: Any]])
    #expect(object["baseCurrency"] as? String == "CNY")
    #expect(entries[0]["receivedUSDT"] as? String == "1000")
    #expect(entries[1]["amountUSDT"] as? String == "801")
    #expect(entries[1]["feeUSDT"] as? String == "1")
    #expect(entries[1]["feeValuationSource"] as? String == "costBasis")
    let valuations = try #require(object["entryValuations"] as? [String: [String: Any]])
    let buy = try #require(valuations[document.entries[1].id.uuidString])
    #expect(buy["costCNY"] as? String == "5607")
    #expect(buy["feeCNYEquivalent"] as? String == "7")
    #expect(buy["feeUnitCostCNY"] as? String == "7")
}

@Test func v2BackupRejectsMissingTamperedOrNumericReplayValuations() throws {
    let document = v2USDTFixture()
    let data = try BackupCodec.encode(document)
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var missing = original
    missing.removeValue(forKey: "entryValuations")
    let missingData = try JSONSerialization.data(withJSONObject: missing)
    #expect(throws: (any Error).self) { try BackupCodec.decode(missingData) }

    for alteredValue in ["5608", 5607] as [Any] {
        var altered = original
        var valuations = try #require(altered["entryValuations"] as? [String: [String: Any]])
        valuations[document.entries[1].id.uuidString]?["costCNY"] = alteredValue
        altered["entryValuations"] = valuations
        let alteredData = try JSONSerialization.data(withJSONObject: altered)
        #expect(throws: (any Error).self) { try BackupCodec.decode(alteredData) }
    }
    var omitted = original
    var valuations = try #require(omitted["entryValuations"] as? [String: [String: Any]])
    valuations.removeValue(forKey: document.entries[0].id.uuidString)
    omitted["entryValuations"] = valuations
    let omittedData = try JSONSerialization.data(withJSONObject: omitted)
    #expect(throws: (any Error).self) { try BackupCodec.decode(omittedData) }
}

@Test func v2EncodingRecalculatesProjectionAfterHistoricalEdit() throws {
    var document = v2USDTFixture()
    document.entries[0].amountCNY = 14_000
    let data = try BackupCodec.encode(document)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let valuations = try #require(object["entryValuations"] as? [String: [String: String]])
    #expect(valuations[document.entries[1].id.uuidString]?["costCNY"] == "11214")
    #expect(valuations[document.entries[1].id.uuidString]?["feeCNYEquivalent"] == "14")
    #expect(try BackupCodec.decode(data) == document)
}

@Test func v1MarkerCannotHideUSDTEntries() throws {
    let data = try BackupCodec.encode(v2USDTFixture())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 1
    let altered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try BackupCodec.decode(altered) }
}

@Test func csvIncludesUSDTSettlementValuationBasisAndOriginalCNYCost() throws {
    let data = try BackupCodec.csv(v2USDTFixture())
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("settlement_currency,amount_usdt,received_usdt,fee_usdt,fee_valuation_source,entry_cost_cny,fee_unit_cost_cny,base_currency,accounting_policy"))
    #expect(text.contains("usdt,801,0,1,costBasis,5607,7,CNY,cny-principal-moving-average-v1"))
    #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
    #expect(text.hasSuffix("\r\n"))
}
