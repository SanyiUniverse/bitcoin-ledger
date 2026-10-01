import Foundation
import Testing
@testable import LedgerCore

private let uExchange = Account(name: "USDT test exchange", kind: .exchange)
private let uWallet = Account(name: "USDT test wallet", kind: .selfCustody)
private let uDate = Date(timeIntervalSince1970: 1_700_000_000)
private func ud(_ string: String) -> Decimal { Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))! }
private func topup(_ cny: Decimal = 720, _ usdt: Decimal = 100, _ sequence: Int64 = 0) -> LedgerEntry {
    LedgerEntry(date: uDate, sequence: sequence, kind: .buyUSDT, amountCNY: cny,
                receivedUSDT: usdt, feeValuationSource: .costBasis)
}
private func uBuy(_ usdt: Decimal, sats: Int64 = 1_000_000, sequence: Int64 = 1) -> LedgerEntry {
    LedgerEntry(date: uDate, sequence: sequence, kind: .buy, toAccountID: uExchange.id,
                amountSats: sats, settlementCurrency: .usdt, amountUSDT: usdt, feeValuationSource: .costBasis)
}
private func uSell(_ sats: Int64, received: Decimal, sequence: Int64 = 2) -> LedgerEntry {
    LedgerEntry(date: uDate, sequence: sequence, kind: .sell, fromAccountID: uExchange.id,
                amountSats: sats, settlementCurrency: .usdt, receivedUSDT: received, feeValuationSource: .costBasis)
}
private func cashout(_ usdt: Decimal, cny: Decimal, sequence: Int64 = 3) -> LedgerEntry {
    LedgerEntry(date: uDate, sequence: sequence, kind: .sellUSDT, amountCNY: cny,
                amountUSDT: usdt, feeValuationSource: .costBasis)
}
private func uCompute(_ entries: [LedgerEntry]) throws -> LedgerSnapshot {
    try LedgerEngine.calculate(accounts: [uExchange, uWallet], entries: entries)
}
private func conserved(_ snapshot: LedgerSnapshot) -> Bool {
    snapshot.costBasisCNY + snapshot.usdtCostBasisCNY
        == snapshot.investedCNY - snapshot.returnedCNY + snapshot.realizedPnLCNY
}

@Suite("USDT cash-recovery ledger")
struct USDTTests {
    @Test func firstUserExampleAllocatesOnlySpentPrincipal() throws {
        let purchase = uBuy(60)
        let result = try uCompute([topup(), purchase])
        #expect(result.investedCNY == 720)
        #expect(result.costBasisCNY == 432)
        #expect(result.usdtBalance == 40)
        #expect(result.usdtCostBasisCNY == 288)
        #expect(result.averageUSDTCostCNY == ud("7.2"))
        #expect(result.entryValuations[purchase.id]?.costCNY == 432)
        #expect(result.returnedCNY == 0)
        #expect(result.realizedPnLCNY == 0)
        #expect(conserved(result))
    }

    @Test func secondUserExampleCarriesOriginalPrincipalThroughRebuy() throws {
        let funding = topup(700)
        let firstBuy = uBuy(100)
        let firstSale = uSell(1_000_000, received: 120)
        let sold = try uCompute([funding, firstBuy, firstSale])
        #expect(sold.usdtBalance == 120)
        #expect(sold.usdtCostBasisCNY == 700)
        #expect(sold.realizedPnLCNY == 0)
        #expect(sold.costBasisCNY == 0)
        let rebuy = uBuy(60, sats: 400_000, sequence: 3)
        let beforeCash = try uCompute([funding, firstBuy, firstSale, rebuy])
        #expect(beforeCash.costBasisCNY == 350)
        #expect(beforeCash.usdtCostBasisCNY == 350)
        let payout = cashout(60, cny: 420, sequence: 4)
        let result = try uCompute([funding, firstBuy, firstSale, rebuy, payout])
        #expect(result.investedCNY == 700)
        #expect(result.returnedCNY == 420)
        #expect(result.realizedPnLCNY == 70)
        #expect(result.costBasisCNY == 350)
        #expect(result.usdtBalance == 0)
        #expect(result.usdtCostBasisCNY == 0)
        #expect(result.averageUSDTCostCNY == nil)
        #expect(conserved(result))
    }

