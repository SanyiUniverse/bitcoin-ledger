import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LedgerCore

@MainActor
final class AppStore: ObservableObject {
    @Published var document: BackupDocument {
        didSet { documentDidChange(from: oldValue) }
    }
    @Published var snapshot: LedgerSnapshot?
    @Published var startupError: String?
    @Published var message: String?
    @Published var priceError: String?
    @Published private(set) var priceRetryAt: Date?
    @Published var refreshing = false
    @Published private(set) var dailyProfitRefreshing = false
    @Published private(set) var dailyProfitError: String?
    @Published private(set) var dailyProfitProgress: String?
    @Published private(set) var dailyProfitRetryAt: Date?
    @Published var isPresentingPanel = false
    @Published private(set) var resolvingCurrency = false
    @Published private(set) var currencyError: String?
    private var lastAttempt: Date?
    private var priceFailures = 0
    private var priceAutomaticSuspended = false
    private var priceRequest: Task<PriceQuote, Error>?
    private var dailyTask: Task<Void, Never>?
    private var dailyFailures = 0
    private var dailyLastAttemptDay: Date?
    private var dailyScheduledThrough: Date?
    private var dailyNeedsAnotherPass = false
    private var generation = 0
    private var dailyGeneration = 0
    private var servicesRunning = false
    private var firstPurchase: LedgerEntry?
    private var dailyHistoryRevision = 0
    private var dailyRowsCache: (revision: Int, through: Date?, rows: [DailyProfitRow])?
    private(set) var dailyProfitDerivationCount = 0
    private let repository: LedgerRepository?
    private let rateProvider: @Sendable (Date) async throws -> USDExchangeRate
    private let priceProvider: @Sendable () async throws -> PriceQuote
    private let noonProvider: @Sendable (Date) async throws -> DailyNoonObservation
    private let now: @Sendable () -> Date
    private let pause: @Sendable (TimeInterval) async throws -> Void

