import Foundation
import Testing
@testable import LedgerCore

private func dailyDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private let dailyNoon = dailyDate("2026-10-01T04:00:00Z")
private let dailyAccount = Account.defaults[0]

private func dailyBuy(at date: Date, sats: Int64 = 100_000_000, cost: Decimal = 100,
                      sequence: Int64 = 0) -> LedgerEntry {
    syntheticEntry(date: date, sequence: sequence, kind: .buy, toAccountID: dailyAccount.id,
        receivedSats: sats, amountCNY: cost)
}
private func dailyPrice(at target: Date = dailyNoon, price: Decimal = 200) -> DailyNoonObservation {
    DailyNoonObservation(targetAt: target, priceUSD: price, fetchedAt: target.addingTimeInterval(30))
}
private func dailyDocument(entries: [LedgerEntry], observations: [DailyNoonObservation] = []) -> BackupDocument {
    BackupDocument(exportedAt: dailyNoon.addingTimeInterval(7 * 86_400), entries: entries,
        dailyNoonObservations: observations)
}

@Test func legacyNoonHelpersRemainAvailableForOldCacheFixtures() {
    let afterNoon = dailyBuy(at: dailyNoon.addingTimeInterval(3_600))
    let nextNoon = dailyNoon.addingTimeInterval(86_400)
    #expect(DailyProfitEngine.noonTargets(entries: [afterNoon], now: nextNoon.addingTimeInterval(-1)) == [dailyNoon])
    #expect(DailyProfitEngine.noonTargets(entries: [afterNoon], now: nextNoon) == [dailyNoon, nextNoon])
    #expect(DailyProfitEngine.noonTargets(entries: [dailyBuy(at: dailyNoon.addingTimeInterval(-3_600))],
        now: dailyNoon.addingTimeInterval(-1)).isEmpty)
    #expect(DailyProfitEngine.noonTargets(entries: [], now: nextNoon).isEmpty)
    // 20:00 UTC is already the next Shanghai calendar date.
    #expect(DailyProfitEngine.noon(on: dailyDate("2026-09-30T20:00:00Z")) == dailyNoon)
}

@Test func afternoonFirstPurchaseStartsAtItsOwnTimeAndIncludesItsHoldingAndCost() throws {
    let target = dailyNoon.addingTimeInterval(60)
    let document = dailyDocument(entries: [dailyBuy(at: target)], observations: [dailyPrice(at: target)])
    let row = try #require(DailyProfitEngine.rows(document: document, now: dailyNoon.addingTimeInterval(3_600)).first)
    #expect(row.date == target && row.totalSats == 100_000_000 && row.costUSD == 100)
    #expect(row.marketValueUSD == 200 && row.profitUSD == 100 && row.profitRatio == 1)
    #expect(row.status == .available && !row.isBeforeFirstPurchase)
}

@Test func dailyAccountingIncludesExactlyNoonTransactionsAndKeepsRatesRelativeToPrincipal() throws {
    let entries = [dailyBuy(at: dailyNoon),
        dailyBuy(at: dailyNoon, sats: 50_000_000, cost: 50, sequence: 1),
        dailyBuy(at: dailyNoon.addingTimeInterval(1), sats: 300_000_000, cost: 300, sequence: 2)]
    let row = try #require(DailyProfitEngine.rows(document: dailyDocument(entries: entries,
        observations: [dailyPrice()]), now: dailyNoon.addingTimeInterval(3_600)).first)
    #expect(row.totalSats == 150_000_000 && row.costUSD == 150 && row.marketValueUSD == 300)
    #expect(row.profitUSD == 150 && row.profitRatio == 1 && row.status == .available)
}

