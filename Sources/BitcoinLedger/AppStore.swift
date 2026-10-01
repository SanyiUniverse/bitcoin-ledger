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
    private var lastAttempt: Date?
    private let repository: LedgerRepository?

    init() {
        let customPath = ProcessInfo.processInfo.environment["BITCOIN_LEDGER_DATA_PATH"]
        do {
            let storage = try LedgerRepository(url: customPath.map { URL(fileURLWithPath: $0) })
            repository = storage
            do {
                document = try storage.load()
                snapshot = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
            } catch {
                document = BackupDocument(accounts: [], entries: [])
                startupError = "账本未能读取：\(error.localizedDescription)\n原文件已保留。请从 JSON 备份恢复后继续。"
            }
        } catch {
            repository = nil
            document = BackupDocument(accounts: [], entries: [])
            startupError = "无法访问本机账本目录：\(error.localizedDescription)"
        }
    }
    var accounts: [Account] { document.accounts.filter { !$0.isArchived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var entries: [LedgerEntry] { document.entries.sorted { $0.date == $1.date ? $0.sequence > $1.sequence : $0.date > $1.date } }
    var quote: PriceQuote? { document.lastPrice }
    var canEdit: Bool { startupError == nil }
    func accountName(_ id: UUID?) -> String { document.accounts.first { $0.id == id }?.name ?? "—" }
    func valuation(for entry: LedgerEntry) -> EntryValuation? { snapshot?.entryValuations[entry.id] }
    func commit(_ candidate: BackupDocument) throws {
        guard canEdit else { throw UIError.text("请先恢复无法读取的账本。") }
        guard let repository else { throw UIError.text("无法访问本机账本目录。") }
        let calculated = try LedgerEngine.calculate(accounts: candidate.accounts, entries: candidate.entries)
        try repository.save(candidate)
        document = candidate
        snapshot = calculated
    }
    func saveAccount(_ account: Account) throws {
        var candidate = document
        if let i = candidate.accounts.firstIndex(where: { $0.id == account.id }) { candidate.accounts[i] = account }
        else { candidate.accounts.append(account) }
        try commit(candidate)
    }
    func deleteAccount(_ account: Account) throws {
        guard snapshot?.balances[account.id, default: 0] == 0 else {
            throw UIError.text("只能删除 BTC 余额为零的账户。")
        }
        var candidate = document
        if document.entries.contains(where: { $0.fromAccountID == account.id || $0.toAccountID == account.id }) {
            if let index = candidate.accounts.firstIndex(where: { $0.id == account.id }) {
                candidate.accounts[index].isArchived = true
            }
        } else {
            candidate.accounts.removeAll { $0.id == account.id }
        }
        try commit(candidate)
    }
    func saveEntry(_ entry: LedgerEntry) throws {
        guard entry.date <= Date().addingTimeInterval(60) else { throw UIError.text("记录时间不能晚于现在。") }
        var candidate = document
        if let i = candidate.entries.firstIndex(where: { $0.id == entry.id }) { candidate.entries[i] = entry }
        else { candidate.entries.append(entry) }
        try commit(candidate)
    }
    /// A reconciliation stores the observed balance as an anchor. Its actual
    /// before/after projection comes from the same replay used by save/import.
    func prepareUSDTAdjustment(to target: Decimal, note: String, existing: LedgerEntry? = nil,
                               id: UUID = UUID(), date: Date = Date()) throws -> (entry: LedgerEntry, valuation: EntryValuation) {
        guard canEdit else { throw UIError.text("请先恢复无法读取的账本。") }
        if let existing {
            guard existing.kind == .adjustUSDT, document.entries.contains(where: { $0.id == existing.id }) else {
                throw UIError.text("这条余额调整已不存在，请关闭后重新打开。")
            }
        }
        let next = (document.entries.map(\.sequence).max() ?? 0).addingReportingOverflow(1)
        guard existing != nil || (!next.overflow && next.partialValue < Int64.max) else {
            throw UIError.text("记录顺序超过支持范围。")
        }
        var entry = LedgerEntry(id: existing?.id ?? id, date: existing?.date ?? date,
                                sequence: existing?.sequence ?? next.partialValue,
                                kind: .adjustUSDT, feeCategory: .other,
                                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                amountUSDT: existing?.amountUSDT ?? 0, receivedUSDT: target)
        var entries = document.entries.filter { $0.id != entry.id }
        entries.append(entry)
        let replay = try LedgerEngine.calculate(accounts: document.accounts, entries: entries)
        guard let valuation = replay.entryValuations[entry.id], let before = valuation.beforeUSDT else {
            throw UIError.text("无法计算余额调整，请重新打开账本后再试。")
        }
        // Keep the initially observed book balance for audit; it is never used
        // as a cached balance during subsequent historical replay.
        entry.amountUSDT = existing?.amountUSDT ?? before
        return (entry, valuation)
    }
    func deleteEntry(_ entry: LedgerEntry) throws {
        var candidate = document
        candidate.entries.removeAll { $0.id == entry.id }
        try commit(candidate)
    }
    func refreshPrice(force: Bool = false) async {
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
            try export(data: BackupCodec.encode(backup), name: "Bitcoin-Ledger-\(Self.dateStamp).json", type: .json) }
        catch { message = error.localizedDescription }
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
            let incoming = try BackupCodec.decode(Data(contentsOf: url))
            guard incoming.entries.allSatisfy({ $0.date <= Date().addingTimeInterval(60) }) else {
                throw UIError.text("备份含有未来日期的记录；当前版本不支持预记账，请检查日期。")
            }
            let alert = NSAlert()
            alert.messageText = "从备份恢复账本？"
            alert.informativeText = "将用 \(incoming.accounts.count) 个账户、\(incoming.entries.count) 条记录替换当前账本。继续前会自动保存当前账本副本。"
            alert.addButton(withTitle: "恢复")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let repository else { throw UIError.text("无法访问本机账本目录。") }
            let calculated = try LedgerEngine.calculate(accounts: incoming.accounts, entries: incoming.entries)
            try repository.save(incoming, replacingCorruptStore: startupError != nil, preserveCurrent: true)
            document = incoming
            snapshot = calculated
            startupError = nil
            message = "账本已恢复。"
        } catch { message = "恢复失败：\(error.localizedDescription)" }
    }
    static var dateStamp: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: Date())
    }
}

