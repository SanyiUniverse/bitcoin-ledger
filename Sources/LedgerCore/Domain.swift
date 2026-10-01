import Foundation

public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case selfCustody, exchange
}

public struct Account: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AccountKind
    public var isArchived: Bool

    public init(id: UUID = UUID(), name: String, kind: AccountKind, isArchived: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, isArchived
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(AccountKind.self, forKey: .kind)
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

public enum EntryKind: String, Codable, CaseIterable, Sendable {
    case buy, transfer, sell, fee, buyUSDT, sellUSDT
}

public enum SettlementCurrency: String, Codable, CaseIterable, Sendable {
    case cny, usdt
}

public enum FeeCurrency: String, Codable, CaseIterable, Sendable {
    case cny, btc, usdt
}

public enum FeeValuationSource: String, Codable, CaseIterable, Sendable {
    case manualPrice, costBasis
}

public enum FeeCategory: String, Codable, CaseIterable, Sendable {
    case trading, withdrawal, network, other
}

public enum LedgerError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// Decimal input deliberately never passes through binary floating point.
public enum Amounts {
    public static let satoshisPerBTC: Int64 = 100_000_000
    public static let maximumSats: Int64 = 2_100_000_000_000_000
    public static let maximumCNY = Decimal(1_000_000_000_000_000 as Int64)
    public static let maximumPrice = Decimal(1_000_000_000_000 as Int64)
    public static let maximumUSDT = Decimal(1_000_000_000_000_000 as Int64)

    /// Accepts plain, nonnegative decimal notation. No exponent, grouping, or suffix.
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

    public static func btc(_ sats: Int64) -> Decimal {
        Decimal(sats) / Decimal(satoshisPerBTC)
    }

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

/// The source of truth is the event history, not mutable account balances.
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
    public var feeCurrency: FeeCurrency
    public var feeSats: Int64
    public var feeCNY: Decimal
    public var feePriceCNY: Decimal
    public var feeCategory: FeeCategory
    public var note: String
    public var settlementCurrency: SettlementCurrency
    public var amountUSDT: Decimal
    public var receivedUSDT: Decimal
    public var feeUSDT: Decimal
    public var feeValuationSource: FeeValuationSource

    public init(
        id: UUID = UUID(), date: Date = Date(), sequence: Int64 = 0,
        kind: EntryKind, fromAccountID: UUID? = nil, toAccountID: UUID? = nil,
        amountSats: Int64 = 0, receivedSats: Int64 = 0, amountCNY: Decimal = 0,
        feeCurrency: FeeCurrency = .cny, feeSats: Int64 = 0,
        feeCNY: Decimal = 0, feePriceCNY: Decimal = 0,
        feeCategory: FeeCategory = .trading, note: String = "",
        settlementCurrency: SettlementCurrency = .cny,
        amountUSDT: Decimal = 0, receivedUSDT: Decimal = 0,
        feeUSDT: Decimal = 0, feeValuationSource: FeeValuationSource = .manualPrice
    ) {
        self.id = id
        self.date = date
        self.sequence = sequence
        self.kind = kind
        self.fromAccountID = fromAccountID
        self.toAccountID = toAccountID
        self.amountSats = amountSats
        self.receivedSats = receivedSats
        self.amountCNY = amountCNY
        self.feeCurrency = feeCurrency
        self.feeSats = feeSats
        self.feeCNY = feeCNY
        self.feePriceCNY = feePriceCNY
        self.feeCategory = feeCategory
        self.note = note
        self.settlementCurrency = settlementCurrency
        self.amountUSDT = amountUSDT
        self.receivedUSDT = receivedUSDT
        self.feeUSDT = feeUSDT
        self.feeValuationSource = feeValuationSource
    }

    /// Legacy manual-price value only. Cost-basis fees require replay: use
    /// LedgerSnapshot.entryValuations[id].feeCNYEquivalent for every v2 display.
    public var feeCNYEquivalent: Decimal {
        guard feeValuationSource == .manualPrice else { return 0 }
        switch feeCurrency {
        case .btc: return Amounts.rounded(Amounts.btc(feeSats) * feePriceCNY)
        case .usdt: return Amounts.rounded(feeUSDT * feePriceCNY)
        case .cny: return feeCNY
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, sequence, kind, fromAccountID, toAccountID
        case amountSats, receivedSats, amountCNY, feeCurrency, feeSats
        case feeCNY, feePriceCNY, feeCNYEquivalent, feeCategory, note
        case settlementCurrency, amountUSDT, receivedUSDT, feeUSDT, feeValuationSource
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
        feeCurrency = try values.decode(FeeCurrency.self, forKey: .feeCurrency)
        feeSats = try values.decode(Int64.self, forKey: .feeSats)
        feeCNY = try Amounts.decimal(values.decode(String.self, forKey: .feeCNY))
        feePriceCNY = try Amounts.decimal(values.decode(String.self, forKey: .feePriceCNY), maxPlaces: 8)
        feeCategory = try values.decode(FeeCategory.self, forKey: .feeCategory)
        note = try values.decode(String.self, forKey: .note)
        settlementCurrency = try values.decodeIfPresent(SettlementCurrency.self, forKey: .settlementCurrency) ?? .cny
        amountUSDT = try Amounts.decimal(values.decodeIfPresent(String.self, forKey: .amountUSDT) ?? "0", maxPlaces: 8)
        receivedUSDT = try Amounts.decimal(values.decodeIfPresent(String.self, forKey: .receivedUSDT) ?? "0", maxPlaces: 8)
        feeUSDT = try Amounts.decimal(values.decodeIfPresent(String.self, forKey: .feeUSDT) ?? "0", maxPlaces: 8)
        feeValuationSource = try values.decodeIfPresent(FeeValuationSource.self, forKey: .feeValuationSource) ?? .manualPrice
        if feeValuationSource == .manualPrice {
            let savedEquivalent = try Amounts.decimal(values.decode(String.self, forKey: .feeCNYEquivalent), maxPlaces: 12)
            guard savedEquivalent == feeCNYEquivalent else {
                throw LedgerError.invalid("备份中的手续费人民币等值与费用数量、历史价格不一致。")
            }
        } else if let raw = try values.decodeIfPresent(String.self, forKey: .feeCNYEquivalent) {
            // Never treat an entry-local derived value as authoritative. The complete
            // document's replay valuations are verified by BackupCodec instead.
            _ = try Amounts.decimal(raw, maxPlaces: 12)
        }
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
        try values.encode(feeCurrency, forKey: .feeCurrency)
        try values.encode(feeSats, forKey: .feeSats)
        try values.encode(Amounts.string(feeCNY), forKey: .feeCNY)
        try values.encode(Amounts.string(feePriceCNY), forKey: .feePriceCNY)
        if feeValuationSource == .manualPrice {
            try values.encode(Amounts.string(feeCNYEquivalent), forKey: .feeCNYEquivalent)
        }
        try values.encode(feeCategory, forKey: .feeCategory)
        try values.encode(note, forKey: .note)
        try values.encode(settlementCurrency, forKey: .settlementCurrency)
        try values.encode(Amounts.string(amountUSDT), forKey: .amountUSDT)
        try values.encode(Amounts.string(receivedUSDT), forKey: .receivedUSDT)
        try values.encode(Amounts.string(feeUSDT), forKey: .feeUSDT)
        try values.encode(feeValuationSource, forKey: .feeValuationSource)
    }
}

public struct EntryValuation: Codable, Equatable, Sendable {
    public var costCNY: Decimal
    public var feeCNYEquivalent: Decimal
    public var feeUnitCostCNY: Decimal

    public init(costCNY: Decimal = 0, feeCNYEquivalent: Decimal = 0, feeUnitCostCNY: Decimal = 0) {
        self.costCNY = costCNY
        self.feeCNYEquivalent = feeCNYEquivalent
        self.feeUnitCostCNY = feeUnitCostCNY
    }

    private enum CodingKeys: String, CodingKey { case costCNY, feeCNYEquivalent, feeUnitCostCNY }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        costCNY = try Amounts.decimal(values.decode(String.self, forKey: .costCNY), maxPlaces: 12)
        feeCNYEquivalent = try Amounts.decimal(values.decode(String.self, forKey: .feeCNYEquivalent), maxPlaces: 12)
        feeUnitCostCNY = try Amounts.decimal(values.decode(String.self, forKey: .feeUnitCostCNY), maxPlaces: 12)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Amounts.string(costCNY), forKey: .costCNY)
        try values.encode(Amounts.string(feeCNYEquivalent), forKey: .feeCNYEquivalent)
        try values.encode(Amounts.string(feeUnitCostCNY), forKey: .feeUnitCostCNY)
    }
}

