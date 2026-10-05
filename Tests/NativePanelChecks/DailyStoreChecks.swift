import Foundation
import Combine
import LedgerCore

private final class QADailyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(_ instant: Date) { self.instant = instant }
    func read() -> Date { lock.withLock { instant } }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant = instant.addingTimeInterval(seconds) } }
}

private actor QADailyMarketProbe {
    let clock: QADailyClock
    var priceCalls = 0
    var noonDates: [Date] = []
    var priceFailures = 0
    var permanentPriceFailure = false
    var noonMissing = 0
    var gateNextNoon = false
    var gateNextPrice = false
    var priceCancellationObserved = false
    private var noonGate: CheckedContinuation<Void, Never>?
    private var priceGate: CheckedContinuation<Void, Never>?
    init(clock: QADailyClock) { self.clock = clock }
    func configure(priceFailures: Int = 0, permanentPriceFailure: Bool = false,
                   noonMissing: Int = 0, gateNoon: Bool = false, gatePrice: Bool = false) {
        self.priceFailures = priceFailures
        self.permanentPriceFailure = permanentPriceFailure
        self.noonMissing = noonMissing
        gateNextNoon = gateNoon
        gateNextPrice = gatePrice
    }
    func price() async throws -> PriceQuote {
        priceCalls += 1
        if gateNextPrice {
            gateNextPrice = false
            await withCheckedContinuation { priceGate = $0 }
        }
        await Task.yield()
        priceCancellationObserved = Task.isCancelled
        if priceFailures > 0 { priceFailures -= 1; throw URLError(.notConnectedToInternet) }
        if permanentPriceFailure { permanentPriceFailure = false; throw PriceError.invalidPrice }
        // Deliberately ignore cancellation: the store's generation must reject
        // this late result even when a provider does not cooperate.
        return PriceQuote(priceUSD: 10_000, fetchedAt: clock.read(), source: "合成现价")
    }
    func noon(_ target: Date) async throws -> DailyNoonObservation {
        noonDates.append(target)
        if gateNextNoon {
            gateNextNoon = false
            await withCheckedContinuation { noonGate = $0 }
        }
        if noonMissing > 0 {
            noonMissing -= 1
            return DailyNoonObservation(targetAt: target, priceUSD: nil,
                fetchedAt: clock.read(), status: .missing)
        }
        return DailyNoonObservation(targetAt: target, priceUSD: 10_000, fetchedAt: clock.read())
    }
    func releaseNoon() { noonGate?.resume(); noonGate = nil }
    func releasePrice() { priceGate?.resume(); priceGate = nil }
}

private actor QADailyCurrencyProbe {
    var calls = 0
    var failing = true
    var gateNext = false
    private var gate: CheckedContinuation<Void, Never>?
    func configure(failing: Bool = true, gateNext: Bool = false) {
        self.failing = failing
        self.gateNext = gateNext
    }
    func rate(_ date: Date) async throws -> USDExchangeRate {
        calls += 1
        if gateNext {
            gateNext = false
            await withCheckedContinuation { gate = $0 }
        }
        if failing { throw URLError(.notConnectedToInternet) }
        return PanelChecks.syntheticRate(asOf: date)
    }
    func release() { gate?.resume(); gate = nil }
}