    @Test func newFundingUsesMovingAverageWithRemainingUSDT() throws {
        let entries = [topup(700, 100), uBuy(40), topup(800, 100, 2), uBuy(80, sequence: 3)]
        let result = try uCompute(entries)
        // Remaining 60 cost 420 + new 100 cost 800 => 7.625 per USDT.
        #expect(result.usdtBalance == 80)
        #expect(result.usdtCostBasisCNY == 610)
        #expect(result.costBasisCNY == 890)
        #expect(result.investedCNY == 1_500)
        #expect(result.averageUSDTCostCNY == ud("7.625"))
        #expect(conserved(result))
    }

    @Test func totalUSDTDebitAlreadyIncludesTradeFee() throws {
        var purchase = uBuy(80)
        purchase.feeCurrency = .usdt
        purchase.feeUSDT = 1
        let result = try uCompute([topup(), purchase])
        #expect(result.usdtBalance == 20)
        #expect(result.usdtCostBasisCNY == 144)
        #expect(result.costBasisCNY == 576)
        #expect(result.investedCNY == 720)
        #expect(result.purchasePrincipalCNY == ud("568.8"))
        #expect(result.totalFeeUSDT == 1)
        #expect(result.totalFeeCNY == ud("7.2"))
        #expect(result.entryValuations[purchase.id] == EntryValuation(costCNY: 576, feeCNYEquivalent: ud("7.2"), feeUnitCostCNY: ud("7.2")))
        #expect(conserved(result))
    }

    @Test func withheldBTCFeeDoesNotAddCostAgain() throws {
        var purchase = uBuy(100, sats: 999_000)
        purchase.feeCurrency = .btc
        purchase.feeSats = 1_000
        let result = try uCompute([topup(), purchase])
        #expect(result.totalSats == 999_000)
        #expect(result.purchasedSats == 1_000_000)
        #expect(result.costBasisCNY == 720)
        #expect(result.investedCNY == 720)
        #expect(result.totalFeeCNY == ud("0.72"))
        #expect(result.entryValuations[purchase.id]?.feeUnitCostCNY == 72_000)
        #expect(conserved(result))
    }

    @Test func transferKeepsCostAndOnlyLosesSatoshiFee() throws {
        let movement = LedgerEntry(date: uDate, sequence: 2, kind: .transfer,
                                   fromAccountID: uExchange.id, toAccountID: uWallet.id,
                                   amountSats: 1_000_000, receivedSats: 999_800,
                                   feeCurrency: .btc, feeSats: 200, feeCategory: .withdrawal,
                                   feeValuationSource: .costBasis)
        let result = try uCompute([topup(), uBuy(100), movement])
        #expect(result.totalSats == 999_800)
        #expect(result.balances[uExchange.id] == 0)
        #expect(result.balances[uWallet.id] == 999_800)
        #expect(result.balances.values.reduce(0, +) == result.totalSats)
        #expect(result.costBasisCNY == 720)
        #expect(result.entryValuations[movement.id]?.costCNY == 720)
        #expect(result.entryValuations[movement.id]?.feeCNYEquivalent == ud("0.144"))
        #expect(conserved(result))
    }

    @Test func cnyFeesUseTheFourDifferentCashConventions() throws {
        var funding = topup(730)
        funding.feeCNY = 10 // INCLUDED in the 730 total cash paid.
        var purchase = uBuy(100)
        purchase.feeCNY = 5 // EXTRA cash beside the USDT debit.
        var sale = uSell(1_000_000, received: 120)
        sale.feeCNY = 3 // EXTRA cash to be carried into the received USDT.
        var payout = cashout(120, cny: 830)
        payout.feeCNY = 10 // Already withheld from actual net cash received.
        let bought = try uCompute([funding, purchase])
        #expect(bought.costBasisCNY == 735)
        #expect(bought.investedCNY == 735)
        let sold = try uCompute([funding, purchase, sale])
        #expect(sold.usdtCostBasisCNY == 738)
        #expect(sold.realizedPnLCNY == 0)
        let result = try uCompute([funding, purchase, sale, payout])
        #expect(result.investedCNY == 738)
        #expect(result.returnedCNY == 830)
        #expect(result.realizedPnLCNY == 92)
        #expect(result.totalFeeCNY == 28)
        #expect(conserved(result))
    }

