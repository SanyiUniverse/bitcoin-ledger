import Foundation
import Testing
@testable import LedgerCore

private let exchange = Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Binance", kind: .exchange)
private let green = Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Green Wallet", kind: .selfCustody)
private let cold = Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "Cold Wallet", kind: .selfCustody)
private let accounts = [exchange, green, cold]
private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func d(_ value: String) -> Decimal { Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))! }
private func buy(_ sats: Int64, _ cny: Decimal, account: Account = exchange, sequence: Int64 = 0) -> LedgerEntry {
    LedgerEntry(date: epoch, sequence: sequence, kind: .buy, toAccountID: account.id, amountSats: sats, amountCNY: cny)
}
private func transfer(_ out: Int64, _ received: Int64, from: Account = exchange, to: Account = green, sequence: Int64 = 1, price: Decimal = 500_000) -> LedgerEntry {
    LedgerEntry(date: epoch, sequence: sequence, kind: .transfer, fromAccountID: from.id, toAccountID: to.id,
                amountSats: out, receivedSats: received, feeCurrency: .btc, feeSats: out - received,
                feePriceCNY: out == received ? 0 : price, feeCategory: .withdrawal)
}
private func compute(_ entries: [LedgerEntry]) throws -> LedgerSnapshot {
    try LedgerEngine.calculate(accounts: accounts, entries: entries)
}

@Suite("BTC ledger accounting")
struct EngineTests {
    @Test func singlePurchase() throws {
        let result = try compute([buy(15_324, 100)])
        #expect(result.totalSats == 15_324)
        #expect(result.balances[exchange.id] == 15_324)
        #expect(result.investedCNY == 100)
        #expect(result.purchasedSats == 15_324)
        #expect(result.costBasisCNY == 100)
        #expect(result.averageBuyPriceCNY == Amounts.rounded(100 / d("0.00015324")))
        #expect(result.actualCostPriceCNY == result.averageBuyPriceCNY)
    }

    @Test func weightedPurchasesAtDifferentPrices() throws {
        let result = try compute([buy(10_000_000, 10_000), buy(20_000_000, 40_000, sequence: 1)])
        #expect(result.totalSats == 30_000_000)
        #expect(result.purchasePrincipalCNY == 50_000)
        #expect(result.purchasedSats == 30_000_000)
        #expect(result.averageBuyPriceCNY == d("166666.666666666667"))
        #expect(result.actualCostPriceCNY == result.averageBuyPriceCNY)
    }

    @Test func purchaseWithCNYFee() throws {
        var entry = buy(1_000_000, 1_000)
        entry.feeCNY = 10
        let result = try compute([entry])
        #expect(result.investedCNY == 1_010)
        #expect(result.costBasisCNY == 1_010)
        #expect(result.averageBuyPriceCNY == 100_000)
        #expect(result.actualCostPriceCNY == 101_000)
        #expect(result.totalFeeCNY == 10)
        #expect(result.totalFeeSats == 0)
        #expect(result.feeRatio == d("0.009900990099"))
    }

    @Test func purchaseWithBTCFeeUsesNetCreditAndGrossPurchasedQuantity() throws {
        var entry = buy(99_800, 500)
        entry.feeCurrency = .btc
        entry.feeSats = 200
        entry.feePriceCNY = 500_000
        let result = try compute([entry])
        #expect(result.totalSats == 99_800)
        #expect(result.purchasedSats == 100_000)
        #expect(result.costBasisCNY == 500)
        #expect(result.investedCNY == 500)
        #expect(result.totalFeeSats == 200)
        #expect(result.totalFeeCNY == 1)
        #expect(result.averageBuyPriceCNY == 500_000)
        #expect(result.actualCostPriceCNY == d("501002.004008016032"))
        #expect(result.feeRatio == d("0.002"))
    }

    @Test func exchangeToWalletMatchesUserExample() throws {
        let result = try compute([buy(100_000, 500), transfer(100_000, 99_800)])
        #expect(result.balances[exchange.id] == 0)
        #expect(result.balances[green.id] == 99_800)
        #expect(result.totalSats == 99_800)
        #expect(result.costBasisCNY == 500)
        #expect(result.investedCNY == 500)
        #expect(result.purchasedSats == 100_000)
        #expect(result.totalFeeSats == 200)
        #expect(result.totalFeeCNY == 1)
    }