extension PanelChecks {
    @MainActor static func checkDailyStoreScheduling() throws {
        let folder = output.appendingPathComponent("daily-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let noon = DailyProfitEngine.noon(on: Date())
        let settlement = noon.addingTimeInterval(1_843.25)
        let error = runAsync {
            let priceClock = QADailyClock(noon.addingTimeInterval(10))
            let prices = QADailyMarketProbe(clock: priceClock)
            await prices.configure(priceFailures: 2)
            let quoteStore = makeDailyStore(folder: folder, name: "price", clock: priceClock, probe: prices)
            await quoteStore.refreshPrice()
            record(await prices.priceCalls == 1 && quoteStore.priceRetryAt == priceClock.read().addingTimeInterval(60),
                "quote outage schedules a real 60-second automatic retry")
            priceClock.advance(59)
            await quoteStore.serviceTick()
            record(await prices.priceCalls == 1 && Int(ceil(quoteStore.priceRetryAt!.timeIntervalSince(priceClock.read()))) == 1,
                "quote countdown derives remaining seconds without requesting again")
            priceClock.advance(1)
            await quoteStore.serviceTick()
            record(await prices.priceCalls == 2 && quoteStore.priceRetryAt == priceClock.read().addingTimeInterval(120),
                "quote retry bypasses freshness and doubles persistent network backoff")
            priceClock.advance(150)
            let wake = Task { await quoteStore.servicesDidBecomeActive() }
            let minute = Task { await quoteStore.serviceTick() }
            await wake.value; await minute.value
            record(await prices.priceCalls == 3 && quoteStore.quote?.priceUSD == 10_000
                   && quoteStore.priceRetryAt == nil && quoteStore.priceError == nil,
                "overdue wake and service tick deduplicate one retry and clear error on success")
            await quoteStore.serviceTick()
            record(await prices.priceCalls == 3, "fresh shared quote is reused across minute/activation callers")
            priceClock.advance(60)
            await quoteStore.serviceTick()
            record(await prices.priceCalls == 4, "shared live quote refreshes at 60 seconds")
            await prices.configure(permanentPriceFailure: true)
            priceClock.advance(60)
            await quoteStore.serviceTick()
            priceClock.advance(600)
            await quoteStore.serviceTick()
            record(await prices.priceCalls == 5 && quoteStore.priceRetryAt == nil && quoteStore.quote?.priceUSD == 10_000,
                "permanent quote data errors stop automatic retries while preserving the successful quote")
            await quoteStore.refreshPrice(force: true)
            record(await prices.priceCalls == 6 && quoteStore.priceError == nil,
                "explicit refresh can recover a permanent quote error")

            try checkDailyDerivedCache(folder: folder, settlement: settlement)
            checkDailyDisplayFormatting(at: settlement)
            try await checkDailyCurrencyRetries(folder: folder, settlement: settlement)

            let clock = QADailyClock(settlement.addingTimeInterval(10))
            let probe = QADailyMarketProbe(clock: clock)
            await probe.configure(noonMissing: 1)
            let store = makeDailyStore(folder: folder, name: "daily", clock: clock, probe: probe)
            let buy = try dailyBuy(store: store, at: settlement.addingTimeInterval(-2 * 86_400))
            try store.saveEntry(buy)
            await store.refreshDailyProfit()
            let targets = DailyProfitEngine.settlementTargets(entries: [buy], now: clock.read())
            record(await probe.noonDates == Array(targets.reversed()) && store.document.dailyNoonObservations.count == 3,
                "settlement backfill fetches today first, then older days serially, saving each unique day")
            record(store.dailyProfitSettlementAnchor == buy.date && store.dailyProfitSettlementToday == settlement
                   && store.dailyProfitRows.first?.date == buy.date,
                "settlement uses first purchase Shanghai hour-minute-second including its precise first-day cutoff")
            record(store.dailyProfitRetryAt == clock.read().addingTimeInterval(60)
                   && store.dailyProfitRows.last?.status == .missingPrice,
                "newly closed settlement minute remains explicitly missing and gets a bounded delayed retry")
            await store.refreshDailyProfit(forceMissing: true)
            record(await probe.noonDates.count == 3, "active settlement retry deadline is respected by manual and automatic callers")
            clock.advance(60)
            await store.serviceTick()
            await settleDailyTasks(store)
            record(await probe.noonDates.count == 4 && store.document.dailyNoonObservations.allSatisfy { $0.status == .available }
                   && store.dailyProfitRetryAt == nil,
                "delayed settlement retry fetches only the missing date and preserves successful prices")
            var changedBuy = buy
            changedBuy.receivedSats = 2_000_000; changedBuy.amountSats = 2_000_000
            try store.saveEntry(changedBuy)
            await store.refreshDailyProfit()
            record(await probe.noonDates.count == 4 && store.dailyProfitRows.allSatisfy { $0.profitUSD == 100 },
                "historical edits immediately recompute daily holdings and profit without refetching settlement prices")
            let restarted = makeDailyStore(folder: folder, name: "daily", clock: clock, probe: probe)
            record(restarted.document.dailyNoonObservations == store.document.dailyNoonObservations
                   && restarted.dailyProfitRows == store.dailyProfitRows,
                "restarting from synthetic storage preserves settlement observations and derived daily profit")

            let lateClock = QADailyClock(noon.addingTimeInterval(7200))
            let lateProbe = QADailyMarketProbe(clock: lateClock)
            let lateStore = makeDailyStore(folder: folder, name: "late-buy", clock: lateClock, probe: lateProbe)
            let lateBuy = try dailyBuy(store: lateStore, at: noon.addingTimeInterval(3_617.75))
            try lateStore.saveEntry(lateBuy)
            await lateStore.refreshDailyProfit()
            record(await lateProbe.noonDates == [lateBuy.date] && lateStore.dailyProfitRows.first?.profitUSD == 0
                   && lateStore.dailyProfitRows.first?.profitRatio == 0 && lateStore.dailyProfitRows.first?.totalSats == 1_000_000,
                "first purchase after noon settles at its own precise time and includes that purchase")

            let boundaryClock = QADailyClock(settlement.addingTimeInterval(86_400 - 1))
            let boundaryProbe = QADailyMarketProbe(clock: boundaryClock)
            let boundaryStore = makeDailyStore(folder: folder, name: "settlement-boundary", clock: boundaryClock, probe: boundaryProbe)
            var boundaryRefreshStarts = 0
            let boundarySubscription = boundaryStore.$dailyProfitRefreshing.sink {
                if $0 { boundaryRefreshStarts += 1 }
            }
            defer { boundarySubscription.cancel() }
            try boundaryStore.saveEntry(dailyBuy(store: boundaryStore, at: settlement))
            await boundaryStore.refreshDailyProfit()
            for _ in 0..<4 { await boundaryStore.serviceTick(); await settleDailyTasks(boundaryStore) }
            record(await boundaryProbe.noonDates == [settlement] && boundaryStore.dailyProfitRows.count == 1
                   && boundaryRefreshStarts == 1,
                "fractional-second cutoffs before today's settlement neither settle early nor restart an empty refresh every tick")
            boundaryClock.advance(1)
            await boundaryStore.serviceTick(); await settleDailyTasks(boundaryStore)
            record(await boundaryProbe.noonDates == [settlement, settlement.addingTimeInterval(86_400)]
                   && boundaryStore.dailyProfitRows.count == 2 && boundaryRefreshStarts == 2,
                "the service settles at the exact first-purchase second and never before its closed boundary")

            let legacyClock = QADailyClock(noon.addingTimeInterval(600))
            let legacyProbe = QADailyMarketProbe(clock: legacyClock)
            let legacyStore = makeDailyStore(folder: folder, name: "legacy-noon-cache", clock: legacyClock, probe: legacyProbe)
            let legacyBuy = try dailyBuy(store: legacyStore, at: noon.addingTimeInterval(30.25))
            let legacyNoon = DailyNoonObservation(targetAt: noon, priceUSD: 5_000,
                source: DailyProfitEngine.legacyNoonSource, fetchedAt: noon.addingTimeInterval(5))
            let oldDocument = BackupDocument(accounts: legacyStore.accounts, entries: [legacyBuy],
                dailyNoonObservations: [legacyNoon])
            var oldJSON = try JSONSerialization.jsonObject(with: BackupCodec.encode(oldDocument)) as! [String: Any]
            oldJSON["schemaVersion"] = 6
            let oldBytes = try JSONSerialization.data(withJSONObject: oldJSON, options: [.sortedKeys])
            let upgraded = try BackupCodec.decode(oldBytes)
            try legacyStore.restoreDocument(upgraded, sourceData: oldBytes)
            record(legacyStore.document.dailyNoonObservations == [legacyNoon]
                   && legacyStore.dailyProfitRows.first?.date == legacyBuy.date
                   && legacyStore.dailyProfitRows.first?.status == .pendingPrice,
                "schema 6 restore preserves legacy noon cache but rows use only the new precise settlement target")
            await legacyStore.refreshDailyProfit()
            record(await legacyProbe.noonDates.isEmpty && legacyStore.document.dailyNoonObservations.count == 2
                   && legacyStore.document.dailyNoonObservations.contains(legacyNoon)
                   && legacyStore.dailyProfitRows.first?.priceUSD == 5_000,
                "same completed minute reuses old noon price as a new target while retaining its original observation")
            let legacyRestarted = makeDailyStore(folder: folder, name: "legacy-noon-cache", clock: legacyClock, probe: legacyProbe)
            record(legacyRestarted.document.dailyNoonObservations == legacyStore.document.dailyNoonObservations
                   && legacyRestarted.dailyProfitRows == legacyStore.dailyProfitRows,
                "upgraded schema 6 caches and precise daily settlement survive restart")
            var differentMinuteBuy = legacyBuy
            differentMinuteBuy.date = noon.addingTimeInterval(90.25)
            try legacyStore.saveEntry(differentMinuteBuy)
            await legacyStore.refreshDailyProfit()
            record(await legacyProbe.noonDates == [differentMinuteBuy.date]
                   && legacyStore.dailyProfitRows.first?.priceUSD == 10_000,
                "changing the first-purchase minute does not borrow another minute's old cached price")

            let missingClock = QADailyClock(settlement.addingTimeInterval(10))
            let missingProbe = QADailyMarketProbe(clock: missingClock)
            await missingProbe.configure(noonMissing: 100)
            let missingStore = makeDailyStore(folder: folder, name: "missing", clock: missingClock, probe: missingProbe)
            try missingStore.saveEntry(dailyBuy(store: missingStore, at: settlement))
            await missingStore.refreshDailyProfit()
            for _ in 0..<5 {
                let deadline = missingStore.dailyProfitRetryAt!
                missingClock.advance(deadline.timeIntervalSince(missingClock.read()))
                await missingStore.serviceTick()
                await settleDailyTasks(missingStore)
            }
            let delayedCalls = await missingProbe.noonDates.count
            missingClock.advance(600)
            await missingStore.serviceTick(); await settleDailyTasks(missingStore)
            let stoppedCalls = await missingProbe.noonDates.count
            record(delayedCalls == 6 && stoppedCalls == delayedCalls
                   && missingStore.dailyProfitRetryAt == nil && missingStore.dailyProfitRows.first?.status == .missingPrice,
                "normal missing history stops minute retries at five minutes and stays an explicit gap")
            missingClock.advance(86_400)
            await missingStore.serviceTick(); await settleDailyTasks(missingStore)
            record(await missingProbe.noonDates.count == delayedCalls + 2,
                "a new Beijing date rechecks saved historical gaps and today's new settlement")

            let mergeClock = QADailyClock(settlement.addingTimeInterval(600))
            let mergeProbe = QADailyMarketProbe(clock: mergeClock)
            await mergeProbe.configure(gateNoon: true)
            let mergeStore = makeDailyStore(folder: folder, name: "merge", clock: mergeClock, probe: mergeProbe)
            let mergeBuy = try dailyBuy(store: mergeStore, at: settlement)
            try mergeStore.saveEntry(mergeBuy)
            let pending = Task { await mergeStore.refreshDailyProfit() }
            await waitForNoonRequest(mergeProbe)
            var edited = mergeBuy
            edited.receivedSats = 2_000_000; edited.amountSats = 2_000_000
            try mergeStore.saveEntry(edited)
            await mergeProbe.releaseNoon(); await pending.value
            await settleDailyTasks(mergeStore)
            record(mergeStore.document.entries == [edited] && mergeStore.dailyProfitRows.first?.profitUSD == 100,
                "a backfill finishing after a transaction edit merges into the latest document")

            let anchorProbe = QADailyMarketProbe(clock: mergeClock)
            await anchorProbe.configure(gateNoon: true, gatePrice: true)
            let anchorStore = makeDailyStore(folder: folder, name: "anchor-generation", clock: mergeClock, probe: anchorProbe)
            let anchorBuy = try dailyBuy(store: anchorStore, at: settlement)
            try anchorStore.saveEntry(anchorBuy)
            let staleAnchor = Task { await anchorStore.refreshDailyProfit() }
            let independentPrice = Task { await anchorStore.refreshPrice(force: true) }
            await waitForNoonRequest(anchorProbe)
            for _ in 0..<100 { if await anchorProbe.priceCalls > 0 { break }; await Task.yield() }
            var changedAnchor = anchorBuy
            changedAnchor.date = settlement.addingTimeInterval(60)
            try anchorStore.saveEntry(changedAnchor)
            await settleDailyTasks(anchorStore)
            record(anchorStore.dailyProfitSettlementAnchor == changedAnchor.date
                   && anchorStore.dailyProfitSettlementToday == changedAnchor.date
                   && anchorStore.dailyProfitRetryAt == nil,
                "editing the earliest purchase resets daily retry and schedules its new precise cutoff")
            await anchorProbe.releaseNoon(); await staleAnchor.value
            await anchorProbe.releasePrice(); await independentPrice.value
            await settleDailyTasks(anchorStore)
            record(anchorStore.document.dailyNoonObservations.map(\.targetAt) == [changedAnchor.date]
                   && anchorStore.dailyProfitRows.first?.date == changedAnchor.date,
                "a cancelled old settlement finishing late cannot publish its obsolete anchor")
            record(await !anchorProbe.priceCancellationObserved && anchorStore.quote?.priceUSD == 10_000,
                "changing the settlement anchor keeps the independently running current-price request alive")
            var earlierBuy = anchorBuy
            earlierBuy.id = UUID(); earlierBuy.date = settlement.addingTimeInterval(-60)
            try anchorStore.saveEntry(earlierBuy)
            record(anchorStore.dailyProfitSettlementAnchor == earlierBuy.date,
                "backdating an earlier purchase immediately moves the settlement clock to its time")
            try anchorStore.deleteEntry(earlierBuy)
            record(anchorStore.dailyProfitSettlementAnchor == changedAnchor.date,
                "deleting the earliest purchase immediately derives the replacement purchase clock")

            let restoreProbe = QADailyMarketProbe(clock: mergeClock)
            await restoreProbe.configure(gateNoon: true, gatePrice: true)
            let restoreStore = makeDailyStore(folder: folder, name: "restore", clock: mergeClock, probe: restoreProbe)
            try restoreStore.saveEntry(dailyBuy(store: restoreStore, at: settlement))
            let staleNoon = Task { await restoreStore.refreshDailyProfit() }
            let stalePrice = Task { await restoreStore.refreshPrice(force: true) }
            await waitForNoonRequest(restoreProbe)
            for _ in 0..<100 { if await restoreProbe.priceCalls > 0 { break }; await Task.yield() }
            let restored = BackupDocument(lastPrice: PriceQuote(priceUSD: 20_000, fetchedAt: mergeClock.read(), source: "合成恢复报价"))
            try restoreStore.restoreDocument(restored)
            await restoreProbe.releaseNoon(); await restoreProbe.releasePrice()
            await staleNoon.value; await stalePrice.value
            record(restoreStore.document == restored && !restoreStore.refreshing && !restoreStore.dailyProfitRefreshing,
                "restoring cancels old generation and rejects late settlement and current-price results")
            var futureObservation = restored
            futureObservation.dailyNoonObservations = [DailyNoonObservation(
                targetAt: noon.addingTimeInterval(86_400), priceUSD: 10_000,
                fetchedAt: noon.addingTimeInterval(86_410))]
            var refusedFuture = false
            do { try restoreStore.restoreDocument(futureObservation) } catch { refusedFuture = true }
            record(refusedFuture && restoreStore.document == restored,
                "restore rejects a future settlement observation before saving or cancelling the current ledger")
            futureObservation.dailyNoonObservations = [DailyNoonObservation(
                targetAt: noon, priceUSD: 10_000, fetchedAt: mergeClock.read().addingTimeInterval(61))]
            var refusedFutureFetch = false
            do { try restoreStore.restoreDocument(futureObservation) } catch { refusedFutureFetch = true }
            record(refusedFutureFetch && restoreStore.document == restored,
                "restore rejects a future observation fetch time while preserving the current ledger")

            let rollbackClock = QADailyClock(settlement.addingTimeInterval(10))
            let rollbackProbe = QADailyMarketProbe(clock: rollbackClock)
            await rollbackProbe.configure(gateNoon: true)
            let rollbackStore = makeDailyStore(folder: folder, name: "rollback", clock: rollbackClock, probe: rollbackProbe)
            try rollbackStore.saveEntry(dailyBuy(store: rollbackStore, at: settlement))
            _ = rollbackStore.dailyProfitRows
            let rollbackRequest = Task { await rollbackStore.refreshDailyProfit() }
            await waitForNoonRequest(rollbackProbe)
            rollbackClock.advance(-11)
            await rollbackProbe.releaseNoon(); await rollbackRequest.value
            record(rollbackStore.document.dailyNoonObservations.isEmpty && rollbackStore.dailyProfitRows.isEmpty,
                "a clock rollback rejects an in-flight target that is no longer closed and invalidates its derived rows")

            let conflictProbe = QADailyMarketProbe(clock: mergeClock)
            let conflictStore = makeDailyStore(folder: folder, name: "conflict", clock: mergeClock, probe: conflictProbe)
            try conflictStore.saveEntry(dailyBuy(store: conflictStore, at: settlement))
            let beforeConflict = conflictStore.document
            let beforeConflictRows = conflictStore.dailyProfitRows
            let beforeConflictDerivations = conflictStore.dailyProfitDerivationCount
            var external = beforeConflict
            external.lastPrice = PriceQuote(priceUSD: 30_000, fetchedAt: mergeClock.read(), source: "合成外部修改")
            try BackupCodec.encode(external).write(to: folder.appendingPathComponent("conflict.json"), options: .atomic)
            await conflictStore.refreshDailyProfit()
            record(conflictStore.document == beforeConflict && conflictStore.dailyProfitError != nil
                   && conflictStore.dailyProfitRows == beforeConflictRows
                   && conflictStore.dailyProfitDerivationCount == beforeConflictDerivations,
                "failed atomic save does not publish an unsaved settlement observation")
        }
        record(error == nil, "isolated synthetic daily scheduling checks complete")
        if let error { throw error }
    }

    @MainActor private static func checkDailyDerivedCache(folder: URL, settlement: Date) throws {
        let clock = QADailyClock(settlement.addingTimeInterval(10))
        let probe = QADailyMarketProbe(clock: clock)
        let store = makeDailyStore(folder: folder, name: "derived-cache", clock: clock, probe: probe)
        _ = store.dailyProfitRows
        _ = store.dailyProfitRows
        record(store.dailyProfitDerivationCount == 1 && store.dailyProfitSettlementAnchor == nil,
            "an empty ledger also caches daily rows without inventing a settlement anchor")
        let buy = try dailyBuy(store: store, at: settlement.addingTimeInterval(-2 * 86_400))
        store.document.entries = [buy]
        let targets = DailyProfitEngine.settlementTargets(entries: [buy], now: clock.read())
        let pendingRows = store.dailyProfitRows
        record(pendingRows.count == 3 && pendingRows.allSatisfy { $0.status == .pendingPrice }
               && store.dailyProfitSettlementAnchor == buy.date && store.dailyProfitDerivationCount == 2,
            "direct published document edits invalidate daily history and update the cached first-purchase anchor")
        store.document.dailyNoonObservations = targets.map {
            DailyNoonObservation(targetAt: $0, priceUSD: 10_000, fetchedAt: clock.read())
        }
        let originalRows = store.dailyProfitRows
        let warmCount = store.dailyProfitDerivationCount
        for _ in 0..<20 { _ = store.dailyProfitRows; _ = store.dailyProfitSettlementToday }
        store.document.lastPrice = PriceQuote(priceUSD: 20_000, fetchedAt: clock.read(), source: "合成现价变化")
        store.priceError = "合成提示"
        _ = store.dailyProfitRows
        record(store.dailyProfitDerivationCount == warmCount && store.dailyProfitRows == originalRows,
            "repeated hover-style reads, current quotes and retry messages reuse fixed daily history")
        store.document.accounts[0].name += " · 合成更正"
        _ = store.dailyProfitRows
        record(store.dailyProfitDerivationCount == warmCount + 1,
            "account inputs invalidate cached daily derivation through the centralized document observer")
        store.document.entries[0].receivedSats *= 2
        store.document.entries[0].amountSats *= 2
        record(store.dailyProfitRows.allSatisfy { $0.profitUSD == 100 },
            "same-anchor historical holdings corrections replace cached profit without changing saved prices")
        store.document.dailyNoonObservations[2].priceUSD = 15_000
        record(store.dailyProfitRows.last?.profitUSD == 200,
            "a fixed-price observation change invalidates cached accounting rows")
        let beforeClock = store.dailyProfitDerivationCount
        clock.advance(86_389)
        _ = store.dailyProfitRows
        record(store.dailyProfitRows.count == 3 && store.dailyProfitDerivationCount == beforeClock,
            "time changes before a fractional settlement cutoff reuse the same completed-history cache")
        clock.advance(1)
        record(store.dailyProfitRows.count == 4 && store.dailyProfitDerivationCount == beforeClock + 1,
            "direct reads at the exact next cutoff derive its newly closed row without a service tick")
        clock.advance(-1)
        record(store.dailyProfitRows.count == 3 && store.dailyProfitDerivationCount == beforeClock + 2,
            "clock rollback excludes the reopened day rather than reusing a future cached row")
        var missing = store.document
        missing.dailyNoonObservations[2] = DailyNoonObservation(targetAt: targets[2], priceUSD: nil,
            fetchedAt: clock.read(), status: .missing)
        try store.restoreDocument(missing)
        record(store.dailyProfitRows.last?.status == .missingPrice,
            "backup restore invalidates the fixed-observation cache before its next read")
        let restarted = makeDailyStore(folder: folder, name: "derived-cache", clock: clock, probe: probe)
        record(restarted.dailyProfitRows == store.dailyProfitRows
               && restarted.dailyProfitSettlementAnchor == buy.date,
            "restart rebuilds only in-memory derived caches from the persisted ledger")
        store.document.entries.removeAll()
        record(store.dailyProfitRows.isEmpty && store.dailyProfitSettlementAnchor == nil,
            "direct deletion of the final purchase clears cached rows and settlement anchor")
    }

    @MainActor private static func checkDailyCurrencyRetries(folder: URL, settlement: Date) async throws {
        let clock = QADailyClock(settlement.addingTimeInterval(10))
        let prices = QADailyMarketProbe(clock: clock)
        let rates = QADailyCurrencyProbe()
        let store = AppStore(repositoryURL: folder.appendingPathComponent("currency-minute-retry.json"),
            rateProvider: { try await rates.rate($0) },
            priceProvider: { try await prices.price() },
            noonProvider: { try await prices.noon($0) },
            now: { clock.read() }, pause: { _ in await Task.yield() })
        // Let the empty-ledger startup migration finish before introducing the
        // isolated pending conversion, then establish one explicit failure.
        for _ in 0..<4 { await Task.yield() }
        var buy = try dailyBuy(store: store, at: settlement)
        buy.conversion = nil
        store.document.entries = [buy]
        store.document.dailyNoonObservations = [DailyNoonObservation(targetAt: settlement,
            priceUSD: 10_000, fetchedAt: clock.read())]
        record(store.dailyProfitRows.first?.status == .pendingCost,
            "the derived cache preserves unknown historical cost until a conversion succeeds")
        await store.completeCurrencyMigration()
        await store.refreshPrice()
        await waitForCurrencyAttempt(store, probe: rates, count: 2)
        for _ in 0..<59 { clock.advance(1); await store.serviceTick() }
        let firstMinuteRates = await rates.calls
        let firstMinutePrices = await prices.priceCalls
        record(firstMinuteRates == 2 && firstMinutePrices == 1,
            "fast historical FX failures do not retry on every one-second service tick")
        clock.advance(1)
        await store.serviceTick()
        await waitForCurrencyAttempt(store, probe: rates, count: 3)
        let nextMinuteRates = await rates.calls
        let nextMinutePrices = await prices.priceCalls
        record(nextMinuteRates == 3 && nextMinutePrices == 2,
            "automatic FX retry is tied to the next permitted minute quote request")
        await rates.configure(gateNext: true)
        clock.advance(60)
        await store.serviceTick()
        for _ in 0..<100 { if await rates.calls == 4 { break }; await Task.yield() }
        clock.advance(60)
        await store.serviceTick()
        record(await rates.calls == 4 && store.resolvingCurrency,
            "a slow FX request remains single even when another minute quote is allowed")
        await rates.release()
        await waitForCurrencyAttempt(store, probe: rates, count: 4)
        await rates.configure(failing: false)
        clock.advance(60)
        await store.serviceTick()
        await waitForCurrencyAttempt(store, probe: rates, count: 5)
        record(store.currencyError == nil && store.dailyProfitRows.first?.costUSD == 100
               && store.dailyProfitRows.first?.status == .available,
            "successful historical currency completion invalidates cached unknown cost and restores daily profit")
    }

    @MainActor private static func waitForCurrencyAttempt(_ store: AppStore, probe: QADailyCurrencyProbe, count: Int) async {
        for _ in 0..<200 {
            if await probe.calls >= count, !store.resolvingCurrency { return }
            await Task.yield()
        }
    }

    @MainActor private static func checkDailyDisplayFormatting(at date: Date) {
        func originalCurrency(_ value: Decimal?, code: String, symbol: String) -> String {
            guard let value else { return "—" }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .currency
            formatter.currencyCode = code
            formatter.currencySymbol = symbol
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
        }
        let values: [Decimal?] = [nil, 0, Decimal(string: "1234.567")!, Decimal(string: "-1234.567")!]
        record(values.allSatisfy {
            Display.money($0) == originalCurrency($0, code: "USD", symbol: "$")
                && Display.cny($0) == originalCurrency($0, code: "CNY", symbol: "¥")
        }, "reused fixed-locale USD/CNY formatters retain nil, signs, grouping and rounding")
        let originalDate = DateFormatter()
        originalDate.locale = Locale(identifier: "zh_CN")
        originalDate.timeZone = TimeZone(identifier: "Asia/Shanghai")
        originalDate.dateFormat = "yyyy-MM-dd HH:mm"
        record(Display.dateTime(date) == originalDate.string(from: date),
            "reused Shanghai timestamp formatter preserves its original locale and minute precision")
    }

    @MainActor private static func makeDailyStore(folder: URL, name: String, clock: QADailyClock,
                                                  probe: QADailyMarketProbe) -> AppStore {
        AppStore(repositoryURL: folder.appendingPathComponent("\(name).json"),
            rateProvider: { syntheticRate(asOf: $0) },
            priceProvider: { try await probe.price() },
            noonProvider: { try await probe.noon($0) },
            now: { clock.read() }, pause: { _ in await Task.yield() })
    }
    @MainActor private static func dailyBuy(store: AppStore, at date: Date) throws -> LedgerEntry {
        let rate = syntheticRate(asOf: date)
        let conversion = try PurchaseConversion.make(amountCNY: 700, rate: rate)
        return LedgerEntry(date: date, sequence: 1, kind: .buy, toAccountID: store.accounts[0].id,
            receivedSats: 1_000_000, amountCNY: 700, conversion: conversion)
    }
    @MainActor private static func settleDailyTasks(_ store: AppStore) async {
        for _ in 0..<200 {
            await Task.yield()
            if !store.dailyProfitRefreshing { await Task.yield(); if !store.dailyProfitRefreshing { break } }
        }
    }
    @MainActor private static func waitForNoonRequest(_ probe: QADailyMarketProbe) async {
        for _ in 0..<200 { if await !probe.noonDates.isEmpty { return }; await Task.yield() }
    }
}
