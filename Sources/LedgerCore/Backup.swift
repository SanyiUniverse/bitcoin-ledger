import Foundation

public struct BackupDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public static let supportedAccountingPolicy = "cny-principal-moving-average-v1"
    public var schemaVersion: Int
    public var baseCurrency: String
    public var accountingPolicy: String
    public var exportedAt: Date
    public var accounts: [Account]
    public var entries: [LedgerEntry]
    public var lastPrice: PriceQuote?

    public init(schemaVersion: Int = BackupDocument.currentSchemaVersion, exportedAt: Date = Date(), accounts: [Account] = [], entries: [LedgerEntry] = [], lastPrice: PriceQuote? = nil,
                baseCurrency: String = "CNY", accountingPolicy: String = BackupDocument.supportedAccountingPolicy) {
        self.schemaVersion = schemaVersion
        self.baseCurrency = baseCurrency
        self.accountingPolicy = accountingPolicy
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.entries = entries
        self.lastPrice = lastPrice
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, baseCurrency, accountingPolicy, exportedAt, accounts, entries, lastPrice, entryValuations
    }

    private struct RequiredV2EntryFields: Decodable {
        let settlementCurrency: SettlementCurrency
        let amountUSDT: String
        let receivedUSDT: String
        let feeUSDT: String
        let feeValuationSource: FeeValuationSource
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let originalVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(originalVersion) else {
            throw BackupError.unsupportedSchema(originalVersion)
        }
        if originalVersion == 1 {
            baseCurrency = try values.decodeIfPresent(String.self, forKey: .baseCurrency) ?? "CNY"
            accountingPolicy = try values.decodeIfPresent(String.self, forKey: .accountingPolicy) ?? Self.supportedAccountingPolicy
        } else {
            baseCurrency = try values.decode(String.self, forKey: .baseCurrency)
            accountingPolicy = try values.decode(String.self, forKey: .accountingPolicy)
        }
        try BackupCodec.validatePolicy(baseCurrency: baseCurrency, accountingPolicy: accountingPolicy)
        schemaVersion = Self.currentSchemaVersion
        exportedAt = try values.decode(Date.self, forKey: .exportedAt)
        accounts = try values.decode([Account].self, forKey: .accounts)
        if originalVersion >= 2 {
            // Entry decoding has legacy defaults for v1 only. A v2 document
            // must explicitly state its settlement/fee semantics, even at zero.
            _ = try values.decode([RequiredV2EntryFields].self, forKey: .entries)
        }
        entries = try values.decode([LedgerEntry].self, forKey: .entries)
        lastPrice = try values.decodeIfPresent(PriceQuote.self, forKey: .lastPrice)
        if originalVersion == 1 {
            // Version 1 could only represent BTC and CNY. A misleading version
            // marker must not smuggle USDT activity or a different fee policy in.
            guard entries.allSatisfy({
                [EntryKind.buy, .transfer, .sell, .fee].contains($0.kind)
                    && $0.settlementCurrency == .cny && $0.amountUSDT == 0
                    && $0.receivedUSDT == 0 && $0.feeUSDT == 0
                    && $0.feeCurrency != .usdt && $0.feeValuationSource == .manualPrice
            }) else { throw BackupError.invalidDocument("版本 1 不能包含 USDT 或新的费用估值口径。") }
        }
        if originalVersion == 2, entries.contains(where: { $0.kind == .adjustUSDT }) {
            throw BackupError.invalidDocument("版本 2 不能包含 USDT 余额校正记录。")
        }
        let replay = try BackupCodec.validatedSnapshot(self)
        if originalVersion >= 2 {
            let stored = try values.decode([String: EntryValuation].self, forKey: .entryValuations)
            var parsed: [UUID: EntryValuation] = [:]
            for (key, value) in stored {
                guard let id = UUID(uuidString: key), parsed.updateValue(value, forKey: id) == nil else {
                    throw BackupError.invalidDocument("逐笔成本快照 ID 无效或重复。")
                }
            }
            guard parsed == replay.entryValuations else {
                throw BackupError.invalidDocument("逐笔人民币成本或费用快照与原始记录不一致。")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        let replay = try BackupCodec.validatedSnapshot(self)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(baseCurrency, forKey: .baseCurrency)
        try values.encode(accountingPolicy, forKey: .accountingPolicy)
        try values.encode(exportedAt, forKey: .exportedAt)
        try values.encode(accounts, forKey: .accounts)
        try values.encode(entries, forKey: .entries)
        try values.encodeIfPresent(lastPrice, forKey: .lastPrice)
        let valuations = Dictionary(uniqueKeysWithValues: replay.entryValuations.map { ($0.key.uuidString, $0.value) })
        try values.encode(valuations, forKey: .entryValuations)
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

    private struct Header: Decodable {
        let schemaVersion: Int
        let baseCurrency: String?
        let accountingPolicy: String?
    }
    private struct VersionHeader: Decodable { let schemaVersion: Int }

    /// Reads only the version/policy header before attempting a version-specific
    /// document decode, so future schemas fail clearly even with unknown bodies.
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
        if header.schemaVersion >= 2 {
            guard let base = header.baseCurrency, let policy = header.accountingPolicy else {
                throw BackupError.invalidDocument("版本 \(header.schemaVersion) 缺少本位币或记账口径。")
            }
            try validatePolicy(baseCurrency: base, accountingPolicy: policy)
        } else {
            try validatePolicy(baseCurrency: header.baseCurrency ?? "CNY", accountingPolicy: header.accountingPolicy ?? BackupDocument.supportedAccountingPolicy)
        }
        return header.schemaVersion
    }

    fileprivate static func validatePolicy(baseCurrency: String, accountingPolicy: String) throws {
        guard baseCurrency == "CNY" else { throw BackupError.invalidDocument("本位币必须为 CNY。") }
        guard accountingPolicy == BackupDocument.supportedAccountingPolicy else {
            throw BackupError.unsupportedAccountingPolicy(accountingPolicy)
        }
    }

    public static func encode(_ document: BackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Foundation retains fractional milliseconds; money remains Decimal strings.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        return data
    }

    public static func encode(accounts: [Account], entries: [LedgerEntry], lastPrice: PriceQuote? = nil) throws -> Data {
        try encode(BackupDocument(accounts: accounts, entries: entries, lastPrice: lastPrice))
    }

    public static func decode(_ data: Data) throws -> BackupDocument {
        _ = try schemaVersion(in: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document: BackupDocument
        do { document = try decoder.decode(BackupDocument.self, from: data) }
        catch let error as BackupError { throw error }
        catch { throw BackupError.invalidDocument("JSON 格式、日期或数值格式不正确。\(error.localizedDescription)") }
        return document
    }

    public static func validate(_ document: BackupDocument) throws {
        _ = try validatedSnapshot(document)
    }

    fileprivate static func validatedSnapshot(_ document: BackupDocument) throws -> LedgerSnapshot {
        guard document.schemaVersion == BackupDocument.currentSchemaVersion else { throw BackupError.unsupportedSchema(document.schemaVersion) }
        try validatePolicy(baseCurrency: document.baseCurrency, accountingPolicy: document.accountingPolicy)
        guard document.exportedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw BackupError.invalidDocument("导出日期无效。")
        }
        if let quote = document.lastPrice {
            guard quote.priceCNY > 0, quote.priceCNY <= Decimal(1_000_000_000_000),
                  quote.fetchedAt.timeIntervalSinceReferenceDate.isFinite,
                  !quote.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  quote.source.count <= 200 else {
                throw BackupError.invalidDocument("缓存行情无效。")
            }
        }
        // The same complete replay validation used for all edits also applies to imports.
        return try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
    }

    /// RFC 4180 CSV with UTF-8 BOM for Excel/WPS. Numeric values are exact base-10
    /// strings; free text is prefixed with an apostrophe when it could be a formula.
    public static func csv(_ document: BackupDocument) throws -> Data {
        try validate(document)
        return try csv(accounts: document.accounts, entries: document.entries)
    }

    public static func csv(accounts: [Account], entries: [LedgerEntry]) throws -> Data {
        let replay = try LedgerEngine.calculate(accounts: accounts, entries: entries)
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var rows = [["id", "date_utc", "sequence", "kind", "from_account_id", "from_account_name", "from_account_type", "to_account_id", "to_account_name", "to_account_type", "amount_sats", "amount_btc", "received_sats", "received_btc", "amount_cny", "fee_currency", "fee_sats", "fee_btc", "fee_cny", "fee_price_cny_per_btc", "fee_cny_equivalent", "fee_category", "note", "settlement_currency", "amount_usdt", "received_usdt", "fee_usdt", "fee_valuation_source", "entry_cost_cny", "fee_unit_cost_cny", "base_currency", "accounting_policy", "adjustment_before_usdt", "adjustment_after_usdt", "adjustment_delta_usdt"]]
        for entry in entries.sorted(by: {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            let from = entry.fromAccountID.flatMap { accountMap[$0] }
            let to = entry.toAccountID.flatMap { accountMap[$0] }
            guard let valuation = replay.entryValuations[entry.id] else {
                throw BackupError.invalidDocument("缺少逐笔人民币成本快照。")
            }
            let feeEquivalent = valuation.feeCNYEquivalent
            var adjustmentColumns = ["", "", ""]
            if entry.kind == .adjustUSDT {
                guard let before = valuation.beforeUSDT, let after = valuation.afterUSDT else {
                    throw BackupError.invalidDocument("余额校正记录缺少重放前后数量。")
                }
                adjustmentColumns = [decimalString(before), decimalString(after), decimalString(after - before)]
            }
            rows.append([
                entry.id.uuidString, timestamp(entry.date), String(entry.sequence), entry.kind.rawValue,
                entry.fromAccountID?.uuidString ?? "", safeText(from?.name ?? ""), from?.kind.rawValue ?? "",
                entry.toAccountID?.uuidString ?? "", safeText(to?.name ?? ""), to?.kind.rawValue ?? "",
                String(entry.amountSats), decimalString(Decimal(entry.amountSats) / Decimal(100_000_000)),
                String(entry.receivedSats), decimalString(Decimal(entry.receivedSats) / Decimal(100_000_000)),
                decimalString(entry.amountCNY), entry.feeCurrency.rawValue,
                String(entry.feeSats), decimalString(Decimal(entry.feeSats) / Decimal(100_000_000)),
                decimalString(entry.feeCNY), decimalString(entry.feePriceCNY), decimalString(feeEquivalent),
                entry.feeCategory.rawValue, safeText(entry.note), entry.settlementCurrency.rawValue,
                decimalString(entry.amountUSDT), decimalString(entry.receivedUSDT), decimalString(entry.feeUSDT),
                entry.feeValuationSource.rawValue, decimalString(valuation.costCNY), decimalString(valuation.feeUnitCostCNY),
                "CNY", BackupDocument.supportedAccountingPolicy
            ] + adjustmentColumns)
        }
        let csv = "\u{FEFF}" + rows.map { $0.map(escapeCSV).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(csv.utf8)
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
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
