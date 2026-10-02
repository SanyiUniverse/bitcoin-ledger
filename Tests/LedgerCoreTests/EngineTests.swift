import Foundation
import Testing
@testable import LedgerCore

private let epoch = Date(timeIntervalSince1970: 1_790_899_200)
private let exchange = Account.defaults[0]
private let wallet = Account.defaults[1]
private let accounts = Account.defaults
private func decimal(_ value: String) -> Decimal { Decimal(string: value)! }
private func buy(_ sats: Int64, _ cny: Decimal, sequence: Int64 = 0, date: Date = epoch, to: Account = exchange) -> LedgerEntry {
    syntheticEntry(date: date, sequence: sequence, kind: .buy, toAccountID: to.id, receivedSats: sats, amountCNY: cny)
}
private func transfer(_ out: Int64, _ received: Int64, sequence: Int64 = 1, date: Date = epoch, from: Account = exchange, to: Account = wallet) -> LedgerEntry {
    syntheticEntry(date: date, sequence: sequence, kind: .transfer, fromAccountID: from.id, toAccountID: to.id,
                amountSats: out, receivedSats: received)
}
private func compute(_ entries: [LedgerEntry], asOf: Date? = nil) throws -> LedgerSnapshot {
    try LedgerEngine.calculate(accounts: accounts, entries: entries, asOf: asOf)
}