    init(repositoryURL: URL? = nil,
         rateProvider: @escaping @Sendable (Date) async throws -> USDExchangeRate = { try await ExchangeRateClient.rate(asOf: $0) },
         priceProvider: @escaping @Sendable () async throws -> PriceQuote = { try await PriceClient.fetch() },
         noonProvider: @escaping @Sendable (Date) async throws -> DailyNoonObservation = { try await DailyProfitEngine.fetchNoonObservation(targetAt: $0) },
         now: @escaping @Sendable () -> Date = { Date() },
         pause: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.rateProvider = rateProvider
        self.priceProvider = priceProvider
        self.noonProvider = noonProvider
        self.now = now
        self.pause = pause
        let customPath = ProcessInfo.processInfo.environment["BITCOIN_LEDGER_DATA_PATH"]
        do {
            let storage = try LedgerRepository(url: repositoryURL ?? customPath.map { URL(fileURLWithPath: $0) })
            repository = storage
            do {
                document = try storage.load()
                snapshot = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
                if storage.needsMigration { try storage.save(document) }
            } catch {
                document = BackupDocument()
                startupError = "账本未能读取：\(error.localizedDescription)\n原文件已保留。请从 JSON 备份恢复后继续。"
            }
        } catch {
            repository = nil
            document = BackupDocument()
            startupError = "无法访问本机账本目录：\(error.localizedDescription)"
        }
        firstPurchase = document.entries.filter { $0.kind == .buy }.min { $0.date < $1.date }
        if canEdit { Task { await completeCurrencyMigration() } }
    }
    var accounts: [Account] { document.accounts }
    var entries: [LedgerEntry] {
        document.entries.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.sequence != $1.sequence { return $0.sequence > $1.sequence }
            return $0.id.uuidString > $1.id.uuidString
        }
    }
    var quote: PriceQuote? { document.lastPrice }
    var dailyProfitRows: [DailyProfitRow] {
        let instant = now()
        let through = latestClosedSettlement(at: instant)
        if let cache = dailyRowsCache, cache.revision == dailyHistoryRevision, cache.through == through {
            return cache.rows
        }
        let rows = (try? DailyProfitEngine.rows(document: document, now: instant)) ?? []
        dailyProfitDerivationCount += 1
        dailyRowsCache = (dailyHistoryRevision, through, rows)
        return rows
    }
    var dailyProfitNow: Date { now() }
    var dailyProfitSettlementAnchor: Date? { firstPurchase?.date }
    var dailyProfitSettlementToday: Date? { settlement(on: now()) }
    var canEdit: Bool { startupError == nil }
    var migrationNotice: String? {
        var notices: [String] = []
        if let report = document.migrationReport, !report.issues.isEmpty {
            notices.append("有 \(report.issues.count) 条旧记录无法可靠迁入；当前统计只包含已迁入的购买和转移。原始账本已备份，详情见迁移报告。")
        }
        let pending = document.entries.filter { $0.kind == .buy && $0.conversion == nil }.count
        if pending > 0 {
            notices.append("\(pending) 条购买等待按购买时间的历史汇率换算美元，期间美元投入、成本与盈亏显示 —。" + (currencyError.map { " \($0)" } ?? ""))
        }
        return notices.isEmpty ? nil : notices.joined(separator: "\n")
    }
    func accountName(_ id: UUID?) -> String { document.accounts.first { $0.id == id }?.name ?? "—" }
    func commit(_ candidate: BackupDocument) throws {
        guard canEdit else { throw UIError.text("请先恢复无法读取的账本。") }
        guard let repository else { throw UIError.text("无法访问本机账本目录。") }
        let calculated = try LedgerEngine.calculate(accounts: candidate.accounts, entries: candidate.entries)
        try repository.save(candidate)
        document = candidate
        snapshot = calculated
    }
    private func documentDidChange(from previous: BackupDocument) {
        let entriesChanged = previous.entries != document.entries
        let previousAnchor = firstPurchase?.date
        if entriesChanged {
            firstPurchase = document.entries.filter { $0.kind == .buy }.min { $0.date < $1.date }
        }
        if entriesChanged || previous.accounts != document.accounts
            || previous.dailyNoonObservations != document.dailyNoonObservations {
            dailyHistoryRevision += 1
            dailyRowsCache = nil
        }
        let anchorChanged = previousAnchor != firstPurchase?.date
        let hadDailyRequest = dailyProfitRefreshing
        if anchorChanged { invalidateDailyNetworkTasks() }
        if entriesChanged {
            // Prices are immutable observations; corrected holdings/costs are derived
            // from the latest ledger. A running backfill merges into this document.
            dailyScheduledThrough = nil
            dailyLastAttemptDay = nil
            if anchorChanged, hadDailyRequest || servicesRunning {
                Task { await refreshDailyProfit(forceMissing: true) }
            } else if dailyProfitRefreshing { dailyNeedsAnotherPass = true }
            else if servicesRunning { Task { await refreshDailyProfit() } }
        }
    }
    private func settlement(on date: Date) -> Date? {
        guard let firstPurchase else { return nil }
        // Reuse the core's precise first-day/fractional-second calculation with
        // the cached anchor instead of scanning the complete ledger every tick.
        return DailyProfitEngine.settlement(on: date, entries: [firstPurchase])
    }
    private func latestClosedSettlement(at instant: Date) -> Date? {
        guard let firstPurchase, let cutoff = settlement(on: instant) else { return nil }
        let latest: Date?
        if cutoff <= instant { latest = cutoff }
        else {
            let day = DailyProfitEngine.calendar.startOfDay(for: instant)
            latest = DailyProfitEngine.calendar.date(byAdding: .day, value: -1, to: day).flatMap { settlement(on: $0) }
        }
        return latest.flatMap { $0 >= firstPurchase.date ? $0 : nil }
    }
    func saveEntry(_ entry: LedgerEntry) throws {
        try commit(candidate(with: entry))
    }
    private func candidate(with entry: LedgerEntry) throws -> BackupDocument {
        guard entry.date <= now().addingTimeInterval(60) else { throw UIError.text("记录时间不能晚于现在。") }
        var candidate = document
        if let i = candidate.entries.firstIndex(where: { $0.id == entry.id }) { candidate.entries[i] = entry }
        else { candidate.entries.append(entry) }
        return candidate
    }
    func saveEntryResolvingCurrency(_ entry: LedgerEntry) async throws {
        guard canEdit else { throw UIError.text("请先恢复无法读取的账本。") }
        let original = document.entries.first { $0.id == entry.id }
        let draft = try candidate(with: entry)
        _ = try LedgerEngine.calculate(accounts: draft.accounts, entries: draft.entries)
        var resolved = entry
        if entry.kind == .buy {
            if let previous = original, previous.kind == .buy, previous.date == entry.date, previous.amountCNY == entry.amountCNY,
               let conversion = previous.conversion {
                resolved.conversion = conversion
            } else {
                let rate = try await rateProvider(entry.date)
                try Task.checkCancellation()
                resolved.conversion = try PurchaseConversion.make(amountCNY: entry.amountCNY, rate: rate)
            }
        }
        try Task.checkCancellation()
        guard document.entries.first(where: { $0.id == entry.id }) == original else {
            throw UIError.text("这条记录已在换算期间被修改或删除，请重新打开后再保存。")
        }
        try saveEntry(resolved)
    }
    /// Missing legacy conversions remain intact unless every requested rate succeeds.
    func completeCurrencyMigration() async {
        guard canEdit, !resolvingCurrency else { return }
        let pending = document.entries.filter { $0.kind == .buy && $0.conversion == nil }
        guard !pending.isEmpty else { return }
        resolvingCurrency = true
        currencyError = nil
        defer {
            resolvingCurrency = false
            // An import or edit during the request can introduce different pending rows.
            let changedPending = document.entries.contains { current in
                current.kind == .buy && current.conversion == nil
                && !pending.contains { $0.id == current.id && $0.date == current.date && $0.amountCNY == current.amountCNY }
            }
            if changedPending { Task { await completeCurrencyMigration() } }
        }
        do {
            var conversions: [UUID: PurchaseConversion] = [:]
            for entry in pending {
                let rate = try await rateProvider(entry.date)
                try Task.checkCancellation()
                conversions[entry.id] = try PurchaseConversion.make(amountCNY: entry.amountCNY, rate: rate)
            }
            var candidate = document
            for original in pending {
                guard let index = candidate.entries.firstIndex(where: { $0.id == original.id }),
                      candidate.entries[index].date == original.date,
                      candidate.entries[index].amountCNY == original.amountCNY,
                      candidate.entries[index].conversion == nil else { continue }
                candidate.entries[index].conversion = conversions[original.id]
            }
            try Task.checkCancellation()
            try commit(candidate)
        } catch is CancellationError {
        } catch {
            currencyError = "换算未完成，原记录保留。\(error.localizedDescription)"
        }
    }
    func deleteEntry(_ entry: LedgerEntry) throws {
        var candidate = document
        candidate.entries.removeAll { $0.id == entry.id }
        try commit(candidate)
    }
    func refreshPrice(force: Bool = false) async {
        guard !refreshing, canEdit else { return }
        guard force || !priceAutomaticSuspended else { return }
        let attemptedAt = now()
        let retryDue = priceRetryAt.map { $0 <= attemptedAt } ?? false
        if let priceRetryAt, priceRetryAt > attemptedAt { return }
        if !retryDue, let lastAttempt, attemptedAt.timeIntervalSince(lastAttempt) < 60 { return }
        if !force, let quote {
            let age = attemptedAt.timeIntervalSince(quote.fetchedAt)
            if !retryDue, age >= 0 && age < 60 { return }
        }
        if currencyError != nil { Task { await completeCurrencyMigration() } }
        refreshing = true
        lastAttempt = attemptedAt
        priceRetryAt = nil
        let requestGeneration = generation
        let provider = priceProvider
        let task = Task { try await provider() }
        priceRequest = task
        defer {
            if generation == requestGeneration { refreshing = false; priceRequest = nil }
        }
        do {
            let result = try await task.value
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            var candidate = document
            candidate.lastPrice = result
            try commit(candidate)
            priceError = nil
            priceFailures = 0
            priceAutomaticSuspended = false
        } catch is CancellationError {
        } catch {
            guard generation == requestGeneration else { return }
            priceError = "刷新失败，保留上次成功价格。\(error.localizedDescription)"
            priceFailures += 1
            priceRetryAt = MarketRetryPolicy.deadline(for: error, failureCount: priceFailures, now: now())
            priceAutomaticSuspended = priceRetryAt == nil
        }
    }

    /// A single lifecycle loop coordinates minute quotes, retry deadlines and
    /// first-purchase-time settlement. The UI owns no independent quote polling timer.
    func runServices() async {
        guard !servicesRunning else { return }
        servicesRunning = true
        defer { servicesRunning = false }
        while !Task.isCancelled {
            await serviceTick()
            do { try await pause(1) } catch { break }
        }
    }

    func servicesDidBecomeActive() async {
        priceAutomaticSuspended = false
        await serviceTick()
    }

    func serviceTick() async {
        guard canEdit else { return }
        let instant = now()
        let day = DailyProfitEngine.calendar.startOfDay(for: instant)
        let newestSettlement = latestClosedSettlement(at: instant)
        let retryDue = dailyProfitRetryAt.map { $0 <= instant } ?? false
        if !dailyProfitRefreshing, dailyProfitRetryAt == nil || retryDue {
            if retryDue || dailyLastAttemptDay != day || dailyScheduledThrough != newestSettlement {
                Task { await refreshDailyProfit(forceMissing: true) }
            }
        }
        await refreshPrice()
    }

    func refreshDailyProfit(forceMissing: Bool = false) async {
        guard canEdit, !dailyProfitRefreshing else { return }
        if let dailyProfitRetryAt, dailyProfitRetryAt > now() { return }
        dailyProfitRefreshing = true
        dailyProfitError = nil
        dailyProfitRetryAt = nil
        dailyNeedsAnotherPass = false
        let requestGeneration = dailyGeneration
        let task = Task { await performDailyRefresh(forceMissing: forceMissing, requestGeneration: requestGeneration) }
        dailyTask = task
        await task.value
        guard dailyGeneration == requestGeneration else { return }
        dailyTask = nil
        dailyProfitRefreshing = false
        if dailyNeedsAnotherPass {
            dailyNeedsAnotherPass = false
            Task { await refreshDailyProfit() }
        }
    }

    private func performDailyRefresh(forceMissing: Bool, requestGeneration: Int) async {
        let startedAt = now()
        dailyLastAttemptDay = DailyProfitEngine.calendar.startOfDay(for: startedAt)
        let targets = DailyProfitEngine.settlementTargets(entries: document.entries, now: startedAt)
        let validTargets = Set(targets)
        dailyScheduledThrough = targets.last
        let zeroDays = Set(dailyProfitRows.filter { $0.totalSats == 0 }.map(\.date))
        let saved = Dictionary(uniqueKeysWithValues: document.dailyNoonObservations.map { ($0.targetAt, $0) })
        let recentSettlementMissing = { (target: Date, observation: DailyNoonObservation?) in
            observation?.status == .missing && startedAt < target.addingTimeInterval(300)
        }
        let needed = targets.reversed().filter { target in
            guard !zeroDays.contains(target), saved[target]?.status != .available else { return false }
            return saved[target] == nil || forceMissing || recentSettlementMissing(target, saved[target])
        }
        let reusable = reusableNoonPrices(targets: Set(needed))
        var completed = 0
        dailyProfitProgress = needed.isEmpty ? nil : "正在补齐每日结算记录：0 / \(needed.count) 天"
        do {
            for target in needed {
                try Task.checkCancellation()
                guard dailyGeneration == requestGeneration else { return }
                if completed > 0, reusable[target] == nil { try await pause(0.5) }
                let observation: DailyNoonObservation
                if let cached = reusable[target] { observation = cached }
                else { observation = try await noonProvider(target) }
                try Task.checkCancellation()
                guard dailyGeneration == requestGeneration else { return }
                // Anchor edits/imports invalidate dailyGeneration. Other edits
                // keep these targets; a clock rollback can still unclose one.
                if validTargets.contains(target), target <= now() {
                    guard observation.targetAt == target, observation.fetchedAt <= now().addingTimeInterval(60) else {
                        throw UIError.text("每日行情的结算时间或获取时间不匹配。")
                    }
                    var candidate = document
                    if candidate.dailyNoonObservations.first(where: { $0.targetAt == target })?.status != .available {
                        candidate.dailyNoonObservations.removeAll { $0.targetAt == target }
                        candidate.dailyNoonObservations.append(observation)
                        candidate.dailyNoonObservations.sort { $0.targetAt < $1.targetAt }
                        try commit(candidate)
                    }
                    if observation.status == .missing, now() < target.addingTimeInterval(300) {
                        let next = min(now().addingTimeInterval(60), target.addingTimeInterval(300))
                        dailyProfitRetryAt = dailyProfitRetryAt.map { min($0, next) } ?? next
                    }
                }
                completed += 1
                dailyFailures = 0
                dailyProfitProgress = "正在补齐每日结算记录：\(completed) / \(needed.count) 天"
            }
            dailyProfitProgress = nil
        } catch is CancellationError {
            if dailyGeneration == requestGeneration { dailyProfitProgress = nil }
        } catch {
            guard dailyGeneration == requestGeneration else { return }
            dailyProfitError = "每日结算记录尚未补齐，已保存的数据保留。\(error.localizedDescription)"
            dailyProfitProgress = completed > 0 ? "已补齐 \(completed) / \(needed.count) 天" : nil
            dailyFailures += 1
            dailyProfitRetryAt = MarketRetryPolicy.deadline(for: error, failureCount: dailyFailures, now: now())
        }
    }

    private func reusableNoonPrices(targets: Set<Date>) -> [Date: DailyNoonObservation] {
        guard !targets.isEmpty else { return [:] }
        var result: [Date: DailyNoonObservation] = [:]
        let savedByMinute = Dictionary(grouping: document.dailyNoonObservations.filter {
            $0.status == .available && $0.fetchedAt <= now().addingTimeInterval(60)
        }, by: \.priceCloseAt)
        for target in targets {
            let closeAt = DailyProfitEngine.completedMinuteClose(for: target)
            if let observation = DailyProfitEngine.reusableNoonObservation(targetAt: target,
                observations: savedByMinute[closeAt] ?? []) {
                result[target] = observation
            }
        }
        guard let directory = repository?.url?.deletingLastPathComponent() else { return result }
        // Aggregated periods cannot supply an exact one-minute closing price.
        for period in [MarketPeriod.minute] {
            let url = directory.appendingPathComponent(BTCChartModel.fileName(period: period))
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 8_000_000, let bytes = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(BTCMarketCacheRecord.self, from: bytes),
                  record.period == .minute, record.history.fetchedAt <= now().addingTimeInterval(60) else { continue }
            for target in targets where result[target] == nil {
                let closeAt = DailyProfitEngine.completedMinuteClose(for: target)
                guard closeAt >= record.from && closeAt <= record.through else { continue }
                if let observation = DailyProfitEngine.reusableNoonObservation(targetAt: target, history: record.history) {
                    result[target] = observation
                }
            }
        }
        return result
    }

    private func invalidateNetworkTasks() {
        generation += 1
        priceRequest?.cancel(); priceRequest = nil
        refreshing = false
        priceRetryAt = nil
        priceError = nil
        lastAttempt = nil
        priceFailures = 0
        priceAutomaticSuspended = false
        invalidateDailyNetworkTasks()
    }

    private func invalidateDailyNetworkTasks() {
        dailyGeneration += 1
        dailyTask?.cancel(); dailyTask = nil
        dailyProfitRefreshing = false
        dailyProfitRetryAt = nil
        dailyProfitError = nil
        dailyProfitProgress = nil
        dailyFailures = 0
        dailyLastAttemptDay = nil
        dailyScheduledThrough = nil
        dailyNeedsAnotherPass = false
    }
    func exportJSON() {
        do {
            var backup = document
            backup.exportedAt = Date()
            try export(data: BackupCodec.encode(backup), name: "Bitcoin-Ledger-\(Self.dateStamp).json", type: .json)
        } catch { message = error.localizedDescription }
    }
    func exportCSV() {
        do { try export(data: BackupCodec.csv(document), name: "Bitcoin-Ledger-History-\(Self.dateStamp).csv", type: .commaSeparatedText) }
        catch { message = error.localizedDescription }
    }
    private func export(data: Data, name: String, type: UTType) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
        message = "已导出：\(url.lastPathComponent)"
    }
    func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= BackupCodec.maximumBytes else { throw UIError.text("备份文件超过 20 MB。") }
            let raw = try Data(contentsOf: url)
            let incoming = try BackupCodec.decode(raw)
            guard incoming.entries.allSatisfy({ $0.date <= now().addingTimeInterval(60) }) else {
                throw UIError.text("备份含有未来日期的记录，请检查日期。")
            }
            let alert = NSAlert()
            alert.messageText = "从备份恢复账本？"
            alert.informativeText = "将用 \(incoming.accounts.count) 个账户、\(incoming.entries.count) 条记录替换当前账本。继续前会自动保存当前账本副本。"
            alert.addButton(withTitle: "恢复")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try restoreDocument(incoming, sourceData: raw)
            message = migrationNotice ?? "账本已恢复。"
            Task { await completeCurrencyMigration(); await serviceTick() }
        } catch { message = "恢复失败：\(error.localizedDescription)" }
    }

    /// Kept separate from the native picker/confirmation so isolated checks can
    /// verify restore cancellation and the exact save-before-publish boundary.
    func restoreDocument(_ incoming: BackupDocument, sourceData: Data? = nil) throws {
        let instant = now()
        guard incoming.entries.allSatisfy({ $0.date <= instant.addingTimeInterval(60) }) else {
            throw UIError.text("备份含有未来日期的记录，请检查日期。")
        }
        guard incoming.dailyNoonObservations.allSatisfy({
            $0.targetAt <= instant && $0.fetchedAt <= instant.addingTimeInterval(60)
        }) else {
            throw UIError.text("备份含有未来的每日结算行情记录或获取时间，请检查日期。")
        }
        guard let repository else { throw UIError.text("无法访问本机账本目录。") }
        let calculated = try LedgerEngine.calculate(accounts: incoming.accounts, entries: incoming.entries)
        // Imported legacy bytes survive independently of the migrated model.
        if let raw = sourceData, try BackupCodec.schemaVersion(in: raw) < BackupDocument.currentSchemaVersion,
           let destination = repository.url?.deletingLastPathComponent() {
            let preserved = destination.appendingPathComponent("ledger.import-source-\(UUID().uuidString).json")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try raw.write(to: preserved, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preserved.path)
        }
        try repository.save(incoming, replacingCorruptStore: startupError != nil, preserveCurrent: true)
        invalidateNetworkTasks()
        document = incoming
        snapshot = calculated
        startupError = nil
    }
    static var dateStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

