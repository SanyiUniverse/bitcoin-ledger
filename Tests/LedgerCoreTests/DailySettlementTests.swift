import Foundation
import Testing
@testable import LedgerCore

private let settlementAnchor = Date(timeIntervalSince1970: 1_790_827_200) // 2026-10-01 12:00 Shanghai
private func settlementBuy(at date: Date, sats: Int64 = 100_000_000, cost: Decimal = 100,
                           sequence: Int64 = 0) -> LedgerEntry {
    syntheticEntry(date: date, sequence: sequence, kind: .buy, toAccountID: Account.defaults[0].id,
        receivedSats: sats, amountCNY: cost)
}
private func settlementPrice(at date: Date, price: Decimal = 200) -> DailyNoonObservation {
    DailyNoonObservation(targetAt: date, priceUSD: price, fetchedAt: date.addingTimeInterval(10))
}

@Test func settlementPreservesTheFirstPurchaseHourMinuteSecondAndFractionExactly() throws {
    let first = settlementAnchor.addingTimeInterval(3_600 + 137.123456789)
    let entries = [settlementBuy(at: first.addingTimeInterval(86_400), sequence: 1), settlementBuy(at: first)]
    let targets = DailyProfitEngine.settlementTargets(entries: entries, now: first.addingTimeInterval(2 * 86_400))
    #expect(targets == [first, first.addingTimeInterval(86_400), first.addingTimeInterval(2 * 86_400)])
    #expect(DailyProfitEngine.settlement(on: first, entries: entries) == first)
    #expect(DailyProfitEngine.settlement(on: first.addingTimeInterval(86_400), entries: entries) == targets[1])
    #expect(DailyProfitEngine.settlementTargets(entries: entries, now: first.addingTimeInterval(-0.001)).isEmpty)
    #expect(DailyProfitEngine.settlementTargets(entries: entries, now: first) == [first])
    #expect(DailyProfitEngine.settlement(on: first, entries: []) == nil)
    #expect(DailyProfitEngine.settlementTargets(entries: [], now: first).isEmpty)
    let document = BackupDocument(entries: entries, dailyNoonObservations: [settlementPrice(at: first)])
    let row = try #require(DailyProfitEngine.rows(document: document, now: first).first)
    #expect(row.date == first && row.totalSats == 100_000_000 && row.costUSD == 100)
    #expect(row.marketValueUSD == 200 && row.profitUSD == 100 && row.profitRatio == 1)
}

@Test func settlementUsesShanghaiDaysAcrossUTCMidnightAndIncludesTheExactCutoff() throws {
    let first = ISO8601DateFormatter().date(from: "2026-09-30T20:03:17Z")!.addingTimeInterval(0.25)
    let tomorrow = first.addingTimeInterval(86_400)
    let entries = [settlementBuy(at: first),
        settlementBuy(at: tomorrow, sats: 50_000_000, cost: 50, sequence: 1),
        settlementBuy(at: tomorrow.addingTimeInterval(0.001), sats: 300_000_000, cost: 300, sequence: 2)]
    let targets = DailyProfitEngine.settlementTargets(entries: entries, now: tomorrow)
    #expect(targets == [first, tomorrow])
    #expect(DailyProfitEngine.calendar.component(.day, from: first) == 1)
    #expect(DailyProfitEngine.calendar.component(.day, from: tomorrow) == 2)
    let rows = try DailyProfitEngine.rows(document: BackupDocument(entries: entries,
        dailyNoonObservations: [settlementPrice(at: first), settlementPrice(at: tomorrow)]), now: tomorrow)
    #expect(rows[1].totalSats == 150_000_000 && rows[1].costUSD == 150 && rows[1].marketValueUSD == 300)
}