@Test func editingAndDeletingHistoricalEntriesReplaysAmountsWithoutReplacingSavedPrices() throws {
    let purchase = dailyBuy(at: dailyNoon)
    let tomorrow = dailyNoon.addingTimeInterval(86_400)
    var document = dailyDocument(entries: [purchase], observations: [dailyPrice(), dailyPrice(at: tomorrow, price: 250)])
    let before = try DailyProfitEngine.rows(document: document, now: tomorrow)
    #expect(before.map(\.profitUSD) == [100, 150])
    document.entries[0].receivedSats = 200_000_000
    document.entries[0].amountSats = 200_000_000
    document.entries[0].amountCNY = 120
    document.entries[0].conversion = try PurchaseConversion.make(amountCNY: 120,
        rate: document.entries[0].conversion!.rate)
    let corrected = try DailyProfitEngine.rows(document: document, now: tomorrow)
    #expect(corrected.map(\.profitUSD) == [280, 380])
    #expect(corrected.map(\.priceUSD) == [200, 250])
    document.entries.removeAll()
    #expect(try DailyProfitEngine.rows(document: document, now: tomorrow).isEmpty)
    #expect(document.dailyNoonObservations.map(\.priceUSD) == [200, 250])
}

@Test func unavailablePricesAndPurchaseConversionsStayExplicitAndDoNotBorrowAdjacentPrices() throws {
    let purchase = dailyBuy(at: dailyNoon)
    let tomorrow = dailyNoon.addingTimeInterval(86_400)
    let missing = DailyNoonObservation(targetAt: tomorrow, priceUSD: nil, fetchedAt: tomorrow, status: .missing)
    let document = dailyDocument(entries: [purchase], observations: [dailyPrice(), missing])
    let rows = try DailyProfitEngine.rows(document: document, now: tomorrow.addingTimeInterval(86_400))
    #expect(rows.map(\.status) == [.available, .missingPrice, .pendingPrice])
    #expect(rows[1].costUSD == 100 && rows[1].marketValueUSD == nil && rows[1].profitUSD == nil)
    #expect(rows[2].marketValueUSD == nil && rows[2].profitRatio == nil)
    var unconverted = purchase
    unconverted.conversion = nil
    let row = try #require(DailyProfitEngine.rows(document: dailyDocument(entries: [unconverted],
        observations: [dailyPrice()]), now: dailyNoon).first)
    #expect(row.costUSD == nil && row.marketValueUSD == 200 && row.profitUSD == nil && row.profitRatio == nil)
    #expect(row.status == .pendingCost)
}

@Test func noonReuseRequiresTheExactCompletedCoinbaseMinuteAndRejectsLiveDailyAndMixedSources() {
    let complete = MarketCandle(closeDate: dailyNoon, interval: 60, open: 190, high: 210, low: 180, close: 200)
    func history(_ candles: [MarketCandle], period: MarketPeriod = .minute,
                 provider: String = "Coinbase · BTC-USD 真实行情（美元）") -> MarketHistory {
        MarketHistory(range: .all, period: period, fetchedAt: dailyNoon.addingTimeInterval(30),
            candles: candles, source: provider)
    }
    #expect(DailyProfitEngine.reusableNoonObservation(targetAt: dailyNoon, history: history([complete]))?.priceUSD == 200)
    let invalid = [
        history([complete], period: .day),
        history([complete], provider: "Yahoo Finance / Coinbase · BTC-USD"),
        history([MarketCandle(closeDate: dailyNoon, interval: 60, open: 200, high: 200, low: 200, close: 200, hasOHLC: false)]),
        history([MarketCandle(closeDate: dailyNoon, interval: 60, open: 190, high: 210, low: 180, close: 200, isComplete: false)]),
        history([MarketCandle(closeDate: dailyNoon.addingTimeInterval(-60), interval: 60, open: 190, high: 210, low: 180, close: 200)]),
        history([MarketCandle(closeDate: dailyNoon, interval: 300, open: 190, high: 210, low: 180, close: 200)])]
    for candidate in invalid {
        #expect(DailyProfitEngine.reusableNoonObservation(targetAt: dailyNoon, history: candidate) == nil)
    }
}

