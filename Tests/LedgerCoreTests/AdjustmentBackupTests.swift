import Foundation
import Testing
@testable import LedgerCore

/// Literal v2 backup written before balance anchors existed. Its valuation
/// has only the original three fields, without beforeUSDT / afterUSDT.
func legacyV2Bytes() -> Data {
    Data(#"""
    {
      "schemaVersion":2,
      "baseCurrency":"CNY",
      "accountingPolicy":"cny-principal-moving-average-v1",
      "exportedAt":1790830000000,
      "accounts":[],
      "entries":[{
        "id":"00000000-0000-0000-0000-000000000003",
        "date":1790830000000,"sequence":1,"kind":"buyUSDT",
        "amountSats":0,"receivedSats":0,"amountCNY":"700",
        "feeCurrency":"cny","feeSats":0,"feeCNY":"0","feePriceCNY":"0",
        "feeCNYEquivalent":"0","feeCategory":"trading","note":"literal v2",
        "settlementCurrency":"cny","amountUSDT":"0","receivedUSDT":"100",
        "feeUSDT":"0","feeValuationSource":"manualPrice"
      }],
      "entryValuations":{
        "00000000-0000-0000-0000-000000000003":{
          "costCNY":"700","feeCNYEquivalent":"0","feeUnitCostCNY":"0"
        }
      }
    }
    """#.utf8)
}

private func adjustmentDocument(target: Decimal = 101) throws -> BackupDocument {
    var document = try BackupCodec.decode(legacyV2Bytes())
    let adjustment = LedgerEntry(date: Date(timeIntervalSince1970: 1_790_830_001), sequence: 2,
                                 kind: .adjustUSDT, feeCategory: .other, note: "手续费返还后对账",
                                 amountUSDT: 100, receivedUSDT: target)
    document.entries.append(adjustment)
    return document
}

@Test func literalV2WithoutAnchorFieldsImportsAndPreservesExistingValues() throws {
    let document = try BackupCodec.decode(legacyV2Bytes())
    #expect(document.schemaVersion == 3)
    #expect(document.entries.count == 1)
    #expect(document.entries[0].receivedUSDT == 100)
    let snapshot = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
    #expect(snapshot.usdtBalance == 100)
    #expect(snapshot.usdtCostBasisCNY == 700)
    #expect(snapshot.entryValuations[document.entries[0].id]?.beforeUSDT == nil)
    #expect(snapshot.entryValuations[document.entries[0].id]?.afterUSDT == nil)
    #expect(try BackupCodec.decode(BackupCodec.encode(document)) == document)
}

@Test func schema3AdjustmentRoundTripsRawReferenceTargetAndActualReplayBalances() throws {
    let document = try adjustmentDocument()
    let data = try BackupCodec.encode(document)
    #expect(try BackupCodec.decode(data) == document)
    #expect(try BackupCodec.schemaVersion(in: data) == 3)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try #require(object["entries"] as? [[String: Any]])
    #expect(entries[1]["amountUSDT"] as? String == "100")
    #expect(entries[1]["receivedUSDT"] as? String == "101")
    let valuations = try #require(object["entryValuations"] as? [String: [String: Any]])
    let value = try #require(valuations[document.entries[1].id.uuidString])
    #expect(value["costCNY"] as? String == "700")
    #expect(value["beforeUSDT"] as? String == "100")
    #expect(value["afterUSDT"] as? String == "101")
    #expect(valuations[document.entries[0].id.uuidString]?["beforeUSDT"] == nil)
    let snapshot = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
    #expect(snapshot.usdtBalance == 101)
    #expect(snapshot.usdtCostBasisCNY == 700)
    #expect(snapshot.investedCNY == 700)
    #expect(snapshot.returnedCNY == 0)
    #expect(snapshot.totalFeeUSDT == 0)
}

@Test func oldSchemaMarkersCannotContainBalanceAdjustments() throws {
    let data = try BackupCodec.encode(adjustmentDocument())
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for version in [1, 2] {
        var object = original
        object["schemaVersion"] = version
        let altered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try BackupCodec.decode(altered) }
    }
}

@Test func schema2StillRequiresExplicitUSDTFieldsAndProjection() throws {
    let original = try #require(JSONSerialization.jsonObject(with: legacyV2Bytes()) as? [String: Any])
    var missingProjection = original
    missingProjection.removeValue(forKey: "entryValuations")
    let missingProjectionData = try JSONSerialization.data(withJSONObject: missingProjection)
    #expect(throws: (any Error).self) { try BackupCodec.decode(missingProjectionData) }
    var missingField = original
    var entries = try #require(missingField["entries"] as? [[String: Any]])
    entries[0].removeValue(forKey: "feeValuationSource")
    missingField["entries"] = entries
    let missingFieldData = try JSONSerialization.data(withJSONObject: missingField)
    #expect(throws: (any Error).self) { try BackupCodec.decode(missingFieldData) }
}

@Test func adjustmentProjectionCannotBeMissingTamperedOrNumeric() throws {
    let document = try adjustmentDocument()
    let original = try #require(JSONSerialization.jsonObject(with: BackupCodec.encode(document)) as? [String: Any])
    for value in [NSNull(), "102", 101] as [Any] {
        var object = original
        var valuations = try #require(object["entryValuations"] as? [String: [String: Any]])
        valuations[document.entries[1].id.uuidString]?["afterUSDT"] = value
        object["entryValuations"] = valuations
        let altered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try BackupCodec.decode(altered) }
    }
}

@Test func historyEditPreservesRawReferenceButRecomputesAnchorBeforeQuantity() throws {
    var document = try adjustmentDocument()
    document.entries[0].receivedUSDT = 120
    let data = try BackupCodec.encode(document)
    let restored = try BackupCodec.decode(data)
    #expect(restored.entries[1].amountUSDT == 100)
    #expect(restored.entries[1].receivedUSDT == 101)
    let snapshot = try LedgerEngine.calculate(accounts: restored.accounts, entries: restored.entries)
    #expect(snapshot.usdtBalance == 101)
    #expect(snapshot.usdtCostBasisCNY == 700)
    #expect(snapshot.entryValuations[restored.entries[1].id]?.beforeUSDT == 120)
    let csv = String(decoding: try BackupCodec.csv(restored), as: UTF8.self)
    #expect(csv.contains(",120,101,-19\r\n"))
}

@Test func csvAppendsAnchorColumnsAndLeavesNonAdjustmentRowsBlank() throws {
    let document = try adjustmentDocument()
    let csv = String(decoding: try BackupCodec.csv(document), as: UTF8.self)
    let rows = csv.components(separatedBy: "\r\n")
    #expect(rows[0].hasSuffix("adjustment_before_usdt,adjustment_after_usdt,adjustment_delta_usdt"))
    #expect(rows[1].hasSuffix(",,,"))
    #expect(rows[2].hasSuffix(",100,101,1"))
    let zeroDocument = try adjustmentDocument(target: 0)
    let zero = try BackupCodec.decode(BackupCodec.encode(zeroDocument))
    let state = try LedgerEngine.calculate(accounts: zero.accounts, entries: zero.entries)
    #expect(state.usdtBalance == 0)
    #expect(state.usdtCostBasisCNY == 0)
    #expect(state.realizedPnLCNY == -700)
    #expect(state.entryValuations[zero.entries[1].id]?.costCNY == 700)
    #expect(String(decoding: try BackupCodec.csv(zero), as: UTF8.self).contains(",100,0,-100\r\n"))
}