    @Test func walletToWalletAbsorbsOnlyFee() throws {
        let result = try compute([buy(100_000, 500, account: green), transfer(80_000, 79_000, from: green, to: cold)])
        #expect(result.balances[green.id] == 20_000)
        #expect(result.balances[cold.id] == 79_000)
        #expect(result.totalSats == 99_000)
        #expect(result.costBasisCNY == 500)
        #expect(result.realizedPnLCNY == 0)
    }

    @Test func feeFreeTransferDoesNotChangeInvestmentOrCost() throws {
        let first = buy(100_000, 500)
        let before = try compute([first])
        let after = try compute([first, transfer(100_000, 100_000)])
        #expect(after.totalSats == before.totalSats)
        #expect(after.investedCNY == before.investedCNY)
        #expect(after.costBasisCNY == before.costBasisCNY)
        #expect(after.actualCostPriceCNY == before.actualCostPriceCNY)
    }

    @Test func editsRecomputeAllDerivedValues() throws {
        var purchase = buy(200_000, 1_000)
        let movement = transfer(100_000, 99_800)
        let before = try compute([purchase, movement])
        purchase.amountSats = 300_000
        purchase.amountCNY = 1_800
        let after = try compute([purchase, movement])
        #expect(before.totalSats == 199_800)
        #expect(after.totalSats == 299_800)
        #expect(after.balances[exchange.id] == 200_000)
        #expect(after.costBasisCNY == 1_800)
        #expect(after.averageBuyPriceCNY == 600_000)
    }

    @Test func deletionsRecomputeInsteadOfLeavingCachedBalances() throws {
        let a = buy(100_000, 500)
        let b = buy(100_000, 600, sequence: 1)
        let movement = transfer(100_000, 99_800, sequence: 2)
        #expect(try compute([a, b, movement]).totalSats == 199_800)
        let deletedMovement = try compute([a, b])
        #expect(deletedMovement.totalSats == 200_000)
        #expect(deletedMovement.totalFeeCNY == 0)
        #expect(deletedMovement.balances[green.id] == 0)
        #expect(try compute([b]).costBasisCNY == 600)
        #expect(try compute([]).totalSats == 0)
    }

    @Test func allAccountBalancesSumToTotalAfterMixedOperations() throws {
        let sale = LedgerEntry(date: epoch, sequence: 4, kind: .sell, fromAccountID: green.id,
                               amountSats: 20_000, amountCNY: 150, feeCurrency: .btc, feeSats: 100, feePriceCNY: 750_000)
        let fee = LedgerEntry(date: epoch, sequence: 5, kind: .fee, fromAccountID: cold.id,
                              feeCurrency: .btc, feeSats: 200, feePriceCNY: 750_000, feeCategory: .network)
        let result = try compute([buy(200_000, 1_000), buy(100_000, 600, sequence: 1),
                                  transfer(100_000, 99_800, sequence: 2),
                                  transfer(50_000, 49_500, from: green, to: cold, sequence: 3), sale, fee])
        #expect(result.balances.values.reduce(0, +) == result.totalSats)
        #expect(result.totalSats == 279_000)
        #expect(result.totalFeeSats == 1_000)
    }

    @Test func valueAverageActualCostPnLAndReturn() throws {
        var purchase = buy(10_000_000, 10_000)
        purchase.feeCNY = 100
        let result = try compute([purchase, transfer(1_000_000, 990_000, price: 100_000)])
        #expect(result.totalSats == 9_990_000)
        #expect(result.marketValue(price: 120_000) == 11_988)
        #expect(result.unrealizedPnL(price: 120_000) == 1_888)
        #expect(result.returnRatio(price: 120_000) == d("0.186930693069"))
        #expect(result.averageBuyPriceCNY == 100_000)
        #expect(result.actualCostPriceCNY == d("101101.101101101101"))
        #expect(result.totalFeeCNY == 110)
        #expect(result.feeRatio == d("0.010891089109"))
    }

