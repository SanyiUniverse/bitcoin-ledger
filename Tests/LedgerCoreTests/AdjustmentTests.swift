import Foundation
import Testing
@testable import LedgerCore

private let adjustmentDate = Date(timeIntervalSince1970: 1_700_000_000)
private let adjustmentAccount = Account(name: "Adjustment test exchange", kind: .exchange)
private func ad(_ string: String) -> Decimal { Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))! }
private func adjustmentFunding(cny: Decimal = 700, usdt: Decimal = 100) -> LedgerEntry {
    LedgerEntry(date: adjustmentDate, kind: .buyUSDT, amountCNY: cny,
                receivedUSDT: usdt, feeValuationSource: .costBasis)
}
private func adjustment(reference: Decimal = 100, target: Decimal, sequence: Int64 = 1) -> LedgerEntry {
    LedgerEntry(date: adjustmentDate, sequence: sequence, kind: .adjustUSDT,
                feeCategory: .other, note: "余额核对", amountUSDT: reference, receivedUSDT: target)
}
private func adjustmentBuy(_ usdt: Decimal, sequence: Int64 = 2) -> LedgerEntry {
    LedgerEntry(date: adjustmentDate, sequence: sequence, kind: .buy,
                toAccountID: adjustmentAccount.id, amountSats: 100_000,
                settlementCurrency: .usdt, amountUSDT: usdt, feeValuationSource: .costBasis)
}
private func adjustmentCompute(_ entries: [LedgerEntry]) throws -> LedgerSnapshot {
    try LedgerEngine.calculate(accounts: [adjustmentAccount], entries: entries)
}
private func adjustmentConserves(_ snapshot: LedgerSnapshot) -> Bool {
    snapshot.costBasisCNY + snapshot.usdtCostBasisCNY
        == snapshot.investedCNY - snapshot.returnedCNY + snapshot.realizedPnLCNY
}

@Suite("Auditable USDT balance adjustments")
struct AdjustmentTests {
    @Test func positiveTargetKeepsExistingPrincipalForBothDirections() throws {
        for target in [Decimal(120), Decimal(60), Decimal(100)] {
            let change = adjustment(target: target)
            let result = try adjustmentCompute([adjustmentFunding(), change])
            #expect(result.usdtBalance == target)
            #expect(result.usdtCostBasisCNY == 700)
            #expect(result.investedCNY == 700)
            #expect(result.returnedCNY == 0)
            #expect(result.realizedPnLCNY == 0)
            #expect(result.entryValuations[change.id] == EntryValuation(costCNY: 700, beforeUSDT: 100, afterUSDT: target))
            #expect(adjustmentConserves(result))
        }
    }

    @Test func adjustmentFromZeroCanRecordReturnWithoutInventingCost() throws {
        let change = adjustment(reference: 0, target: ad("1.00000001"))
        let result = try adjustmentCompute([change])
        #expect(result.usdtBalance == ad("1.00000001"))
        #expect(result.usdtCostBasisCNY == 0)
        #expect(result.averageUSDTCostCNY == 0)
        #expect(result.investedCNY == 0)
        #expect(result.returnedCNY == 0)
        #expect(result.realizedPnLCNY == 0)
        #expect(result.entryValuations[change.id]?.beforeUSDT == 0)
        #expect(adjustmentConserves(result))
        let consumed = try adjustmentCompute([change, adjustmentBuy(ad("1.00000001"))])
        #expect(consumed.usdtBalance == 0)
        #expect(consumed.costBasisCNY == 0)
        #expect(consumed.totalSats == 100_000)
        #expect(adjustmentConserves(consumed))
    }

    @Test func zeroTargetRecognizesEntireRemainingPrincipalLoss() throws {
        let change = adjustment(target: 0)
        let result = try adjustmentCompute([adjustmentFunding(), change])
        #expect(result.usdtBalance == 0)
        #expect(result.usdtCostBasisCNY == 0)
        #expect(result.realizedPnLCNY == -700)
        #expect(result.investedCNY == 700)
        #expect(result.returnedCNY == 0)
        #expect(result.totalFeeCNY == 0)
        #expect(result.totalFeeUSDT == 0)
        #expect(result.entryValuations[change.id] == EntryValuation(costCNY: 700, beforeUSDT: 100, afterUSDT: 0))
        #expect(adjustmentConserves(result))
    }