@Test func settlementPriceUsesOnlyTheLastEndedMinuteWhileAccountingUsesTheRealCutoff() throws {
    let close = settlementAnchor
    let target = close.addingTimeInterval(37.125)
    let completed = MarketCandle(closeDate: close, interval: 60, open: 190, high: 210, low: 180, close: 200)
    let ongoing = MarketCandle(closeDate: close.addingTimeInterval(45), interval: 45,
        open: 900, high: 1_100, low: 800, close: 1_000, isComplete: false)
    let history = MarketHistory(range: .all, period: .minute, fetchedAt: close.addingTimeInterval(45),
        candles: [completed, ongoing], source: "Coinbase · BTC-USD 真实行情（美元）")
    let observation = try #require(DailyProfitEngine.reusableNoonObservation(targetAt: target, history: history))
    #expect(observation.priceUSD == 200 && observation.priceCloseAt == close && observation.targetAt == target)
    #expect(DailyProfitEngine.completedMinuteClose(for: close) == close)
    #expect(DailyProfitEngine.completedMinuteClose(for: close.addingTimeInterval(59.999)) == close)
    #expect(DailyProfitEngine.completedMinuteClose(for: close.addingTimeInterval(60)) == close.addingTimeInterval(60))
    let row = try #require(DailyProfitEngine.rows(document: BackupDocument(entries: [settlementBuy(at: target)],
        dailyNoonObservations: [observation]), now: target).first)
    #expect(row.costUSD == 100 && row.totalSats == 100_000_000 && row.marketValueUSD == 200)
    let absent = MarketHistory(range: .all, period: .minute, fetchedAt: target.addingTimeInterval(10),
        candles: [ongoing], source: history.source)
    #expect(DailyProfitEngine.reusableNoonObservation(targetAt: target, history: absent) == nil)
}

@Test func savedLegacyNoonPricesReuseOnlyTheSameMinuteAndKeepTheirOriginalRecord() throws {
    let legacy = DailyNoonObservation(targetAt: settlementAnchor, priceUSD: 200,
        source: DailyProfitEngine.legacyNoonSource, fetchedAt: settlementAnchor.addingTimeInterval(5))
    let target = settlementAnchor.addingTimeInterval(37.125)
    let reused = try #require(DailyProfitEngine.reusableNoonObservation(targetAt: target, observations: [legacy]))
    #expect(reused.targetAt == target && reused.priceUSD == 200 && reused.fetchedAt == legacy.fetchedAt)
    #expect(reused.source == DailyProfitEngine.priceSource && reused.priceCloseAt == legacy.targetAt)
    try DailyProfitEngine.validate([legacy, reused])
    let cachedMinute = MarketCandle(closeDate: settlementAnchor, interval: 60,
        open: 190, high: 210, low: 180, close: 200)
    let history = MarketHistory(range: .all, period: .minute, fetchedAt: legacy.fetchedAt,
        candles: [cachedMinute], source: DailyProfitEngine.legacyNoonSource)
    #expect(DailyProfitEngine.reusableNoonObservation(targetAt: target, history: history)?.priceUSD == 200)
    #expect(DailyProfitEngine.reusableNoonObservation(targetAt: target.addingTimeInterval(60), observations: [legacy]) == nil)
    var wrongLegacy = legacy
    wrongLegacy.targetAt = target
    #expect(throws: (any Error).self) { try DailyProfitEngine.validate([wrongLegacy]) }
    var missing = reused
    missing.status = .missing
    missing.priceUSD = nil
    #expect(throws: (any Error).self) { try DailyProfitEngine.validate([missing]) }
}