enum UIError: LocalizedError {
    case text(String)
    var errorDescription: String? { if case .text(let text) = self { text } else { nil } }
}

enum Display {
    @MainActor private static let shanghaiDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    @MainActor private static let usd = currencyFormatter(code: "USD", symbol: "$")
    @MainActor private static let yuan = currencyFormatter(code: "CNY", symbol: "¥")
    @MainActor static func dateTime(_ date: Date) -> String { shanghaiDateTime.string(from: date) }
    @MainActor static func money(_ value: Decimal?) -> String { currency(value, formatter: usd) }
    @MainActor static func cny(_ value: Decimal?) -> String { currency(value, formatter: yuan) }
    @MainActor private static func currencyFormatter(code: String, symbol: String) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.currencySymbol = symbol
        formatter.maximumFractionDigits = 2
        return formatter
    }
    @MainActor private static func currency(_ value: Decimal?, formatter: NumberFormatter) -> String {
        guard let value else { return "—" }
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    static func btc(_ sats: Int64) -> String { String(format: "%lld.%08lld", sats / 100_000_000, abs(sats % 100_000_000)) }
    static func decimal(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func percent(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
}

extension EntryKind {
    var title: String { self == .buy ? "购买" : "转移" }
    var icon: String { self == .buy ? "arrow.down.left" : "arrow.left.arrow.right" }
}