    @Test func laterRefundDoesNotReduceHistoricalFeeTotals() throws {
        let fee = LedgerEntry(date: adjustmentDate, sequence: 1, kind: .fee,
                              feeCurrency: .usdt, feeUSDT: 2, feeValuationSource: .costBasis)
        let change = adjustment(reference: 98, target: 99, sequence: 2)
        let before = try adjustmentCompute([adjustmentFunding(), fee])
        let after = try adjustmentCompute([adjustmentFunding(), fee, change])
        #expect(after.usdtBalance == 99)
        #expect(after.usdtCostBasisCNY == 700)
        #expect(after.totalFeeUSDT == 2)
        #expect(after.totalFeeCNY == 14)
        #expect(after.totalFeeUSDT == before.totalFeeUSDT)
        #expect(after.entryValuations[fee.id] == before.entryValuations[fee.id])
        #expect(after.entryValuations[change.id]?.feeCNYEquivalent == 0)
        #expect(adjustmentConserves(after))
    }

    @Test func BTCPoolAndCashTotalsDoNotChange() throws {
        let purchase = adjustmentBuy(20, sequence: 1)
        let initial = [adjustmentFunding(), purchase]
        let before = try adjustmentCompute(initial)
        let after = try adjustmentCompute(initial + [adjustment(reference: 80, target: 82, sequence: 2)])
        #expect(after.totalSats == before.totalSats)
        #expect(after.balances == before.balances)
        #expect(after.costBasisCNY == 140)
        #expect(after.usdtCostBasisCNY == 560)
        #expect(after.investedCNY == before.investedCNY)
        #expect(after.returnedCNY == before.returnedCNY)
        #expect(after.purchasedSats == before.purchasedSats)
        #expect(after.purchasePrincipalCNY == before.purchasePrincipalCNY)
        #expect(after.totalFeeSats == before.totalFeeSats)
        #expect(adjustmentConserves(after))
    }

    @Test func earlierEditReplaysTrueBeforeBalanceAndKeepsTargetAnchor() throws {
        var funding = adjustmentFunding()
        let change = adjustment(reference: 100, target: 101)
        let original = try adjustmentCompute([funding, change])
        funding.amountCNY = 840
        funding.receivedUSDT = 120
        let edited = try adjustmentCompute([funding, change])
        #expect(original.entryValuations[change.id]?.beforeUSDT == 100)
        #expect(edited.entryValuations[change.id]?.beforeUSDT == 120)
        #expect(edited.entryValuations[change.id]?.afterUSDT == 101)
        #expect(edited.usdtBalance == 101)
        #expect(edited.usdtCostBasisCNY == 840)
        #expect(change.amountUSDT == 100) // Original audit reference is not mutated.
        #expect(adjustmentConserves(edited))
    }

    @Test func earlierEditRecomputesZeroTargetLoss() throws {
        var funding = adjustmentFunding()
        let change = adjustment(target: 0)
        #expect(try adjustmentCompute([funding, change]).realizedPnLCNY == -700)
        funding.amountCNY = 800
        let edited = try adjustmentCompute([funding, change])
        #expect(edited.realizedPnLCNY == -800)
        #expect(edited.entryValuations[change.id]?.costCNY == 800)
        #expect(adjustmentConserves(edited))
    }

    @Test func deletingFundingDoesNotTurnSavedReferenceIntoFakeFunding() throws {
        let change = adjustment(reference: 100, target: 101)
        let original = try adjustmentCompute([adjustmentFunding(), change])
        let withoutFunding = try adjustmentCompute([change])
        #expect(original.usdtCostBasisCNY == 700)
        #expect(withoutFunding.usdtBalance == 101)
        #expect(withoutFunding.usdtCostBasisCNY == 0)
        #expect(withoutFunding.investedCNY == 0)
        #expect(withoutFunding.entryValuations[change.id]?.beforeUSDT == 0)
        #expect(adjustmentConserves(withoutFunding))
    }

    @Test func deletingAdjustmentCanExposeFutureOverdraft() throws {
        let funding = adjustmentFunding()
        let change = adjustment(target: 120)
        let purchase = adjustmentBuy(110)
        #expect(try adjustmentCompute([funding, change, purchase]).usdtBalance == 10)
        #expect(throws: LedgerError.self) { try adjustmentCompute([funding, purchase]) }
        var reduced = change
        reduced.receivedUSDT = 109
        #expect(throws: LedgerError.self) { try adjustmentCompute([funding, reduced, purchase]) }
    }

    @Test func futureAnchorCannotRepairEarlierOverdraft() throws {
        let funding = adjustmentFunding(usdt: 50)
        let purchase = adjustmentBuy(60, sequence: 1)
        let change = adjustment(reference: 0, target: 100, sequence: 2)
        #expect(throws: LedgerError.self) { try adjustmentCompute([funding, purchase, change]) }
    }