    @Test func usdtWithheldFromIncomingSaleUsesIncomingBatchCost() throws {
        var sale = uSell(1_000_000, received: 119)
        sale.feeCurrency = .usdt
        sale.feeUSDT = 1
        let result = try uCompute([topup(720), uBuy(100), sale])
        #expect(result.usdtBalance == 119)
        #expect(result.usdtCostBasisCNY == 720)
        #expect(result.totalFeeUSDT == 1)
        #expect(result.totalFeeCNY == 6) // 720 / (119 received + 1 withheld)
        #expect(result.realizedPnLCNY == 0)
        #expect(conserved(result))
    }

    @Test func c2cUSDTWithheldFeeUsesGrossQuantity() throws {
        var funding = topup(720, 99)
        funding.feeCurrency = .usdt
        funding.feeUSDT = 1
        let result = try uCompute([funding])
        #expect(result.usdtBalance == 99)
        #expect(result.usdtCostBasisCNY == 720)
        #expect(result.investedCNY == 720)
        #expect(result.totalFeeCNY == ud("7.2"))
        #expect(conserved(result))
    }

    @Test func cashoutUSDTFeeIsInsideTotalDebit() throws {
        var payout = cashout(100, cny: 730, sequence: 1)
        payout.feeCurrency = .usdt
        payout.feeUSDT = 1
        let result = try uCompute([topup(700), payout])
        #expect(result.usdtBalance == 0)
        #expect(result.returnedCNY == 730)
        #expect(result.realizedPnLCNY == 30)
        #expect(result.totalFeeCNY == 7)
        #expect(conserved(result))
    }

    @Test func allUSDTMarkedAsFeeCannotAlsoProduceCashProceeds() throws {
        var payout = cashout(100, cny: 1, sequence: 1)
        payout.feeCurrency = .usdt
        payout.feeUSDT = 100
        #expect(throws: LedgerError.self) { try uCompute([topup(700), payout]) }
        payout.amountCNY = 0
        let exhausted = try uCompute([topup(700), payout])
        #expect(exhausted.usdtBalance == 0)
        #expect(exhausted.realizedPnLCNY == -700)
        #expect(conserved(exhausted))
    }

    @Test func BTCFeeOnSaleTransfersAllDebitedPrincipal() throws {
        var sale = uSell(900_000, received: 110)
        sale.feeCurrency = .btc
        sale.feeSats = 100_000
        let result = try uCompute([topup(700), uBuy(100), sale])
        #expect(result.totalSats == 0)
        #expect(result.usdtCostBasisCNY == 700)
        #expect(result.totalFeeCNY == 70)
        #expect(result.realizedPnLCNY == 0)
        #expect(conserved(result))
    }

    @Test func standaloneUSDTFeeLeavesCostUntilPoolIsExhausted() throws {
        let fee = LedgerEntry(date: uDate, sequence: 1, kind: .fee, feeCurrency: .usdt,
                              feeUSDT: 1, feeValuationSource: .costBasis)
        let remaining = try uCompute([topup(), fee])
        #expect(remaining.usdtBalance == 99)
        #expect(remaining.usdtCostBasisCNY == 720)
        #expect(remaining.realizedPnLCNY == 0)
        var last = fee
        last.id = UUID()
        last.sequence = 2
        last.feeUSDT = 99
        let empty = try uCompute([topup(), fee, last])
        #expect(empty.usdtBalance == 0)
        #expect(empty.usdtCostBasisCNY == 0)
        #expect(empty.realizedPnLCNY == -720)
        #expect(empty.totalFeeUSDT == 100)
        #expect(conserved(empty))
    }

    @Test func tinyUSDTDisposalsKeepExactRemainder() throws {
        let funding = topup(ud("0.01"), ud("0.00000003"))
        var entries = [funding]
        for index in 1...3 {
            entries.append(cashout(ud("0.00000001"), cny: 0, sequence: Int64(index)))
        }
        let result = try uCompute(entries)
        #expect(result.usdtBalance == 0)
        #expect(result.usdtCostBasisCNY == 0)
        #expect(result.realizedPnLCNY == ud("-0.01"))
        #expect(conserved(result))
    }