    @Test func saleWithBTCFeeRemovesProportionalBasis() throws {
        let sale = LedgerEntry(date: epoch, sequence: 1, kind: .sell, fromAccountID: exchange.id,
                               amountSats: 20_000_000, amountCNY: 30_000,
                               feeCurrency: .btc, feeSats: 1_000_000, feePriceCNY: 100_000)
        let result = try compute([buy(100_000_000, 100_000), sale])
        #expect(result.totalSats == 79_000_000)
        #expect(result.costBasisCNY == 79_000)
        #expect(result.realizedPnLCNY == 9_000)
        #expect(result.investedCNY == 100_000)
        #expect(result.totalFeeCNY == 1_000)
    }

    @Test func saleCNYFeeIsAlreadyWithheldFromNetProceeds() throws {
        let sale = LedgerEntry(date: epoch, sequence: 1, kind: .sell, fromAccountID: exchange.id,
                               amountSats: 100_000_000, amountCNY: 1_900, feeCNY: 100)
        let result = try compute([buy(100_000_000, 1_000), sale])
        #expect(result.totalSats == 0)
        #expect(result.costBasisCNY == 0)
        #expect(result.realizedPnLCNY == 900)
        #expect(result.investedCNY == 1_000)
        #expect(result.totalFeeCNY == 100)
        #expect(result.actualCostPriceCNY == nil)
        #expect(result.returnRatio(price: 500_000) == nil)
    }

    @Test func spendCanHaveZeroCashProceeds() throws {
        let spend = LedgerEntry(date: epoch, sequence: 1, kind: .sell, fromAccountID: exchange.id,
                                amountSats: 50_000, amountCNY: 0)
        let result = try compute([buy(100_000, 500), spend])
        #expect(result.totalSats == 50_000)
        #expect(result.costBasisCNY == 250)
        #expect(result.realizedPnLCNY == -250)
    }

    @Test func standaloneCNYFeeCapitalizesOnlyWhileHoldingBTC() throws {
        let fee = LedgerEntry(date: epoch, sequence: 1, kind: .fee, feeCNY: 10, feeCategory: .other)
        let held = try compute([buy(100_000, 500), fee])
        #expect(held.costBasisCNY == 510)
        #expect(held.investedCNY == 510)
        #expect(held.realizedPnLCNY == 0)
        let empty = try compute([fee])
        #expect(empty.costBasisCNY == 0)
        #expect(empty.investedCNY == 10)
        #expect(empty.realizedPnLCNY == -10)
    }

    @Test func lastBTCConsumedByFeeClearsBasisAsRealizedLoss() throws {
        let fee = LedgerEntry(date: epoch, sequence: 1, kind: .fee, fromAccountID: exchange.id,
                              feeCurrency: .btc, feeSats: 100_000, feePriceCNY: 600_000, feeCategory: .other)
        let result = try compute([buy(100_000, 500), fee])
        #expect(result.totalSats == 0)
        #expect(result.costBasisCNY == 0)
        #expect(result.realizedPnLCNY == -500)
        #expect(result.totalFeeCNY == 600)
    }

    @Test func finalSaleClearsRoundingRemainder() throws {
        var entries = [buy(3, d("0.01"))]
        for index in 1...3 {
            entries.append(LedgerEntry(date: epoch, sequence: Int64(index), kind: .sell,
                                       fromAccountID: exchange.id, amountSats: 1, amountCNY: 0))
        }
        let result = try compute(entries)
        #expect(result.costBasisCNY == 0)
        #expect(result.realizedPnLCNY == d("-0.01"))
    }

    @Test func chronologicalReplayUsesDateThenSequenceThenUUID() throws {
        let purchase = buy(100_000, 500, sequence: 1)
        let movement = transfer(100_000, 100_000, sequence: 2)
        #expect(try compute([movement, purchase]).balances[green.id] == 100_000)
        var earlyMovement = movement
        earlyMovement.date = epoch.addingTimeInterval(-1)
        #expect(throws: LedgerError.self) { try compute([purchase, earlyMovement]) }
        var tieBuy = purchase
        tieBuy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var tieTransfer = movement
        tieTransfer.sequence = 1
        tieTransfer.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(try compute([tieTransfer, tieBuy]).balances[green.id] == 100_000)
    }