enum UIError: LocalizedError {
    case text(String)
    var errorDescription: String? { if case .text(let text) = self { text } else { nil } }
}

enum Display {
    static func money(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    static func btc(_ sats: Int64) -> String { String(format: "%lld.%08lld", sats / 100_000_000, abs(sats % 100_000_000)) }
    static func usdt(_ value: Decimal) -> String { Amounts.string(value) }
    static func decimal(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    static func percent(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter(); formatter.numberStyle = .percent; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    static func fee(_ entry: LedgerEntry) -> String {
        switch entry.feeCurrency {
        case .btc: "\(btc(entry.feeSats)) BTC"
        case .usdt: "\(usdt(entry.feeUSDT)) USDT"
        case .cny: money(entry.feeCNY)
        }
    }
}

extension AccountKind {
    var title: String { self == .selfCustody ? "自托管钱包" : "交易所" }
    var english: String { self == .selfCustody ? "Self-custody" : "Exchanges" }
    var icon: String { self == .selfCustody ? "wallet.bifold" : "building.columns" }
}
extension EntryKind {
    var title: String { switch self { case .buy: "买入 BTC"; case .transfer: "转账"; case .sell: "卖出 / 花费 BTC"; case .fee: "其他手续费"; case .buyUSDT: "人民币买 USDT"; case .sellUSDT: "USDT 换回人民币"; case .adjustUSDT: "USDT 余额调整" } }
    var icon: String { switch self { case .buy: "arrow.down.left"; case .transfer: "arrow.left.arrow.right"; case .sell: "arrow.up.right"; case .fee: "minus.circle"; case .buyUSDT: "plus.circle"; case .sellUSDT: "yensign.circle"; case .adjustUSDT: "slider.horizontal.3" } }
}
extension FeeCategory {
    var title: String { switch self { case .trading: "交易手续费"; case .withdrawal: "提币手续费"; case .network: "链上转账手续费"; case .other: "其他手续费" } }
}

extension FeeCurrency {
    var title: String { switch self { case .cny: "人民币 CNY"; case .btc: "BTC"; case .usdt: "USDT" } }
}