    @Test func editingFundingRevaluesDownstreamCostsAndDerivedFees() throws {
        var funding = topup(700)
        var purchase = uBuy(80)
        purchase.feeCurrency = .usdt
        purchase.feeUSDT = 1
        let first = try uCompute([funding, purchase])
        funding.amountCNY = 800
        let changed = try uCompute([funding, purchase])
        #expect(first.costBasisCNY == 560)
        #expect(first.totalFeeCNY == 7)
        #expect(changed.costBasisCNY == 640)
        #expect(changed.usdtCostBasisCNY == 160)
        #expect(changed.totalFeeCNY == 8)
        #expect(conserved(changed))
    }

    @Test func deletingOrReducingFundingRejectsHistoricalUSDTOverdraft() throws {
        var funding = topup()
        let purchase = uBuy(80)
        #expect(throws: LedgerError.self) { try uCompute([purchase]) }
        funding.receivedUSDT = 50
        #expect(throws: LedgerError.self) { try uCompute([funding, purchase]) }
        #expect(try uCompute([topup()]).usdtBalance == 100)
    }

    @Test func manualBTCSnapshotSurvivesEarlierFundingEdit() throws {
        var funding = topup(700)
        var purchase = uBuy(100, sats: 999_000)
        purchase.feeCurrency = .btc
        purchase.feeSats = 1_000
        purchase.feePriceCNY = 500_000
        purchase.feeValuationSource = .manualPrice
        let first = try uCompute([funding, purchase])
        funding.amountCNY = 800
        let changed = try uCompute([funding, purchase])
        #expect(first.totalFeeCNY == 5)
        #expect(changed.totalFeeCNY == 5)
        #expect(changed.costBasisCNY == 800)
        #expect(conserved(changed))
    }

    @Test func legacyDirectCNYRoundTripStillReturnsActualCash() throws {
        let purchase = LedgerEntry(date: uDate, kind: .buy, toAccountID: uExchange.id,
                                   amountSats: 1_000_000, amountCNY: 700, feeCNY: 2)
        let sale = LedgerEntry(date: uDate, sequence: 1, kind: .sell, fromAccountID: uExchange.id,
                              amountSats: 1_000_000, amountCNY: 800, feeCNY: 3)
        let result = try uCompute([purchase, sale])
        #expect(result.investedCNY == 702)
        #expect(result.returnedCNY == 800)
        #expect(result.realizedPnLCNY == 98)
        #expect(result.totalFeeCNY == 5)
        #expect(result.usdtBalance == 0)
        #expect(conserved(result))
    }

    @Test func everyMixedEventPrefixPreservesBothPools() throws {
        var purchase = uBuy(80)
        purchase.feeCurrency = .usdt
        purchase.feeUSDT = ud("0.1")
        var sale = uSell(300_000, received: 30, sequence: 2)
        sale.feeCNY = ud("0.01")
        let fee = LedgerEntry(date: uDate, sequence: 4, kind: .fee, feeCurrency: .usdt,
                              feeUSDT: ud("0.00000001"), feeValuationSource: .costBasis)
        let events = [topup(ud("700.01")), purchase, sale, cashout(10, cny: ud("71.23")), fee]
        for index in events.indices {
            let result = try uCompute(Array(events[...index]))
            #expect(conserved(result))
            #expect(result.balances.values.reduce(0, +) == result.totalSats)
            #expect(result.usdtBalance >= 0)
        }
    }

