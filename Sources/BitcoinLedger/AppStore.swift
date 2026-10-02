import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LedgerCore

@MainActor
final class AppStore: ObservableObject {
    @Published var document: BackupDocument
    @Published var snapshot: LedgerSnapshot?
    @Published var startupError: String?
    @Published var message: String?
    @Published var priceError: String?
    @Published var refreshing = false
    @Published var isPresentingPanel = false
    @Published private(set) var resolvingCurrency = false
    @Published private(set) var currencyError: String?
    private var lastAttempt: Date?
    private let repository: LedgerRepository?
    private let rateProvider: @Sendable (Date) async throws -> USDExchangeRate

    init(rateProvider: @escaping @Sendable (Date) async throws -> USDExchangeRate = { try await ExchangeRateClient.rate(asOf: $0) }) {
        self.rateProvider = rateProvider
        let customPath = ProcessInfo.processInfo.environment["BITCOIN_LEDGER_DATA_PATH"]
        do {
            let storage = try LedgerRepository(url: customPath.map { URL(fileURLWithPath: $0) })
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
    func saveEntry(_ entry: LedgerEntry) throws {
        try commit(candidate(with: entry))
    }
    private func candidate(with entry: LedgerEntry) throws -> BackupDocument {
        guard entry.date <= Date().addingTimeInterval(60) else { throw UIError.text("记录时间不能晚于现在。") }
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
        if canEdit, currencyError != nil { Task { await completeCurrencyMigration() } }
        guard !refreshing, canEdit else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 { return }
        if !force, let quote {
            let age = Date().timeIntervalSince(quote.fetchedAt)
            if age >= 0 && age < 300 { return }
        }
        refreshing = true
        lastAttempt = Date()
        defer { refreshing = false }
        do {
            let result = try await PriceClient.fetch()
            var candidate = document
            candidate.lastPrice = result
            try commit(candidate)
            priceError = nil
        } catch {
            priceError = "刷新失败，保留上次成功价格。\(error.localizedDescription)"
        }
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
            guard incoming.entries.allSatisfy({ $0.date <= Date().addingTimeInterval(60) }) else {
                throw UIError.text("备份含有未来日期的记录，请检查日期。")
            }
            let alert = NSAlert()
            alert.messageText = "从备份恢复账本？"
            alert.informativeText = "将用 \(incoming.accounts.count) 个账户、\(incoming.entries.count) 条记录替换当前账本。继续前会自动保存当前账本副本。"
            alert.addButton(withTitle: "恢复")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let repository else { throw UIError.text("无法访问本机账本目录。") }
            let calculated = try LedgerEngine.calculate(accounts: incoming.accounts, entries: incoming.entries)
            // Imported legacy bytes must also survive independently of the migrated model.
            if try BackupCodec.schemaVersion(in: raw) < BackupDocument.currentSchemaVersion,
               let destination = repository.url?.deletingLastPathComponent() {
                let preserved = destination.appendingPathComponent("ledger.import-source-\(UUID().uuidString).json")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try raw.write(to: preserved, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preserved.path)
            }
            try repository.save(incoming, replacingCorruptStore: startupError != nil, preserveCurrent: true)
            document = incoming
            snapshot = calculated
            startupError = nil
            message = migrationNotice ?? "账本已恢复。"
            Task { await completeCurrencyMigration() }
        } catch { message = "恢复失败：\(error.localizedDescription)" }
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
    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
    static func money(_ value: Decimal?) -> String {
        currency(value, code: "USD", symbol: "$")
    }
    static func cny(_ value: Decimal?) -> String {
        currency(value, code: "CNY", symbol: "¥")
    }
    private static func currency(_ value: Decimal?, code: String, symbol: String) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.currencySymbol = symbol
        formatter.maximumFractionDigits = 2
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