    @Test func editingOrDeletingEarlierBuyCannotCauseHistoricalOverdraft() throws {
        var purchase = buy(100_000, 500)
        let movement = transfer(100_000, 99_800)
        purchase.amountSats = 50_000
        #expect(throws: LedgerError.self) { try compute([purchase, movement]) }
        #expect(throws: LedgerError.self) { try compute([movement]) }
    }

    @Test func feeSnapshotDoesNotChangeWithCurrentMarketPrice() throws {
        var purchase = buy(99_800, 500)
        purchase.feeCurrency = .btc
        purchase.feeSats = 200
        purchase.feePriceCNY = d("500000.12345678")
        let result = try compute([purchase])
        #expect(result.totalFeeCNY == d("1.000000246914"))
        #expect(result.marketValue(price: 1_000_000) == 998)
        #expect(result.totalFeeCNY == purchase.feeCNYEquivalent)
    }

    @Test func emptyLedgerRatiosAreUndefinedNotNaN() throws {
        let result = try compute([])
        #expect(result.averageBuyPriceCNY == nil)
        #expect(result.actualCostPriceCNY == nil)
        #expect(result.feeRatio == nil)
        #expect(result.returnRatio(price: 500_000) == nil)
        #expect(result.marketValue(price: 500_000) == 0)
    }

    @Test func allBTCArithmeticRespectsOneSatoshi() throws {
        #expect(try Amounts.satoshis("0.00000001") == 1)
        #expect(try Amounts.satoshis("21000000.00000000") == Amounts.maximumSats)
        #expect(try Amounts.satoshis("0.10000001") == 10_000_001)
        #expect(Amounts.btc(1) == d("0.00000001"))
        let result = try compute([buy(2, d("0.01")), transfer(2, 1, price: 500_000)])
        #expect(result.totalSats == 1)
        #expect(result.totalFeeCNY == d("0.005"))
        #expect(result.marketValue(price: 500_000) == d("0.005"))
    }

    @Test func strictInputRejectsRoundingAndTrailingGarbage() throws {
        for text in ["0.000000001", "-1", "1e-8", "1 BTC", "1,000", "NaN", "Infinity", "", ".", "1.", "21000001"] {
            #expect(throws: LedgerError.self) { try Amounts.satoshis(text) }
        }
        #expect(throws: LedgerError.self) { try Amounts.decimal("1.001") }
        #expect(try Amounts.decimal(" 0.10 ") + Amounts.decimal("0.20") == d("0.30"))
    }