    @Test func editedTargetAndDeletionRecomputeFollowingPrincipal() throws {
        let funding = adjustmentFunding()
        var change = adjustment(target: 120)
        let purchase = adjustmentBuy(60)
        let first = try adjustmentCompute([funding, change, purchase])
        #expect(first.costBasisCNY == 350)
        change.receivedUSDT = 100
        let edited = try adjustmentCompute([funding, change, purchase])
        let deleted = try adjustmentCompute([funding, purchase])
        #expect(edited.costBasisCNY == 420)
        #expect(deleted.costBasisCNY == 420)
        #expect(edited.usdtBalance == 40)
        #expect(adjustmentConserves(edited))
        #expect(adjustmentConserves(deleted))
    }

    @Test func acceptsOneUSDTSubunitAndRejectsInvalidAmounts() throws {
        #expect(try adjustmentCompute([adjustment(reference: 0, target: ad("0.00000001"))]).usdtBalance == ad("0.00000001"))
        for invalid in [ad("0.000000001"), Decimal(-1), Decimal.nan, Amounts.maximumUSDT + 1] {
            #expect(throws: LedgerError.self) {
                try adjustmentCompute([adjustment(reference: 0, target: invalid)])
            }
            #expect(throws: LedgerError.self) {
                try adjustmentCompute([adjustment(reference: invalid, target: 1)])
            }
        }
    }

    @Test func rejectsIrrelevantCashAccountsAndFees() throws {
        let valid = adjustment(target: 101)
        var variants: [LedgerEntry] = []
        var candidate = valid
        candidate.fromAccountID = adjustmentAccount.id; variants.append(candidate)
        candidate = valid; candidate.toAccountID = adjustmentAccount.id; variants.append(candidate)
        candidate = valid; candidate.amountSats = 1; variants.append(candidate)
        candidate = valid; candidate.receivedSats = 1; variants.append(candidate)
        candidate = valid; candidate.amountCNY = 1; variants.append(candidate)
        candidate = valid; candidate.feeCNY = 1; variants.append(candidate)
        candidate = valid; candidate.feeCurrency = .btc; variants.append(candidate)
        candidate = valid; candidate.feeCurrency = .usdt; variants.append(candidate)
        candidate = valid; candidate.feeSats = 1; variants.append(candidate)
        candidate = valid; candidate.feeUSDT = 1; variants.append(candidate)
        candidate = valid; candidate.feePriceCNY = 1; variants.append(candidate)
        candidate = valid; candidate.settlementCurrency = .usdt; variants.append(candidate)
        candidate = valid; candidate.feeValuationSource = .costBasis; variants.append(candidate)
        for entry in variants {
            #expect(throws: LedgerError.self) { try adjustmentCompute([adjustmentFunding(), entry]) }
        }
    }

    @Test func everyAdjustmentPrefixPreservesCapitalConservation() throws {
        let events = [
            adjustmentFunding(),
            adjustment(target: 120),
            adjustmentBuy(30, sequence: 2),
            adjustment(reference: 90, target: 80, sequence: 3),
            adjustmentBuy(20, sequence: 4),
            adjustment(reference: 60, target: 0, sequence: 5),
            adjustment(reference: 0, target: ad("0.00000001"), sequence: 6)
        ]
        for index in events.indices {
            let snapshot = try adjustmentCompute(Array(events[...index]))
            #expect(adjustmentConserves(snapshot))
            #expect(snapshot.balances.values.reduce(0, +) == snapshot.totalSats)
            #expect(snapshot.returnedCNY == 0)
            #expect(snapshot.totalFeeCNY == 0)
        }
    }

    @Test func optionalValuationBalancesPreserveOldJSONAndExactStrings() throws {
        let legacy = EntryValuation(costCNY: 700, feeCNYEquivalent: 1, feeUnitCostCNY: 7)
        let legacyData = try JSONEncoder().encode(legacy)
        let oldObject = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(oldObject["beforeUSDT"] == nil)
        #expect(oldObject["afterUSDT"] == nil)
        #expect(try JSONDecoder().decode(EntryValuation.self, from: legacyData) == legacy)
        let adjusted = EntryValuation(costCNY: 700, beforeUSDT: ad("100.00000001"), afterUSDT: 0)
        let data = try JSONEncoder().encode(adjusted)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["beforeUSDT"] as? String == "100.00000001")
        #expect(object["afterUSDT"] as? String == "0")
        #expect(try JSONDecoder().decode(EntryValuation.self, from: data) == adjusted)
        object["beforeUSDT"] = 100.0
        let numeric = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EntryValuation.self, from: numeric) }
        object["beforeUSDT"] = "100.000000001"
        let excessPrecision = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: LedgerError.self) { try JSONDecoder().decode(EntryValuation.self, from: excessPrecision) }
    }
}
