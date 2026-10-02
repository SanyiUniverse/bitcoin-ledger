import Foundation

public struct MigrationIssue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: String
    public var reason: String
}

/// Metadata proves which original records supplied each retained BTC event.
/// No old settlement balances or fee accounting remain in the new ledger.
public struct MigrationMapping: Codable, Equatable, Sendable {
    public var targetEntryID: UUID
    public var sourceEntryIDs: [UUID]
    public var sourceDates: [Date]
}

public struct MigrationReport: Codable, Equatable, Sendable {
    public var sourceSchemaVersion: Int
    public var sourceEntryCount: Int
    public var migratedCount: Int
    public var mappings: [MigrationMapping]
    public var issues: [MigrationIssue]
}

public struct BackupDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 5
    public static let supportedAccountingPolicy = "usd-invested-net-btc-v1"
    public var schemaVersion: Int
    public var baseCurrency: String
    public var accountingPolicy: String
    public var exportedAt: Date
    public var accounts: [Account]
    public var entries: [LedgerEntry]
    public var lastPrice: PriceQuote?
    public var migrationReport: MigrationReport?

    public init(schemaVersion: Int = Self.currentSchemaVersion, exportedAt: Date = Date(),
                accounts: [Account] = Account.defaults, entries: [LedgerEntry] = [],
                lastPrice: PriceQuote? = nil, baseCurrency: String = "USD",
                accountingPolicy: String = Self.supportedAccountingPolicy,
                migrationReport: MigrationReport? = nil) {
        self.schemaVersion = schemaVersion
        self.baseCurrency = baseCurrency
        self.accountingPolicy = accountingPolicy
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.entries = entries
        self.lastPrice = lastPrice
        self.migrationReport = migrationReport
    }
}

public enum BackupError: LocalizedError, Equatable {
    case tooLarge
    case unsupportedSchema(Int)
    case unsupportedAccountingPolicy(String)
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "备份文件超过 20 MB，未导入。"
        case .unsupportedSchema(let version): return "暂不支持备份版本 \(version)，现有数据没有改变。"
        case .unsupportedAccountingPolicy(let policy): return "暂不支持此备份的记账口径：\(policy)。现有数据没有改变。"
        case .invalidDocument(let reason): return "备份内容无效：\(reason)"
        }
    }
}

public enum BackupCodec {
    public static let maximumBytes = 20 * 1_024 * 1_024
    private static let legacyPolicy = "cny-principal-moving-average-v1"
    private struct Header: Decodable {
        let schemaVersion: Int
        let baseCurrency: String?
        let accountingPolicy: String?
    }
    private struct VersionHeader: Decodable { let schemaVersion: Int }