    @Test func manyCyclesAndHistoricalEditsConserveEveryPrefix() throws {
        var history: [LedgerEntry] = []
        for cycle in 0..<25 {
            let offset = Int64(cycle * 6)
            let funding = topup(700 + Decimal(cycle) / 100, 100, offset)
            var purchase = uBuy(60, sequence: offset + 1)
            purchase.feeCurrency = .usdt
            purchase.feeUSDT = ud("0.01345678")
            let partial = uSell(300_000, received: 20, sequence: offset + 2)
            let remainder = uSell(700_000, received: 50, sequence: offset + 3)
            let dustFee = LedgerEntry(date: uDate, sequence: offset + 4, kind: .fee,
                                      feeCurrency: .usdt, feeUSDT: ud("0.00000001"),
                                      feeValuationSource: .costBasis)
            let payout = cashout(ud("109.99999999"), cny: 800 + Decimal(cycle) / 100, sequence: offset + 5)
            for entry in [funding, purchase, partial, remainder, dustFee, payout] {
                history.append(entry)
                let prefix = try uCompute(history)
                #expect(conserved(prefix))
                #expect(prefix.balances.values.reduce(0, +) == prefix.totalSats)
            }
        }
        let original = try uCompute(history)
        #expect(original.realizedPnLCNY == 2_500)
        #expect(original.usdtBalance == 0)
        #expect(original.usdtCostBasisCNY == 0)
        #expect(original.costBasisCNY == 0)
        history[0].amountCNY += 100
        let edited = try uCompute(history)
        #expect(edited.realizedPnLCNY == 2_400)
        #expect(edited.returnedCNY == original.returnedCNY)
        #expect(edited.totalFeeCNY > original.totalFeeCNY)
        #expect(conserved(edited))
        history[0].receivedUSDT += ud("0.00000001")
        for index in history.indices {
            #expect(conserved(try uCompute(Array(history[...index]))))
        }
        #expect(try uCompute(history).usdtBalance == ud("0.00000001"))
        history.removeFirst()
        #expect(throws: LedgerError.self) { try uCompute(history) }
    }

    @Test func rejectsMixedAndExcessPrecisionFields() throws {
        var funding = topup()
        funding.receivedUSDT = ud("0.000000001")
        #expect(throws: LedgerError.self) { try uCompute([funding]) }
        funding = topup()
        funding.feeCNY = 721
        #expect(throws: LedgerError.self) { try uCompute([funding]) }
        var purchase = uBuy(80)
        purchase.amountCNY = 1
        #expect(throws: LedgerError.self) { try uCompute([topup(), purchase]) }
        purchase = uBuy(80)
        purchase.feeCurrency = .usdt
        purchase.feeUSDT = 80
        #expect(throws: LedgerError.self) { try uCompute([topup(), purchase]) }
        purchase.feeUSDT = 1
        purchase.feeValuationSource = .manualPrice
        #expect(throws: LedgerError.self) { try uCompute([topup(), purchase]) }
        purchase.feeValuationSource = .costBasis
        purchase.feePriceCNY = 7
        #expect(throws: LedgerError.self) { try uCompute([topup(), purchase]) }
    }

    @Test func derivedFeesEncodeNoFakeSnapshotAndV1FieldsDefault() throws {
        let entry = uBuy(60)
        let bytes = try JSONEncoder().encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["feeCNYEquivalent"] == nil)
        #expect(object["amountUSDT"] as? String == "60")
        #expect(try JSONDecoder().decode(LedgerEntry.self, from: bytes) == entry)
        let legacy = LedgerEntry(date: uDate, kind: .buy, toAccountID: uExchange.id, amountSats: 1, amountCNY: ud("0.01"))
        var oldObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        for key in ["settlementCurrency", "amountUSDT", "receivedUSDT", "feeUSDT", "feeValuationSource"] {
            oldObject.removeValue(forKey: key)
        }
        let decoded = try JSONDecoder().decode(LedgerEntry.self, from: JSONSerialization.data(withJSONObject: oldObject))
        #expect(decoded == legacy)
        #expect(decoded.feeValuationSource == .manualPrice)
        #expect(decoded.settlementCurrency == .cny)
    }

    @Test func valuationJSONUsesExactStringsAndRejectsNumericCoercion() throws {
        let projection = EntryValuation(costCNY: ud("0.333333333333"), feeCNYEquivalent: ud("0.000000000001"), feeUnitCostCNY: ud("7.123456789012"))
        let data = try JSONEncoder().encode(projection)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["feeCNYEquivalent"] as? String == "0.000000000001")
        #expect(try JSONDecoder().decode(EntryValuation.self, from: data) == projection)
        object["costCNY"] = 0.33
        let poisoned = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EntryValuation.self, from: poisoned) }
    }
}