private final class DailyRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; recorded.append(request) }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
}
private class DailyNoonProtocol: URLProtocol, @unchecked Sendable {
    class var empty: Bool { false }
    class var statusCode: Int { 200 }
    class var log: DailyRequestLog { CompleteDailyNoonProtocol.recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        type(of: self).log.append(request)
        let start = Int64(dailyNoon.addingTimeInterval(-60).timeIntervalSince1970)
        // The API can include the following minute at its end boundary. Only
        // the completed requested minute may be used.
        let text = type(of: self).empty ? "[]" : "[[\(start + 60),900,1200,1000,1100,1],[\(start),180,210,190,200,1]]"
        let response = HTTPURLResponse(url: request.url!, statusCode: type(of: self).statusCode,
            httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class CompleteDailyNoonProtocol: DailyNoonProtocol, @unchecked Sendable {
    static let recorded = DailyRequestLog()
}
private final class EmptyDailyNoonProtocol: DailyNoonProtocol, @unchecked Sendable {
    static let recorded = DailyRequestLog()
    override class var empty: Bool { true }
    override class var log: DailyRequestLog { recorded }
}
private final class FailedDailyNoonProtocol: DailyNoonProtocol, @unchecked Sendable {
    static let recorded = DailyRequestLog()
    override class var statusCode: Int { 503 }
    override class var log: DailyRequestLog { recorded }
}
private func dailySession(_ protocolClass: AnyClass) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    return URLSession(configuration: configuration)
}

@Test func noonFetchUsesOnePublicSixtySecondWindowAndNeverTheFollowingMinute() async throws {
    let session = dailySession(CompleteDailyNoonProtocol.self)
    defer { session.invalidateAndCancel() }
    let observation = try await DailyProfitEngine.fetchNoonObservation(targetAt: dailyNoon,
        client: MarketHistoryClient(session: session))
    #expect(observation.priceUSD == 200 && observation.status == .available)
    let requests = CompleteDailyNoonProtocol.recorded.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.host == "api.exchange.coinbase.com" && request.url?.path == "/products/BTC-USD/candles")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.httpBody == nil)
    let params = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        .map { ($0.name, $0.value ?? "") })
    #expect(params["granularity"] == "60")
    #expect(params["start"] == "2026-10-01T03:59:00Z" && params["end"] == "2026-10-01T04:00:00Z")
}

@Test func emptyNoonResponsePersistsAnExplicitMissingObservationWhileOutagesThrow() async throws {
    let empty = dailySession(EmptyDailyNoonProtocol.self)
    let failed = dailySession(FailedDailyNoonProtocol.self)
    defer { empty.invalidateAndCancel(); failed.invalidateAndCancel() }
    let observation = try await DailyProfitEngine.fetchNoonObservation(targetAt: dailyNoon,
        client: MarketHistoryClient(session: empty))
    #expect(observation.priceUSD == nil && observation.status == .missing)
    let document = dailyDocument(entries: [dailyBuy(at: dailyNoon.addingTimeInterval(-60))], observations: [observation])
    let restored = try #require(BackupCodec.decode(BackupCodec.encode(document)).dailyNoonObservations.first)
    #expect(restored.targetAt == observation.targetAt && restored.priceUSD == observation.priceUSD)
    #expect(restored.source == observation.source && restored.status == observation.status)
    #expect(abs(restored.fetchedAt.timeIntervalSince(observation.fetchedAt)) < 0.000001)
    await #expect(throws: (any Error).self) {
        try await DailyProfitEngine.fetchNoonObservation(targetAt: dailyNoon,
            client: MarketHistoryClient(session: failed))
    }
    #expect(EmptyDailyNoonProtocol.recorded.requests.count == 1 && FailedDailyNoonProtocol.recorded.requests.count == 1)
}

@Test func dailyPricesRoundTripExactlyAndSchemaFiveKeepsAllUSDInputs() throws {
    let price = Decimal(string: "200.123456789123456789")!
    var document = dailyDocument(entries: [dailyBuy(at: dailyNoon.addingTimeInterval(-60))], observations: [dailyPrice(price: price)])
    document.lastPrice = PriceQuote(priceUSD: 201, fetchedAt: dailyNoon, source: "合成当前行情")
    document.migrationReport = MigrationReport(sourceSchemaVersion: 1, sourceEntryCount: 0,
        migratedCount: 0, mappings: [], issues: [])
    #expect(try BackupCodec.decode(BackupCodec.encode(document)) == document)
    var old = try #require(JSONSerialization.jsonObject(with: BackupCodec.encode(document)) as? [String: Any])
    old["schemaVersion"] = 5
    old.removeValue(forKey: "dailyNoonObservations")
    let restored = try BackupCodec.decode(JSONSerialization.data(withJSONObject: old))
    #expect(restored.schemaVersion == BackupDocument.currentSchemaVersion && restored.entries == document.entries && restored.accounts == document.accounts)
    #expect(restored.exportedAt == document.exportedAt && restored.dailyNoonObservations.isEmpty)
    #expect(restored.lastPrice == document.lastPrice && restored.migrationReport == document.migrationReport)
}