public struct LedgerSnapshot: Equatable, Sendable {
    public var balances: [UUID: Int64]
    public var totalSats: Int64
    public var investedCNY: Decimal
    public var purchasedSats: Int64
    public var purchasePrincipalCNY: Decimal
    public var costBasisCNY: Decimal
    public var totalFeeCNY: Decimal
    public var totalFeeSats: Int64
    public var realizedPnLCNY: Decimal
    public var entryValuations: [UUID: EntryValuation]
    public var usdtBalance: Decimal
    public var usdtCostBasisCNY: Decimal
    public var returnedCNY: Decimal
    public var totalFeeUSDT: Decimal

    public init(
        balances: [UUID: Int64] = [:], totalSats: Int64 = 0,
        investedCNY: Decimal = 0, purchasedSats: Int64 = 0,
        purchasePrincipalCNY: Decimal = 0, costBasisCNY: Decimal = 0,
        totalFeeCNY: Decimal = 0, totalFeeSats: Int64 = 0,
        realizedPnLCNY: Decimal = 0,
        entryValuations: [UUID: EntryValuation] = [:], usdtBalance: Decimal = 0,
        usdtCostBasisCNY: Decimal = 0, returnedCNY: Decimal = 0, totalFeeUSDT: Decimal = 0
    ) {
        self.balances = balances
        self.totalSats = totalSats
        self.investedCNY = investedCNY
        self.purchasedSats = purchasedSats
        self.purchasePrincipalCNY = purchasePrincipalCNY
        self.costBasisCNY = costBasisCNY
        self.totalFeeCNY = totalFeeCNY
        self.totalFeeSats = totalFeeSats
        self.realizedPnLCNY = realizedPnLCNY
        self.entryValuations = entryValuations
        self.usdtBalance = usdtBalance
        self.usdtCostBasisCNY = usdtCostBasisCNY
        self.returnedCNY = returnedCNY
        self.totalFeeUSDT = totalFeeUSDT
    }

