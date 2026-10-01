import Foundation

public struct BackupDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var accounts: [Account]
    public var entries: [LedgerEntry]
    public var lastPrice: PriceQuote?

    public init(schemaVersion: Int = 1, exportedAt: Date = Date(), accounts: [Account] = [], entries: [LedgerEntry] = [], lastPrice: PriceQuote? = nil) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.accounts = accounts
        self.entries = entries
        self.lastPrice = lastPrice
    }
}

public enum BackupError: LocalizedError, Equatable {
    case tooLarge
    case unsupportedSchema(Int)
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "备份文件超过 20 MB，未导入。"
        case .unsupportedSchema(let version): return "暂不支持备份版本 \(version)，现有数据没有改变。"
        case .invalidDocument(let reason): return "备份内容无效：\(reason)"
        }
    }
}

public enum BackupCodec {
    public static let maximumBytes = 20 * 1_024 * 1_024

    public static func encode(_ document: BackupDocument) throws -> Data {
        try validate(document)
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
        guard data.count <= maximumBytes else { throw BackupError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let document: BackupDocument
        do { document = try decoder.decode(BackupDocument.self, from: data) }
        catch { throw BackupError.invalidDocument("JSON 格式、日期或数值格式不正确。") }
        try validate(document)
        return document
    }

    public static func validate(_ document: BackupDocument) throws {
        guard document.schemaVersion == 1 else { throw BackupError.unsupportedSchema(document.schemaVersion) }
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
        _ = try LedgerEngine.calculate(accounts: document.accounts, entries: document.entries)
    }

    /// RFC 4180 CSV with UTF-8 BOM for Excel/WPS. Numeric values are exact base-10
    /// strings; free text is prefixed with an apostrophe when it could be a formula.
    public static func csv(_ document: BackupDocument) throws -> Data {
        try validate(document)
        return try csv(accounts: document.accounts, entries: document.entries)
    }

    public static func csv(accounts: [Account], entries: [LedgerEntry]) throws -> Data {
        _ = try LedgerEngine.calculate(accounts: accounts, entries: entries)
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var rows = [["id", "date_utc", "sequence", "kind", "from_account_id", "from_account_name", "from_account_type", "to_account_id", "to_account_name", "to_account_type", "amount_sats", "amount_btc", "received_sats", "received_btc", "amount_cny", "fee_currency", "fee_sats", "fee_btc", "fee_cny", "fee_price_cny_per_btc", "fee_cny_equivalent", "fee_category", "note"]]
        for entry in entries.sorted(by: {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            let from = entry.fromAccountID.flatMap { accountMap[$0] }
            let to = entry.toAccountID.flatMap { accountMap[$0] }
            let feeEquivalent = entry.feeCNYEquivalent
            rows.append([
                entry.id.uuidString, timestamp(entry.date), String(entry.sequence), entry.kind.rawValue,
                entry.fromAccountID?.uuidString ?? "", safeText(from?.name ?? ""), from?.kind.rawValue ?? "",
                entry.toAccountID?.uuidString ?? "", safeText(to?.name ?? ""), to?.kind.rawValue ?? "",
                String(entry.amountSats), decimalString(Decimal(entry.amountSats) / Decimal(100_000_000)),
                String(entry.receivedSats), decimalString(Decimal(entry.receivedSats) / Decimal(100_000_000)),
                decimalString(entry.amountCNY), entry.feeCurrency.rawValue,
                String(entry.feeSats), decimalString(Decimal(entry.feeSats) / Decimal(100_000_000)),
                decimalString(entry.feeCNY), decimalString(entry.feePriceCNY), decimalString(feeEquivalent),
                entry.feeCategory.rawValue, safeText(entry.note)
            ])
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