@Test @MainActor func schemaFiveRepositoryUpgradePreservesOriginalBytesBeforeItsFirstWrite() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("daily-noon-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("ledger.json")
    let document = dailyDocument(entries: [dailyBuy(at: dailyNoon.addingTimeInterval(-60))])
    var object = try #require(JSONSerialization.jsonObject(with: BackupCodec.encode(document)) as? [String: Any])
    object["schemaVersion"] = 5
    object.removeValue(forKey: "dailyNoonObservations")
    let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    try original.write(to: url)
    let repository = try LedgerRepository(url: url)
    let migrated = try repository.load()
    #expect(repository.needsMigration && migrated.schemaVersion == BackupDocument.currentSchemaVersion)
    #expect(try Data(contentsOf: url) == original)
    #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1)
    try repository.save(migrated)
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("ledger.before-upgrade-v5-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
    #expect(try BackupCodec.decode(Data(contentsOf: url)) == migrated)
    try repository.save(migrated)
    #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("ledger.before-upgrade-v5-") }.count == 1)
}

@Test func dailyBackupRejectsDuplicateDatesBadStatusSourceAndNonNoonTargets() throws {
    let purchase = dailyBuy(at: dailyNoon.addingTimeInterval(-60))
    var invalidPrice = dailyPrice()
    invalidPrice.priceUSD = 0
    var wrongSource = dailyPrice()
    wrongSource.source = "Yahoo Finance / Coinbase · BTC-USD"
    var wrongTime = dailyPrice()
    wrongTime.source = DailyProfitEngine.legacyNoonSource
    wrongTime.targetAt = dailyNoon.addingTimeInterval(60)
    wrongTime.fetchedAt = wrongTime.targetAt
    var wrongStatus = dailyPrice()
    wrongStatus.status = .missing
    for observations in [[dailyPrice(), dailyPrice()], [invalidPrice], [wrongSource], [wrongTime], [wrongStatus]] {
        #expect(throws: (any Error).self) { try BackupCodec.encode(dailyDocument(entries: [purchase], observations: observations)) }
    }
    var object = try #require(JSONSerialization.jsonObject(with: BackupCodec.encode(dailyDocument(entries: [purchase], observations: [dailyPrice()]))) as? [String: Any])
    var observations = try #require(object["dailyNoonObservations"] as? [[String: Any]])
    observations[0]["priceUSD"] = 200
    object["dailyNoonObservations"] = observations
    #expect(throws: (any Error).self) { try BackupCodec.decode(JSONSerialization.data(withJSONObject: object)) }
}

@Test func dailyCSVIsSeparateAndKeepsMissingValuesBlankWithStableShanghaiDates() throws {
    let document = dailyDocument(entries: [dailyBuy(at: dailyNoon)], observations: [dailyPrice()])
    let data = try BackupCodec.dailyProfitCSV(document, now: dailyNoon.addingTimeInterval(86_400))
    #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
    let csv = try #require(String(data: data, encoding: .utf8))
    #expect(csv.contains("date_shanghai,settlement_utc") && !csv.contains("noon_utc"))
    #expect(csv.contains("2026-10-01,2026-10-01T04:00:00.000Z,100000000,1,100,200,100,1,200,available"))
    #expect(csv.contains("2026-10-02,2026-10-02T04:00:00.000Z,100000000,1,100,,,,,pendingPrice"))
    let transactionCSV = try #require(String(data: BackupCodec.csv(document), encoding: .utf8))
    #expect(transactionCSV.contains("date_utc,sequence,kind") && !transactionCSV.contains("profit_usd"))
}