    /// Purchase principal divided by gross BTC bought. USDT settlement uses its
    /// carried CNY basis and excludes the current trade's separately stated fees.
    public var averageBuyPriceCNY: Decimal? {
        purchasedSats > 0 ? Amounts.rounded(purchasePrincipalCNY / Amounts.btc(purchasedSats)) : nil
    }

    /// Remaining capitalized cost divided by BTC still held.
    public var actualCostPriceCNY: Decimal? {
        totalSats > 0 ? Amounts.rounded(costBasisCNY / Amounts.btc(totalSats)) : nil
    }

    public var averageUSDTCostCNY: Decimal? {
        usdtBalance > 0 ? Amounts.rounded(usdtCostBasisCNY / usdtBalance) : nil
    }

    public var feeRatio: Decimal? {
        investedCNY > 0 ? Amounts.rounded(totalFeeCNY / investedCNY) : nil
    }

    public func marketValue(price: Decimal) -> Decimal {
        Amounts.rounded(Amounts.btc(totalSats) * price)
    }

    public func unrealizedPnL(price: Decimal) -> Decimal {
        marketValue(price: price) - costBasisCNY
    }

    public func returnRatio(price: Decimal) -> Decimal? {
        costBasisCNY > 0 ? Amounts.rounded(unrealizedPnL(price: price) / costBasisCNY) : nil
    }
}
