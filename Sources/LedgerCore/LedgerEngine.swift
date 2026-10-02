import Foundation

public enum LedgerEngine {
    /// Includes events at the cutoff. Future events never affect a historical
    /// balance, investment, loss, cost, or profit.
    public static func calculate(accounts: [Account], entries: [LedgerEntry], asOf: Date? = nil) throws -> LedgerSnapshot {
        try validate(accounts: accounts, entries: entries)
        var result = emptySnapshot(accounts: accounts)
        for entry in ordered(entries) where asOf == nil || entry.date <= asOf! {
            try apply(entry, to: &result)
        }
        return result
    }

    /// One chronological replay supplies the chart's changing cost line.
    public static func history(accounts: [Account], entries: [LedgerEntry]) throws -> [LedgerHistoryPoint] {
        try validate(accounts: accounts, entries: entries)
        var snapshot = emptySnapshot(accounts: accounts)
        return try ordered(entries).map { entry in
            try apply(entry, to: &snapshot)
            return LedgerHistoryPoint(date: entry.date, entryID: entry.id, snapshot: snapshot)
        }
    }

    public static func ordered(_ entries: [LedgerEntry]) -> [LedgerEntry] {
        entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func emptySnapshot(accounts: [Account]) -> LedgerSnapshot {
        LedgerSnapshot(balances: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, 0) }))
    }

    private static func validate(accounts: [Account], entries: [LedgerEntry]) throws {
        guard Set(accounts.map(\.id)).count == accounts.count else {
            throw LedgerError.invalid("账户 ID 重复，无法计算账本。")
        }
        guard Set(entries.map(\.id)).count == entries.count else {
            throw LedgerError.invalid("记录 ID 重复，无法计算账本。")
        }
        // Distinct historical accounts can share a name. Their stable UUIDs
        // preserve the original ownership and never merge balances by label.
        for account in accounts {
            guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, account.name.count <= 100 else {
                throw LedgerError.invalid("账户名称不能为空，且最多 100 个字符。")
            }
        }
        let ids = Set(accounts.map(\.id))
        for entry in entries {
            guard entry.date.timeIntervalSinceReferenceDate.isFinite,
                  entry.sequence >= 0, entry.sequence < Int64.max, entry.note.count <= 10_000 else {
                throw LedgerError.invalid("记录日期、顺序或备注无效。")
            }
            guard [entry.amountSats, entry.receivedSats].allSatisfy({ $0 >= 0 && $0 <= Amounts.maximumSats }) else {
                throw LedgerError.invalid("BTC 数量必须在 0 至 21,000,000 BTC 之间。")
            }
            for id in [entry.fromAccountID, entry.toAccountID].compactMap({ $0 }) {
                guard ids.contains(id) else { throw LedgerError.invalid("记录引用了不存在的账户。") }
            }
            guard !entry.amountCNY.isNaN, entry.amountCNY >= 0,
                  entry.amountCNY <= Amounts.maximumCNY,
                  Amounts.rounded(entry.amountCNY, scale: 2) == entry.amountCNY else {
                throw LedgerError.invalid("人民币金额超出支持范围或小数超过 2 位。")
            }
            switch entry.kind {
            case .buy:
                guard entry.fromAccountID == nil, entry.toAccountID != nil,
                      entry.receivedSats > 0, entry.amountSats == entry.receivedSats,
                      entry.amountCNY > 0 else {
                    throw LedgerError.invalid("购买需选择存入账户，并填写实际投入人民币和实际获得 BTC。")
                }
                if let conversion = entry.conversion {
                    let rate = conversion.rate
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                    guard rate.date.timeIntervalSinceReferenceDate.isFinite,
                          calendar.startOfDay(for: rate.date) == rate.date,
                          rate.availableAt <= entry.date, entry.date.timeIntervalSince(rate.date) <= 7 * 86_400,
                          !rate.cnyPerUSD.isNaN, rate.cnyPerUSD > 0, rate.cnyPerUSD < 1000,
                          Amounts.rounded(rate.cnyPerUSD) == rate.cnyPerUSD,
                          !rate.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rate.source.count <= 200,
                          !conversion.amountUSD.isNaN, conversion.amountUSD > 0, conversion.amountUSD <= Amounts.maximumCNY,
                          conversion.amountUSD == Amounts.rounded(entry.amountCNY / rate.cnyPerUSD) else {
                        throw LedgerError.invalid("美元投入与已公布的历史汇率不一致；请重新换算该购买记录。")
                    }
                }
            case .transfer:
                guard entry.fromAccountID != nil, entry.toAccountID != nil,
                      entry.fromAccountID != entry.toAccountID, entry.amountSats > 0,
                      entry.receivedSats <= entry.amountSats, entry.amountCNY == 0, entry.conversion == nil else {
                    throw LedgerError.invalid("转移需选择不同账户，转出 BTC 大于 0，到账不能超过转出数量。")
                }
            }
        }
    }

    private static func apply(_ entry: LedgerEntry, to result: inout LedgerSnapshot) throws {
        switch entry.kind {
        case .buy:
            if let total = result.totalInvestedUSD, let dollars = entry.amountUSD {
                result.totalInvestedUSD = try adding(total, dollars)
            } else { result.totalInvestedUSD = nil }
            result.totalPurchasedSats = try adding(result.totalPurchasedSats, entry.receivedSats)
            try credit(entry.receivedSats, account: entry.toAccountID!, to: &result)
        case .transfer:
            let source = entry.fromAccountID!
            guard let available = result.balances[source], available >= entry.amountSats else {
                throw LedgerError.invalid("来源账户在记录发生时余额不足；请检查日期、数量及之前的购买记录。")
            }
            result.balances[source] = available - entry.amountSats
            try credit(entry.receivedSats, account: entry.toAccountID!, to: &result)
            result.totalLossSats = try adding(result.totalLossSats, entry.lossSats)
        }
        result.totalSats = result.totalPurchasedSats - result.totalLossSats
        let accountTotal = try result.balances.values.reduce(Int64(0)) { try adding($0, $1) }
        guard result.totalSats >= 0, result.totalSats <= Amounts.maximumSats,
              result.totalInvestedUSD == nil || result.totalInvestedUSD! <= Amounts.maximumCNY,
              accountTotal == result.totalSats else {
            throw LedgerError.invalid("账户余额、BTC 总量或累计投入超出支持范围。")
        }
    }

    private static func credit(_ sats: Int64, account: UUID, to snapshot: inout LedgerSnapshot) throws {
        guard let balance = snapshot.balances[account] else { throw LedgerError.invalid("存入账户不存在。") }
        let updated = try adding(balance, sats)
        guard updated <= Amounts.maximumSats else { throw LedgerError.invalid("账户 BTC 数量超出支持范围。") }
        snapshot.balances[account] = updated
    }

    private static func adding(_ first: Int64, _ second: Int64) throws -> Int64 {
        let (sum, overflow) = first.addingReportingOverflow(second)
        guard !overflow else { throw LedgerError.invalid("BTC 累计数量超出支持范围。") }
        return sum
    }
    private static func adding(_ first: Decimal, _ second: Decimal) throws -> Decimal {
        var lhs = first, rhs = second, sum = Decimal()
        guard NSDecimalAdd(&sum, &lhs, &rhs, .bankers) == .noError, !sum.isNaN else {
            throw LedgerError.invalid("累计金额超出精确计算范围。")
        }
        return sum
    }
}