    public static func schemaVersion(in data: Data) throws -> Int {
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        let version: Int
        do { version = try JSONDecoder().decode(VersionHeader.self, from: data).schemaVersion }
        catch { throw BackupError.invalidDocument("JSON 备份版本信息不正确。") }
        guard (1...BackupDocument.currentSchemaVersion).contains(version) else {
            throw BackupError.unsupportedSchema(version)
        }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) }
        catch { throw BackupError.invalidDocument("JSON 备份头信息不正确。") }
        guard (1...BackupDocument.currentSchemaVersion).contains(header.schemaVersion) else {
            throw BackupError.unsupportedSchema(header.schemaVersion)
        }
        guard header.schemaVersion == 1 || (header.baseCurrency != nil && header.accountingPolicy != nil) else {
            throw BackupError.invalidDocument("备份缺少本位币或记账口径。")
        }
        let currency = header.schemaVersion < 5 ? "CNY" : "USD"
        guard header.baseCurrency ?? currency == currency else { throw BackupError.invalidDocument("备份本位币与版本不一致。") }
        let supportedPolicy = header.schemaVersion < 4 ? legacyPolicy : header.schemaVersion == 4
            ? "cny-invested-net-btc-v1" : BackupDocument.supportedAccountingPolicy
        guard header.accountingPolicy ?? supportedPolicy == supportedPolicy else {
            throw BackupError.unsupportedAccountingPolicy(header.accountingPolicy ?? "")
        }
        return header.schemaVersion
    }

    public static func encode(_ document: BackupDocument) throws -> Data {
        try validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        return data
    }

    public static func encode(accounts: [Account], entries: [LedgerEntry], lastPrice: PriceQuote? = nil) throws -> Data {
        try encode(BackupDocument(accounts: accounts, entries: entries, lastPrice: lastPrice))
    }

    public static func decode(_ data: Data) throws -> BackupDocument {
        let version = try schemaVersion(in: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            let document: BackupDocument
            if version == 5 { document = try decoder.decode(BackupDocument.self, from: data) }
            else if version == 4 {
                let old = try decoder.decode(PreviousBTCOnlyDocument.self, from: data)
                // CNY quotes cannot be relabelled USD. Retain purchase inputs;
                // missing conversions stay explicit until historical FX loads.
                let entries = old.entries.map { entry in
                    var original = entry
                    original.conversion = nil
                    return original
                }
                document = BackupDocument(exportedAt: old.exportedAt, accounts: old.accounts,
                    entries: entries, migrationReport: old.migrationReport)
            } else { document = try migrate(decoder.decode(LegacyDocument.self, from: data)) }
            try validate(document)
            return document
        } catch let error as BackupError { throw error }
        catch { throw BackupError.invalidDocument("JSON 格式、日期或数值格式不正确。\(error.localizedDescription)") }
    }

    public static func validate(_ document: BackupDocument) throws {
        guard document.schemaVersion == BackupDocument.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(document.schemaVersion)
        }
        guard document.baseCurrency == "USD" else { throw BackupError.invalidDocument("本位币必须为 USD。") }
        guard document.accountingPolicy == BackupDocument.supportedAccountingPolicy else {
            throw BackupError.unsupportedAccountingPolicy(document.accountingPolicy)
        }
        guard document.exportedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw BackupError.invalidDocument("导出日期无效。")
        }
        if let quote = document.lastPrice {
            guard quote.priceUSD > 0, quote.priceUSD <= Amounts.maximumPrice,
                  quote.fetchedAt.timeIntervalSinceReferenceDate.isFinite,
                  !quote.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  quote.source.count <= 200 else { throw BackupError.invalidDocument("缓存行情无效。") }
        }
        if let report = document.migrationReport {
            guard (1...3).contains(report.sourceSchemaVersion), report.sourceEntryCount >= 0,
                  report.migratedCount >= 0, report.migratedCount <= report.sourceEntryCount,
                  report.mappings.allSatisfy({ !$0.sourceEntryIDs.isEmpty && $0.sourceEntryIDs.count == $0.sourceDates.count
                      && $0.sourceDates.allSatisfy { $0.timeIntervalSinceReferenceDate.isFinite } }),
                  report.issues.allSatisfy({ $0.date.timeIntervalSinceReferenceDate.isFinite && !$0.reason.isEmpty }) else {
                throw BackupError.invalidDocument("迁移报告无效。")
            }
        }
        _ = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
    }

    public static func csv(_ document: BackupDocument) throws -> Data {
        try validate(document)
        return try csv(accounts: document.accounts, entries: document.entries)
    }

    public static func csv(accounts: [Account], entries: [LedgerEntry]) throws -> Data {
        _ = try LedgerEngine.calculate(accounts: accounts, entries: entries)
        let names = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        var rows = [["id", "date_utc", "sequence", "kind", "from_account_id", "from_account_name",
                     "to_account_id", "to_account_name", "amount_sats", "amount_btc", "received_sats",
                     "received_btc", "amount_cny", "amount_usd", "cny_per_usd", "fx_date_utc", "fx_source", "loss_sats", "loss_btc", "note"]]
        for entry in LedgerEngine.ordered(entries) {
            rows.append([
                entry.id.uuidString, timestamp(entry.date), String(entry.sequence), entry.kind.rawValue,
                entry.fromAccountID?.uuidString ?? "", safeText(entry.fromAccountID.flatMap { names[$0] } ?? ""),
                entry.toAccountID?.uuidString ?? "", safeText(entry.toAccountID.flatMap { names[$0] } ?? ""),
                String(entry.amountSats), Amounts.string(Amounts.btc(entry.amountSats)),
                String(entry.receivedSats), Amounts.string(Amounts.btc(entry.receivedSats)),
                Amounts.string(entry.amountCNY), entry.amountUSD.map(Amounts.string) ?? "",
                entry.conversion.map { Amounts.string($0.rate.cnyPerUSD) } ?? "",
                entry.conversion.map { timestamp($0.rate.date) } ?? "",
                safeText(entry.conversion?.rate.source ?? ""),
                String(entry.lossSats), Amounts.string(Amounts.btc(entry.lossSats)), safeText(entry.note)
            ])
        }
        let csv = "\u{FEFF}" + rows.map { $0.map(escapeCSV).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(csv.utf8)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func safeText(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let formulaStart = first.map { "=+-@".contains($0) } ?? false
        let controlStart = value.first.map { $0 == "\t" || $0 == "\r" || $0 == "\n" } ?? false
        return formulaStart || controlStart ? "'" + value : value
    }
    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

// Everything below is read-only migration input. Old fields are never encoded
// into v4 events or used by the runtime ledger calculations.
private struct LegacyAccount: Decodable {
    var id: UUID
    var name: String
    var kind: String?
    var isArchived: Bool?
}
private struct LegacyDocument: Decodable {
    var schemaVersion: Int
    var exportedAt: Date
    var accounts: [LegacyAccount]
    var entries: [LegacyEntry]
}
private struct PreviousBTCOnlyDocument: Decodable {
    var exportedAt: Date
    var accounts: [Account]
    var entries: [LedgerEntry]
    var migrationReport: MigrationReport?
}
private struct LegacyEntry: Decodable {
    var id: UUID
    var date: Date
    var sequence: Int64
    var kind: String
    var fromAccountID: UUID?
    var toAccountID: UUID?
    var amountSats: Int64
    var receivedSats: Int64
    var amountCNY: String
    var feeCurrency: String
    var feeSats: Int64
    var feeCNY: String
    var note: String
    var settlementCurrency: String?
    var amountUSDT: String?
    var receivedUSDT: String?
    var feeUSDT: String?
    var feeValuationSource: String?
}

private extension BackupCodec {
    static func migrate(_ old: LegacyDocument) throws -> BackupDocument {
        if old.schemaVersion >= 2 {
            guard old.entries.allSatisfy({ $0.settlementCurrency != nil && $0.amountUSDT != nil
                && $0.receivedUSDT != nil && $0.feeUSDT != nil && $0.feeValuationSource != nil }) else {
                throw BackupError.invalidDocument("旧版记录缺少明确的结算或费用字段，未猜测其含义。")
            }
        }
        guard Set(old.entries.map(\.id)).count == old.entries.count else {
            throw BackupError.invalidDocument("旧记录 ID 重复，不能可靠迁移。")
        }
        var accounts = old.accounts.map { Account(id: $0.id, name: $0.name) }
        let activeExchanges = old.accounts.filter { $0.kind == "exchange" && $0.isArchived != true }
        if activeExchanges.count == 1, let known = activeExchanges.first,
           known.name.lowercased().contains("okx") || known.name.contains("欧易"),
           let index = accounts.firstIndex(where: { $0.id == known.id }) { accounts[index].name = "欧易" }
        let activeWallets = old.accounts.filter { $0.kind == "selfCustody" && $0.isArchived != true }
        if activeWallets.count == 1, let known = activeWallets.first,
           let index = accounts.firstIndex(where: { $0.id == known.id }) { accounts[index].name = "自有钱包" }
        for account in Account.defaults where !accounts.contains(where: { $0.name == account.name }) {
            if !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
        }
        _ = try LedgerEngine.calculate(accounts: accounts, entries: [])

        let ordered = old.entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        let lastIntermediateIndex = ordered.lastIndex(where: {
            ["buyUSDT", "sellUSDT", "adjustUSDT"].contains($0.kind)
                || $0.settlementCurrency == "usdt" || $0.feeCurrency == "usdt"
        })
        var candidates: [LedgerEntry] = []
        var mappings: [MigrationMapping] = []
        var issues: [MigrationIssue] = []
        var consumedIDs = Set<UUID>()
        var intermediateBalanceKnownZero = true

        func issue(_ entry: LegacyEntry, _ reason: String) {
            issues.append(MigrationIssue(id: entry.id, date: entry.date, kind: entry.kind, reason: reason))
        }
        for (index, entry) in ordered.enumerated() where !consumedIDs.contains(entry.id) {
            do {
                try validateLegacy(entry)
                guard entry.date.timeIntervalSinceReferenceDate.isFinite, entry.sequence >= 0,
                      entry.sequence < Int64.max, entry.note.count <= 10_000 else {
                    throw LedgerError.invalid("旧记录日期、顺序或备注无效。")
                }
                let cny = try Amounts.decimal(entry.amountCNY)
                let feeCNY = try Amounts.decimal(entry.feeCNY)
                let settlement = entry.settlementCurrency ?? "cny"
                if entry.kind == "buy", settlement == "cny" {
                    guard cny > 0, entry.receivedSats == 0, entry.amountSats > 0,
                          ["cny", "btc"].contains(entry.feeCurrency), entry.feeSats >= 0,
                          (entry.feeCurrency != "btc" || feeCNY == 0),
                          (try Amounts.decimal(entry.amountUSDT ?? "0", maxPlaces: 8)) == 0 else {
                        throw LedgerError.invalid("人民币购买记录的原字段关系不明确。")
                    }
                    // Legacy amountSats already represented NET BTC received.
                    candidates.append(LedgerEntry(id: entry.id, date: entry.date, sequence: entry.sequence,
                        kind: .buy, toAccountID: entry.toAccountID, receivedSats: entry.amountSats,
                        amountCNY: cny + feeCNY, note: entry.note))
                    mappings.append(MigrationMapping(targetEntryID: entry.id, sourceEntryIDs: [entry.id], sourceDates: [entry.date]))
                } else if entry.kind == "transfer" {
                    guard entry.amountSats > 0, entry.receivedSats >= 0,
                          entry.receivedSats <= entry.amountSats,
                          entry.amountSats - entry.receivedSats == entry.feeSats,
                          cny == 0, feeCNY == 0, settlement == "cny", entry.feeCurrency != "usdt" else {
                        throw LedgerError.invalid("转移的到账、损耗或外付人民币不能可靠映射，请确认原记录。")
                    }
                    candidates.append(LedgerEntry(id: entry.id, date: entry.date, sequence: entry.sequence,
                        kind: .transfer, fromAccountID: entry.fromAccountID, toAccountID: entry.toAccountID,
                        amountSats: entry.amountSats, receivedSats: entry.receivedSats, note: entry.note))
                    mappings.append(MigrationMapping(targetEntryID: entry.id, sourceEntryIDs: [entry.id], sourceDates: [entry.date]))
                } else if entry.kind == "buyUSDT", intermediateBalanceKnownZero,
                          index + 1 < ordered.count {
                    let purchase = ordered[index + 1]
                    try validateLegacy(purchase)
                    let funded = try Amounts.decimal(entry.receivedUSDT ?? "0", maxPlaces: 8)
                    let debited = try Amounts.decimal(purchase.amountUSDT ?? "0", maxPlaces: 8)
                    let purchaseCNY = try Amounts.decimal(purchase.amountCNY)
                    let purchaseFeeCNY = try Amounts.decimal(purchase.feeCNY)
                    guard purchase.kind == "buy", purchase.settlementCurrency == "usdt",
                          cny > 0, funded > 0, debited > 0, debited <= funded,
                          purchaseCNY == 0, purchase.amountSats > 0, purchase.receivedSats == 0,
                          purchase.fromAccountID == nil, purchase.toAccountID != nil,
                          entry.fromAccountID == nil, entry.toAccountID == nil,
                          entry.amountSats == 0, entry.receivedSats == 0,
                          entry.feeCurrency != "btc", feeCNY <= cny,
                          purchase.feeSats >= 0,
                          ["cny", "btc", "usdt"].contains(purchase.feeCurrency),
                          (purchase.feeCurrency != "btc" || purchaseFeeCNY == 0),
                          (purchase.feeCurrency != "usdt" || purchaseFeeCNY == 0),
                          (try Amounts.decimal(purchase.feeUSDT ?? "0", maxPlaces: 8)) < debited,
                          (funded == debited || lastIntermediateIndex == index + 1) else {
                        intermediateBalanceKnownZero = false
                        throw LedgerError.invalid("无法确定一笔人民币投入唯一对应哪笔 BTC 购买；未采用平均汇率推算。")
                    }
                    // The exact, isolated funding belongs entirely to this BTC
                    // purchase. Only the final chain may leave an unused balance,
                    // which the requested model explicitly treats as its cost.
                    candidates.append(LedgerEntry(id: purchase.id, date: purchase.date, sequence: purchase.sequence,
                        kind: .buy, toAccountID: purchase.toAccountID, receivedSats: purchase.amountSats,
                        amountCNY: cny + purchaseFeeCNY, note: purchase.note))
                    mappings.append(MigrationMapping(targetEntryID: purchase.id,
                        sourceEntryIDs: [entry.id, purchase.id], sourceDates: [entry.date, purchase.date]))
                    consumedIDs.insert(purchase.id)
                    intermediateBalanceKnownZero = funded == debited
                } else {
                    if ["buyUSDT", "sellUSDT", "adjustUSDT"].contains(entry.kind)
                        || settlement == "usdt" || entry.feeCurrency == "usdt" {
                        intermediateBalanceKnownZero = false
                    }
                    issue(entry, "此旧记录不能唯一转换为购买或转移；完整原数据已保留，需人工确认。")
                }
            } catch {
                if entry.kind == "buyUSDT" || entry.settlementCurrency == "usdt" { intermediateBalanceKnownZero = false }
                issue(entry, error.localizedDescription)
            }
        }
        // Most ledgers validate in one linear replay. If skipped old purchases
        // caused a missing transfer balance, isolate those dependent events.
        var entries = candidates
        if (try? LedgerEngine.calculate(accounts: accounts, entries: entries)) == nil {
            entries = []
            for candidate in LedgerEngine.ordered(candidates) {
                do {
                    _ = try LedgerEngine.calculate(accounts: accounts, entries: entries + [candidate])
                    entries.append(candidate)
                } catch {
                    let sourceIDs = mappings.first(where: { $0.targetEntryID == candidate.id })?.sourceEntryIDs ?? [candidate.id]
                    for original in ordered where sourceIDs.contains(original.id) { issue(original, error.localizedDescription) }
                    mappings.removeAll { $0.targetEntryID == candidate.id }
                }
            }
        }
        return BackupDocument(exportedAt: old.exportedAt, accounts: accounts, entries: entries,
            migrationReport: MigrationReport(sourceSchemaVersion: old.schemaVersion,
                sourceEntryCount: old.entries.count, migratedCount: entries.count, mappings: mappings, issues: issues))
    }

    static func validateLegacy(_ entry: LegacyEntry) throws {
        guard entry.date.timeIntervalSinceReferenceDate.isFinite, entry.sequence >= 0,
              entry.sequence < Int64.max, entry.note.count <= 10_000,
              [entry.amountSats, entry.receivedSats, entry.feeSats].allSatisfy({ $0 >= 0 && $0 <= Amounts.maximumSats }),
              ["cny", "usdt"].contains(entry.settlementCurrency ?? "cny"),
              ["cny", "btc", "usdt"].contains(entry.feeCurrency) else {
            throw LedgerError.invalid("旧记录日期、数量或币种字段无效。")
        }
        let cny = try Amounts.decimal(entry.amountCNY)
        let feeCNY = try Amounts.decimal(entry.feeCNY)
        let feeUSDT = try Amounts.decimal(entry.feeUSDT ?? "0", maxPlaces: 8)
        _ = try Amounts.decimal(entry.amountUSDT ?? "0", maxPlaces: 8)
        _ = try Amounts.decimal(entry.receivedUSDT ?? "0", maxPlaces: 8)
        guard cny <= Amounts.maximumCNY, feeCNY <= Amounts.maximumCNY,
              (entry.feeCurrency != "cny" || (entry.feeSats == 0 && feeUSDT == 0)),
              (entry.feeCurrency != "btc" || (feeCNY == 0 && feeUSDT == 0)),
              (entry.feeCurrency != "usdt" || (feeCNY == 0 && entry.feeSats == 0)) else {
            throw LedgerError.invalid("旧记录金额或费用币种关系不明确。")
        }
    }
}
