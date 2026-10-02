import Foundation

public struct Account: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }

    public static let defaults = [
        Account(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "欧易"),
        Account(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, name: "自有钱包")
    ]
}

public enum EntryKind: String, Codable, CaseIterable, Sendable {
    case buy, transfer
}

public enum LedgerError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Money never passes through binary floating point; BTC uses integer satoshis.
public enum Amounts {
    public static let satoshisPerBTC: Int64 = 100_000_000
    public static let maximumSats: Int64 = 2_100_000_000_000_000
    public static let maximumCNY = Decimal(1_000_000_000_000_000 as Int64)
    public static let maximumPrice = Decimal(1_000_000_000_000 as Int64)

    public static func decimal(_ text: String, maxPlaces: Int = 2) throws -> Decimal {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (0...38).contains(maxPlaces), !value.isEmpty, value.count <= 80 else {
            throw LedgerError.invalid("请输入有效数字。")
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              parts.allSatisfy({ $0.allSatisfy { $0 >= "0" && $0 <= "9" } }),
              !parts[0].isEmpty || (parts.count == 2 && !parts[1].isEmpty),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= maxPlaces) else {
            throw LedgerError.invalid("请输入非负数字，小数最多 \(maxPlaces) 位；不使用逗号或科学计数法。")
        }
        let digits = value.filter { $0 != "." }.drop(while: { $0 == "0" })
        guard digits.count <= 38,
              let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !result.isNaN, result >= 0 else {
            throw LedgerError.invalid("数字超出支持范围。")
        }
        return result
    }

    public static func satoshis(_ text: String) throws -> Int64 {
        let amount = try decimal(text, maxPlaces: 8)
        guard amount <= Decimal(21_000_000) else {
            throw LedgerError.invalid("BTC 数量不能超过 21,000,000。")
        }
        let scaled = amount * Decimal(satoshisPerBTC)
        let result = NSDecimalNumber(decimal: scaled).int64Value
        guard Decimal(result) == scaled else {
            throw LedgerError.invalid("BTC 最小单位为 0.00000001（1 satoshi）。")
        }
        return result
    }

    public static func btc(_ sats: Int64) -> Decimal { Decimal(sats) / Decimal(satoshisPerBTC) }
    public static func string(_ amount: Decimal) -> String {
        var value = amount
        return NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
    }
    public static func rounded(_ amount: Decimal, scale: Int = 12) -> Decimal {
        var source = amount
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .bankers)
        return result
    }
}

/// The two events are the source of truth. A purchase stores actual cash paid
/// and actual BTC received; a transfer stores total debit and actual credit.
public struct LedgerEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var sequence: Int64
    public var kind: EntryKind
    public var fromAccountID: UUID?
    public var toAccountID: UUID?
    public var amountSats: Int64
    public var receivedSats: Int64
    public var amountCNY: Decimal
    public var note: String

    public init(id: UUID = UUID(), date: Date = Date(), sequence: Int64 = 0,
                kind: EntryKind, fromAccountID: UUID? = nil, toAccountID: UUID? = nil,
                amountSats: Int64 = 0, receivedSats: Int64 = 0,
                amountCNY: Decimal = 0, note: String = "") {
        self.id = id
        self.date = date
        self.sequence = sequence
        self.kind = kind
        self.fromAccountID = fromAccountID
        self.toAccountID = toAccountID
        self.amountSats = kind == .buy && amountSats == 0 ? receivedSats : amountSats
        self.receivedSats = kind == .buy && receivedSats == 0 ? amountSats : receivedSats
        self.amountCNY = amountCNY
        self.note = note
    }

    public var lossSats: Int64 { kind == .transfer ? amountSats - receivedSats : 0 }

    private enum CodingKeys: String, CodingKey {
        case id, date, sequence, kind, fromAccountID, toAccountID, amountSats, receivedSats, amountCNY, note
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        sequence = try values.decode(Int64.self, forKey: .sequence)
        kind = try values.decode(EntryKind.self, forKey: .kind)
        fromAccountID = try values.decodeIfPresent(UUID.self, forKey: .fromAccountID)
        toAccountID = try values.decodeIfPresent(UUID.self, forKey: .toAccountID)
        amountSats = try values.decode(Int64.self, forKey: .amountSats)
        receivedSats = try values.decode(Int64.self, forKey: .receivedSats)
        amountCNY = try Amounts.decimal(values.decode(String.self, forKey: .amountCNY))
        note = try values.decode(String.self, forKey: .note)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(date, forKey: .date)
        try values.encode(sequence, forKey: .sequence)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(fromAccountID, forKey: .fromAccountID)
        try values.encodeIfPresent(toAccountID, forKey: .toAccountID)
        try values.encode(amountSats, forKey: .amountSats)
        try values.encode(receivedSats, forKey: .receivedSats)
        try values.encode(Amounts.string(amountCNY), forKey: .amountCNY)
        try values.encode(note, forKey: .note)
    }
}

public struct LedgerSnapshot: Equatable, Sendable {
    public var balances: [UUID: Int64]
    public var totalSats: Int64
    public var totalInvestedCNY: Decimal
    public var totalPurchasedSats: Int64
    public var totalLossSats: Int64

    public init(balances: [UUID: Int64] = [:], totalSats: Int64 = 0,
                totalInvestedCNY: Decimal = 0, totalPurchasedSats: Int64 = 0,
                totalLossSats: Int64 = 0) {
        self.balances = balances
        self.totalSats = totalSats
        self.totalInvestedCNY = totalInvestedCNY
        self.totalPurchasedSats = totalPurchasedSats
        self.totalLossSats = totalLossSats
    }
    public var averageCostCNY: Decimal? {
        totalSats > 0 ? Amounts.rounded(totalInvestedCNY / Amounts.btc(totalSats)) : nil
    }
    public func value(price: Decimal) -> Decimal { Amounts.rounded(Amounts.btc(totalSats) * price) }
    public func profit(price: Decimal) -> Decimal { value(price: price) - totalInvestedCNY }
    /// Ratio, not percentage: the display multiplies by 100.
    public func profitRatio(price: Decimal) -> Decimal? {
        totalInvestedCNY > 0 ? Amounts.rounded(profit(price: price) / totalInvestedCNY) : nil
    }
}

public struct LedgerHistoryPoint: Equatable, Sendable {
    public var date: Date
    public var entryID: UUID
    public var snapshot: LedgerSnapshot
}