@Test func dailyPurchasesComeFromEventsAtTheCutoffAndTransfersNeverLightTheCostRow() throws {
    let first = settlementBuy(at: settlementAnchor)
    let tomorrow = settlementAnchor.addingTimeInterval(86_400)
    let atBoundary = settlementBuy(at: tomorrow, sats: 50_000_000, cost: 50, sequence: 1)
    let justAfter = settlementBuy(at: tomorrow.addingTimeInterval(0.001), sats: 25_000_000,
        cost: 25, sequence: 2)
    let transfer = syntheticEntry(date: tomorrow.addingTimeInterval(3_600), sequence: 3, kind: .transfer,
        fromAccountID: Account.defaults[0].id, toAccountID: Account.defaults[1].id,
        amountSats: 10_000_000, receivedSats: 9_000_000)
    var document = BackupDocument(entries: [first, atBoundary, justAfter, transfer])
    let final = tomorrow.addingTimeInterval(2 * 86_400)
    let rows = try DailyProfitEngine.rows(document: document, now: final)
    #expect(rows.map(\.purchaseEntryIDs) == [[first.id], [atBoundary.id], [justAfter.id], []])
    #expect(rows.map(\.purchaseCount) == [1, 1, 1, 0])
    #expect(rows.map(\.purchaseCostChangeUSD) == [100, 50, 25, 0])
    #expect(rows[2].costUSD == 175 && rows[2].totalSats == 174_000_000)
    document.entries.removeAll { $0.id == justAfter.id }
    let corrected = try DailyProfitEngine.rows(document: document, now: final)
    #expect(corrected.map(\.purchaseEntryIDs) == [[first.id], [atBoundary.id], [], []])
    #expect(corrected.map(\.purchaseCostChangeUSD) == [100, 50, 0, 0])
    #expect(corrected[2].costUSD == 150 && corrected[2].totalSats == 149_000_000)
}

@Test func purchasesWithUnknownFXRemainExplicitEventsEvenWhenCostIsMissing() throws {
    var first = settlementBuy(at: settlementAnchor)
    first.conversion = nil
    let second = settlementBuy(at: settlementAnchor.addingTimeInterval(86_400), sequence: 1)
    let rows = try DailyProfitEngine.rows(document: BackupDocument(entries: [first, second]),
        now: second.date.addingTimeInterval(86_400))
    #expect(rows.map(\.purchaseEntryIDs) == [[first.id], [second.id], []])
    #expect(rows.map(\.purchaseCostChangeUSD) == [nil, 100, 0])
    #expect(rows.allSatisfy { $0.costUSD == nil })
    // Existing fixture construction can omit event metadata.
    let fixture = DailyProfitRow(date: settlementAnchor, totalSats: 0, costUSD: 0,
        marketValueUSD: 0, profitUSD: 0, profitRatio: nil, status: .available)
    #expect(fixture.purchaseEntryIDs.isEmpty && fixture.purchaseCount == 0)
}

@Test func fractionalSettlementTargetsRemainReusableAcrossJSONRestartsForManyDays() throws {
    for fraction in [0.000000183, 0.0004999, 0.123456789, 0.9999999] {
        let first = settlementAnchor.addingTimeInterval(137 + fraction)
        let entry = settlementBuy(at: first)
        let last = first.addingTimeInterval(95 * 86_400)
        let targets = DailyProfitEngine.settlementTargets(entries: [entry], now: last)
        #expect(targets.count == 96 && targets.first == first)
        var document = BackupDocument(exportedAt: last.addingTimeInterval(60), entries: [entry],
            dailyNoonObservations: targets.map { settlementPrice(at: $0) })
        for _ in 0..<3 {
            document = try BackupCodec.decode(BackupCodec.encode(document))
            let rows = try DailyProfitEngine.rows(document: document, now: last.addingTimeInterval(1))
            let restartedTargets = DailyProfitEngine.settlementTargets(entries: document.entries,
                now: last.addingTimeInterval(1))
            #expect(rows.count == 96 && restartedTargets == rows.map(\.date))
            #expect(restartedTargets == document.dailyNoonObservations.map(\.targetAt))
            #expect(Set(rows.map(\.date)).count == rows.count)
            #expect(rows.allSatisfy { $0.status == .available && $0.priceUSD == 200 && $0.profitUSD == 100 })
            #expect(rows.first?.purchaseEntryIDs == [entry.id])
        }
    }
}