    @Test func rejectsInvalidAccountsDuplicateIDsAndReferences() throws {
        let purchase = buy(100_000, 500)
        #expect(throws: LedgerError.self) { try compute([purchase, purchase]) }
        #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: [exchange, exchange], entries: []) }
        #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: [Account(name: "  ", kind: .exchange)], entries: []) }
        #expect(throws: LedgerError.self) {
            try LedgerEngine.calculate(accounts: [exchange, Account(name: " binance ", kind: .selfCustody)], entries: [])
        }
        #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: [green], entries: [purchase]) }
    }

    @Test func rejectsInvalidTransferAndIrrelevantFields() throws {
        var mismatch = transfer(100_000, 99_800)
        mismatch.feeSats = 100
        #expect(throws: LedgerError.self) { try compute([buy(100_000, 500), mismatch]) }
        var sameAccount = transfer(100_000, 100_000, to: exchange)
        #expect(throws: LedgerError.self) { try compute([buy(100_000, 500), sameAccount]) }
        sameAccount.toAccountID = green.id
        sameAccount.amountCNY = 1
        #expect(throws: LedgerError.self) { try compute([buy(100_000, 500), sameAccount]) }
        var badBuy = buy(100_000, 500)
        badBuy.receivedSats = 1
        #expect(throws: LedgerError.self) { try compute([badBuy]) }
    }

    @Test func rejectsOutOfRangeAndExcessPrecisionAmounts() throws {
        var purchase = buy(1, d("0.001"))
        #expect(throws: LedgerError.self) { try compute([purchase]) }
        purchase.amountCNY = Decimal.nan
        #expect(throws: LedgerError.self) { try compute([purchase]) }
        purchase.amountCNY = -1
        #expect(throws: LedgerError.self) { try compute([purchase]) }
        purchase = buy(Amounts.maximumSats, 1)
        #expect(throws: LedgerError.self) { try compute([purchase, buy(1, 1, account: green, sequence: 1)]) }
        purchase.amountSats = Int64.max
        #expect(throws: LedgerError.self) { try compute([purchase]) }
        purchase = buy(1, 1)
        purchase.sequence = Int64.max
        #expect(throws: LedgerError.self) { try compute([purchase]) }
    }

    @Test func rejectsMissingBTCFeeSnapshotAndMixedFees() throws {
        var purchase = buy(99_800, 500)
        purchase.feeCurrency = .btc
        purchase.feeSats = 200
        #expect(throws: LedgerError.self) { try compute([purchase]) }
        purchase.feePriceCNY = 500_000
        purchase.feeCNY = 1
        #expect(throws: LedgerError.self) { try compute([purchase]) }
    }

    @Test func precisionIsPreservedInJSONDecimalStrings() throws {
        var entry = buy(99_800, d("500.01"))
        entry.feeCurrency = .btc
        entry.feeSats = 200
        entry.feePriceCNY = d("500000.12345678")
        let bytes = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LedgerEntry.self, from: bytes)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["amountCNY"] as? String == "500.01")
        #expect(object["feePriceCNY"] as? String == "500000.12345678")
        #expect(object["feeCNYEquivalent"] as? String == "1.000000246914")
        #expect(decoded == entry)
        var numeric = object
        numeric["amountCNY"] = 500.01
        let malformed = try JSONSerialization.data(withJSONObject: numeric)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LedgerEntry.self, from: malformed) }
        var mismatch = object
        mismatch["feeCNYEquivalent"] = "1.00"
        let wrongSnapshot = try JSONSerialization.data(withJSONObject: mismatch)
        #expect(throws: LedgerError.self) { try JSONDecoder().decode(LedgerEntry.self, from: wrongSnapshot) }
    }

    @Test func cnyTransferFeeAddsCashCostButDoesNotConsumeBTC() throws {
        let movement = LedgerEntry(date: epoch, sequence: 1, kind: .transfer,
                                   fromAccountID: exchange.id, toAccountID: green.id,
                                   amountSats: 100_000, receivedSats: 100_000,
                                   feeCNY: 10, feeCategory: .withdrawal)
        let result = try compute([buy(100_000, 500), movement])
        #expect(result.totalSats == 100_000)
        #expect(result.costBasisCNY == 510)
        #expect(result.investedCNY == 510)
        #expect(result.purchasedSats == 100_000)
        #expect(result.totalFeeCNY == 10)
    }

    @Test func deletingEmptyHistoricalAccountPreservesItsReferences() throws {
        var archivedExchange = exchange
        archivedExchange.isArchived = true
        let history = [buy(100_000, 500), transfer(100_000, 99_800)]
        let result = try LedgerEngine.calculate(accounts: [archivedExchange, green, cold], entries: history)
        #expect(result.totalSats == 99_800)
        #expect(result.costBasisCNY == 500)
        #expect(result.balances[archivedExchange.id] == 0)
        #expect(history[0].toAccountID == archivedExchange.id)
        let reusedName = Account(name: exchange.name, kind: .exchange)
        #expect(try LedgerEngine.calculate(accounts: [archivedExchange, green, reusedName], entries: history).totalSats == 99_800)
    }

    @Test func cannotArchiveAccountWithBalance() throws {
        var archivedExchange = exchange
        archivedExchange.isArchived = true
        #expect(throws: LedgerError.self) {
            try LedgerEngine.calculate(accounts: [archivedExchange], entries: [buy(1, d("0.01"))])
        }
    }

    @Test func oldAccountBackupWithoutArchiveFlagDefaultsToActive() throws {
        let original = try JSONEncoder().encode(exchange)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object.removeValue(forKey: "isArchived")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Account.self, from: oldData) == exchange)
    }
}