@Suite("Purchase and transfer accounting")
struct EngineTests {
    @Test func userPurchaseExample() throws {
        let result = try compute([buy(52_000, 500)])
        #expect(result.totalInvestedUSD == 500)
        #expect(result.totalPurchasedSats == 52_000)
        #expect(result.totalLossSats == 0)
        #expect(result.totalSats == 52_000)
        #expect(result.balances[exchange.id] == 52_000)
        #expect(result.averageCostUSD == decimal("961538.461538461538"))
    }
    @Test func userTransferExampleIncreasesCostWithoutInvestment() throws {
        let result = try compute([buy(1_000_000, 5_000), transfer(1_000_000, 995_000)])
        #expect(result.balances[exchange.id] == 0)
        #expect(result.balances[wallet.id] == 995_000)
        #expect(result.totalPurchasedSats == 1_000_000)
        #expect(result.totalLossSats == 5_000)
        #expect(result.totalSats == 995_000)
        #expect(result.totalInvestedUSD == 5_000)
        #expect(result.averageCostUSD == decimal("502512.562814070352"))
    }
    @Test func weightedActualPurchasesIncludeAllConversionCost() throws {
        let result = try compute([buy(10_000_000, 10_000), buy(20_000_000, 40_000, sequence: 1)])
        #expect(result.totalInvestedUSD == 50_000)
        #expect(result.totalPurchasedSats == 30_000_000)
        #expect(result.averageCostUSD == decimal("166666.666666666667"))
    }
    @Test func reverseTransfersAndBalancesUseOnlyLoss() throws {
        let entries = [buy(200_000, 1_000), transfer(100_000, 99_800),
                       transfer(50_000, 49_500, sequence: 2, from: wallet, to: exchange)]
        let result = try compute(entries)
        #expect(result.balances[exchange.id] == 149_500)
        #expect(result.balances[wallet.id] == 49_800)
        #expect(result.totalLossSats == 700)
        #expect(result.balances.values.reduce(0, +) == result.totalSats)
        #expect(result.totalSats == result.totalPurchasedSats - result.totalLossSats)
    }
    @Test func equalTransferLeavesCostUnchanged() throws {
        let before = try compute([buy(100_000, 500)])
        let after = try compute([buy(100_000, 500), transfer(100_000, 100_000)])
        #expect(after.averageCostUSD == before.averageCostUSD)
        #expect(after.totalInvestedUSD == before.totalInvestedUSD)
        #expect(after.totalLossSats == 0)
    }
    @Test func marketValueProfitAndRatioUseTotalInvestment() throws {
        let result = try compute([buy(10_000_000, 10_100), transfer(1_000_000, 990_000)])
        #expect(result.value(price: 120_000) == 11_988)
        #expect(result.profit(price: 120_000) == 1_888)
        #expect(result.profitRatio(price: 120_000) == decimal("0.186930693069"))
    }
    @Test func historicalSnapshotsNeverIncludeFuturePurchasesOrLosses() throws {
        let first = buy(100_000, 500)
        let secondDate = epoch.addingTimeInterval(86_400)
        let second = buy(200_000, 1_200, date: secondDate)
        let movement = transfer(100_000, 99_000, date: secondDate.addingTimeInterval(86_400))
        let entries = [movement, second, first]
        let beforeAll = try compute(entries, asOf: epoch.addingTimeInterval(-1))
        let firstDay = try compute(entries, asOf: epoch)
        let secondDay = try compute(entries, asOf: secondDate)
        let today = try compute(entries)
        #expect(beforeAll.totalSats == 0)
        #expect(firstDay.totalInvestedUSD == 500)
        #expect(firstDay.totalSats == 100_000)
        #expect(firstDay.totalLossSats == 0)
        #expect(firstDay.averageCostUSD == 500_000)
        #expect(firstDay.profit(price: 600_000) == 100)
        #expect(secondDay.totalSats == 300_000)
        #expect(secondDay.totalInvestedUSD == 1_700)
        #expect(secondDay.totalLossSats == 0)
        #expect(today.totalLossSats == 1_000)
        #expect(today.totalSats == 299_000)
        let history = try LedgerEngine.history(accounts: accounts, entries: entries)
        #expect(history.map(\.entryID) == [first.id, second.id, movement.id])
        #expect(history.map(\.snapshot) == [firstDay, secondDay, today])
    }
    @Test func intradayHistoryReplaysAtExactEventTime() throws {
        let purchase = buy(100_000, 500, date: epoch.addingTimeInterval(3_600))
        let movement = transfer(100_000, 99_800, date: epoch.addingTimeInterval(7_200))
        #expect(try compute([purchase, movement], asOf: epoch.addingTimeInterval(5_400)).totalLossSats == 0)
        #expect(try compute([purchase, movement], asOf: movement.date).totalLossSats == 200)
    }
    @Test func editsAndDeletesReplayWholeLedger() throws {
        var purchase = buy(200_000, 1_000)
        let movement = transfer(100_000, 99_800)
        purchase.amountSats = 300_000
        purchase.receivedSats = 300_000
        purchase.amountCNY = 1_800
        purchase.conversion = try PurchaseConversion.make(amountCNY: 1_800, rate: purchase.conversion!.rate)
        #expect(try compute([purchase, movement]).totalSats == 299_800)
        #expect(try compute([purchase]).totalLossSats == 0)
        #expect(try compute([]).totalInvestedUSD == 0)
    }
    @Test func historicalOverdraftPreventsInvalidEditsAndDeletes() throws {
        let movement = transfer(100_000, 99_800)
        #expect(throws: LedgerError.self) { try compute([buy(50_000, 500), movement]) }
        #expect(throws: LedgerError.self) { try compute([movement]) }
        #expect(throws: LedgerError.self) { try compute([buy(100_000, 500), transfer(100_000, 99_800, date: epoch.addingTimeInterval(-1))]) }
    }
    @Test func fullLossKeepsCashInvestmentAndUndefinedCost() throws {
        let result = try compute([buy(100_000, 500), transfer(100_000, 0)])
        #expect(result.totalSats == 0)
        #expect(result.totalLossSats == 100_000)
        #expect(result.totalInvestedUSD == 500)
        #expect(result.averageCostUSD == nil)
        #expect(result.profit(price: 600_000) == -500)
        #expect(result.profitRatio(price: 600_000) == -1)
    }
    @Test func emptyRatiosAreUndefined() throws {
        let result = try compute([])
        #expect(result.averageCostUSD == nil)
        #expect(result.profitRatio(price: 600_000) == nil)
        #expect(result.value(price: 600_000) == 0)
    }
    @Test func sequenceThenUUIDDeterminesSameTimeOrder() throws {
        var purchase = buy(100_000, 500, sequence: 1)
        var movement = transfer(100_000, 99_800, sequence: 1)
        purchase.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        movement.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(try compute([movement, purchase]).totalSats == 99_800)
        movement.sequence = 0
        #expect(throws: LedgerError.self) { try compute([purchase, movement]) }
    }
    @Test func rejectsInvalidAccountsIDsAndReferences() throws {
        let purchase = buy(100_000, 500)
        #expect(throws: LedgerError.self) { try compute([purchase, purchase]) }
        #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: [exchange, exchange], entries: []) }
        #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: [Account(name: "  ")], entries: []) }
        #expect(throws: LedgerError.self) { try LedgerEngine.calculate(accounts: [wallet], entries: [purchase]) }
    }
    @Test func rejectsInvalidTransferAndPurchaseFields() throws {
        #expect(throws: LedgerError.self) { try compute([buy(100_000, 500), transfer(100_000, 100_001)]) }
        #expect(throws: LedgerError.self) { try compute([buy(100_000, 500), transfer(100_000, 100_000, to: exchange)]) }
        var movement = transfer(100_000, 99_800)
        movement.amountCNY = 1
        #expect(throws: LedgerError.self) { try compute([buy(100_000, 500), movement]) }
        var purchase = buy(100_000, 500)
        purchase.receivedSats = 1
        #expect(throws: LedgerError.self) { try compute([purchase]) }
    }
    @Test func moneyLimitsAndPrecisionAreValidated() throws {
        for value in [decimal("0.001"), Decimal.nan, -1, Amounts.maximumCNY + 1] {
            #expect(throws: LedgerError.self) { try compute([buy(1, value)]) }
        }
        #expect(throws: LedgerError.self) { try compute([buy(Amounts.maximumSats, 1), buy(1, 1, sequence: 1)]) }
        var purchase = buy(1, 1)
        purchase.amountSats = Int64.max
        #expect(throws: LedgerError.self) { try compute([purchase]) }
        purchase = buy(1, 1, sequence: Int64.max)
        #expect(throws: LedgerError.self) { try compute([purchase]) }
    }
    @Test func exactSatoshiAndMoneyParsing() throws {
        #expect(try Amounts.satoshis("0.00000001") == 1)
        #expect(try Amounts.satoshis("0.10000001") == 10_000_001)
        #expect(try Amounts.satoshis("21000000.00000000") == Amounts.maximumSats)
        #expect(try Amounts.decimal("0.10") + Amounts.decimal("0.20") == decimal("0.30"))
        for text in ["0.000000001", "-1", "1e-8", "1 BTC", "1,000", "NaN", "Infinity", "", ".", "1.", "21000001"] {
            #expect(throws: LedgerError.self) { try Amounts.satoshis(text) }
        }
    }
}