@Test func backdatedFirstPurchaseChangesTheScheduleWithoutBorrowingOldNoonPrices() throws {
    let original = settlementBuy(at: settlementAnchor)
    let legacy = DailyNoonObservation(targetAt: settlementAnchor, priceUSD: 200,
        source: DailyProfitEngine.legacyNoonSource, fetchedAt: settlementAnchor.addingTimeInterval(10))
    var document = BackupDocument(entries: [original], dailyNoonObservations: [legacy])
    #expect(try DailyProfitEngine.rows(document: document, now: settlementAnchor).first?.profitUSD == 100)
    let earlier = settlementAnchor.addingTimeInterval(-86_400 + 125.5)
    document.entries.append(settlementBuy(at: earlier, sats: 50_000_000, cost: 50, sequence: 1))
    let rows = try DailyProfitEngine.rows(document: document, now: settlementAnchor.addingTimeInterval(3_600))
    #expect(rows.map(\.date) == [earlier, earlier.addingTimeInterval(86_400)])
    #expect(rows.map(\.status) == [.pendingPrice, .pendingPrice])
    #expect(rows.map(\.profitUSD) == [nil, nil])
    #expect(rows[1].totalSats == 150_000_000 && rows[1].costUSD == 150)
    #expect(document.dailyNoonObservations == [legacy])
}

@Test func schemaSixUpgradeRetainsNoonCacheAndRejectsInvalidSourceInsteadOfClearingIt() throws {
    let legacy = DailyNoonObservation(targetAt: settlementAnchor, priceUSD: 200,
        source: DailyProfitEngine.legacyNoonSource, fetchedAt: settlementAnchor.addingTimeInterval(30))
    let document = BackupDocument(entries: [settlementBuy(at: settlementAnchor.addingTimeInterval(37.125))],
        dailyNoonObservations: [legacy])
    var object = try #require(JSONSerialization.jsonObject(with: BackupCodec.encode(document)) as? [String: Any])
    object["schemaVersion"] = 6
    let migrated = try BackupCodec.decode(JSONSerialization.data(withJSONObject: object))
    #expect(migrated.schemaVersion == 7 && migrated.entries == document.entries && migrated.accounts == document.accounts)
    #expect(migrated.dailyNoonObservations == [legacy])
    #expect(try DailyProfitEngine.rows(document: migrated, now: settlementAnchor.addingTimeInterval(3_600)).first?.marketValueUSD == nil)
    var observations = try #require(object["dailyNoonObservations"] as? [[String: Any]])
    observations[0]["source"] = DailyProfitEngine.priceSource
    object["dailyNoonObservations"] = observations
    #expect(throws: (any Error).self) { try BackupCodec.decode(JSONSerialization.data(withJSONObject: object)) }
    observations[0]["source"] = "Yahoo Finance / Coinbase · BTC-USD"
    object["dailyNoonObservations"] = observations
    #expect(throws: (any Error).self) { try BackupCodec.decode(JSONSerialization.data(withJSONObject: object)) }
}

@Test @MainActor func schemaSixFirstSavePreservesOriginalCacheAndBytesBeforeUpgrade() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daily-settlement-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ledger.json")
    let legacy = DailyNoonObservation(targetAt: settlementAnchor, priceUSD: 200,
        source: DailyProfitEngine.legacyNoonSource, fetchedAt: settlementAnchor.addingTimeInterval(30))
    let document = BackupDocument(entries: [settlementBuy(at: settlementAnchor)], dailyNoonObservations: [legacy])
    var object = try #require(JSONSerialization.jsonObject(with: BackupCodec.encode(document)) as? [String: Any])
    object["schemaVersion"] = 6
    let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    try original.write(to: url)
    let repository = try LedgerRepository(url: url)
    let migrated = try repository.load()
    #expect(repository.needsMigration && migrated.dailyNoonObservations == [legacy])
    #expect(try Data(contentsOf: url) == original)
    try repository.save(migrated)
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("ledger.before-upgrade-v6-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
    #expect(try BackupCodec.decode(Data(contentsOf: url)).dailyNoonObservations == [legacy])
}
