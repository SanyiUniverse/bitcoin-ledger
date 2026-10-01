import Foundation

public enum LedgerEngine {
    /// Replays the complete history. Edits/deletions are validated by replaying the proposed history.
    public static func calculate(accounts: [Account], entries: [LedgerEntry]) throws -> LedgerSnapshot {
        guard Set(accounts.map(\.id)).count == accounts.count else {
            throw LedgerError.invalid("账户 ID 重复，无法计算账本。")
        }
        guard Set(entries.map(\.id)).count == entries.count else {
            throw LedgerError.invalid("记录 ID 重复，无法计算账本。")
        }
        let accountIDs = Set(accounts.map(\.id))
        var accountNames = Set<String>()
        for account in accounts {
            guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  account.name.count <= 100 else {
                throw LedgerError.invalid("账户名称不能为空，且最多 100 个字符。")
            }
            let normalized = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard account.isArchived || accountNames.insert(normalized).inserted else {
                throw LedgerError.invalid("账户名称不能重复（不区分大小写）。")
            }
        }
        // Validate before sorting: NaN dates must never enter a comparison predicate.
        for entry in entries {
            try validate(entry, accountIDs: accountIDs)
        }
        let ordered = entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result = LedgerSnapshot(balances: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, 0) }))
        for entry in ordered {
            result.totalFeeCNY = try adding(result.totalFeeCNY, entry.feeCNYEquivalent)
            result.totalFeeSats = try adding(result.totalFeeSats, entry.feeSats)
            switch entry.kind {
            case .buy:
                let destination = entry.toAccountID!
                let grossSats = try adding(entry.amountSats, entry.feeSats)
                let cashCost = try adding(entry.amountCNY, entry.feeCNY)
                try credit(entry.amountSats, account: destination, snapshot: &result)
                result.totalSats = try adding(result.totalSats, entry.amountSats)
                result.purchasedSats = try adding(result.purchasedSats, grossSats)
                result.purchasePrincipalCNY = try adding(result.purchasePrincipalCNY, entry.amountCNY)
                result.investedCNY = try adding(result.investedCNY, cashCost)
                result.costBasisCNY = try adding(result.costBasisCNY, cashCost)

            case .transfer:
                try debit(entry.amountSats, account: entry.fromAccountID!, snapshot: &result)
                try credit(entry.receivedSats, account: entry.toAccountID!, snapshot: &result)
                result.totalSats -= entry.feeSats
                // Moving BTC does not dispose its cost. Fee loss is absorbed by remaining BTC.
                try addExternalFee(entry.feeCNY, snapshot: &result)
                absorbFinalBTCFee(snapshot: &result)

            case .sell:
                let debitSats = try adding(entry.amountSats, entry.feeSats)
                let priorTotal = result.totalSats
                try debit(debitSats, account: entry.fromAccountID!, snapshot: &result)
                guard priorTotal >= debitSats, priorTotal > 0 else {
                    throw LedgerError.invalid("卖出及手续费超过当时 BTC 总余额。")
                }
                // Allocate from the whole personal pool, independent of the selling account.
                // A final disposal takes all residual basis so rounding cannot strand cost.
                let disposedBasis = debitSats == priorTotal
                    ? result.costBasisCNY
                    : Amounts.rounded(result.costBasisCNY * Decimal(debitSats) / Decimal(priorTotal))
                result.costBasisCNY -= disposedBasis
                result.totalSats -= debitSats
                result.realizedPnLCNY = try adding(result.realizedPnLCNY, entry.amountCNY - disposedBasis)
                // amountCNY is actual net proceeds: do not subtract the informational CNY fee twice.

            case .fee:
                if entry.feeCurrency == .btc {
                    try debit(entry.feeSats, account: entry.fromAccountID!, snapshot: &result)
                    result.totalSats -= entry.feeSats
                    absorbFinalBTCFee(snapshot: &result)
                } else {
                    try addExternalFee(entry.feeCNY, snapshot: &result)
                }
            }
            guard result.totalSats >= 0, result.totalSats <= Amounts.maximumSats else {
                throw LedgerError.invalid("BTC 总余额必须在 0 至 21,000,000 BTC 之间。")
            }
        }
        // Make the account conservation invariant explicit, even when introducing future event types.
        let accountTotal = try result.balances.values.reduce(Int64(0)) { try adding($0, $1) }
        guard accountTotal == result.totalSats else {
            throw LedgerError.invalid("账户余额与 BTC 总量不一致。")
        }
        guard accounts.filter(\.isArchived).allSatisfy({ result.balances[$0.id] == 0 }) else {
            throw LedgerError.invalid("已删除的账户仍有 BTC 余额；请先清空余额再删除。")
        }
        return result
    }

    private static func validate(_ entry: LedgerEntry, accountIDs: Set<UUID>) throws {
        guard entry.date.timeIntervalSinceReferenceDate.isFinite,
              entry.sequence >= 0, entry.sequence < Int64.max, entry.note.count <= 10_000 else {
            throw LedgerError.invalid("记录日期、顺序或备注无效。")
        }
        for id in [entry.fromAccountID, entry.toAccountID].compactMap({ $0 }) {
            guard accountIDs.contains(id) else { throw LedgerError.invalid("记录引用了不存在的账户。") }
        }
        guard [entry.amountSats, entry.receivedSats, entry.feeSats].allSatisfy({ $0 >= 0 && $0 <= Amounts.maximumSats }) else {
            throw LedgerError.invalid("BTC 数量必须在 0 至 21,000,000 BTC 之间。")
        }
        try validateDecimal(entry.amountCNY, maximum: Amounts.maximumCNY, places: 2, name: "人民币金额")
        try validateDecimal(entry.feeCNY, maximum: Amounts.maximumCNY, places: 2, name: "人民币手续费")
        try validateDecimal(entry.feePriceCNY, maximum: Amounts.maximumPrice, places: 8, name: "手续费发生时 BTC 价格")
        switch entry.feeCurrency {
        case .cny:
            guard entry.feeSats == 0, entry.feePriceCNY == 0 else {
                throw LedgerError.invalid("人民币手续费不能同时带有 BTC 手续费或换算价格。")
            }
        case .btc:
            guard entry.feeCNY == 0,
                  (entry.feeSats > 0 && entry.feePriceCNY > 0) || (entry.feeSats == 0 && entry.feePriceCNY == 0) else {
                throw LedgerError.invalid("BTC 手续费需保留当时人民币价格；不能同时输入人民币手续费。")
            }
        }
        switch entry.kind {
        case .buy:
            guard entry.toAccountID != nil, entry.fromAccountID == nil,
                  entry.amountSats > 0, entry.amountCNY > 0, entry.receivedSats == 0,
                  try adding(entry.amountSats, entry.feeSats) <= Amounts.maximumSats else {
                throw LedgerError.invalid("买入需选择存入账户、输入正数人民币本金及实际到账 BTC。")
            }
        case .transfer:
            guard entry.fromAccountID != nil, entry.toAccountID != nil,
                  entry.fromAccountID != entry.toAccountID,
                  entry.amountSats > 0, entry.receivedSats > 0,
                  entry.receivedSats <= entry.amountSats,
                  entry.amountSats - entry.receivedSats == entry.feeSats,
                  entry.amountCNY == 0 else {
                throw LedgerError.invalid("转账需选择不同账户；转出总额必须等于实际到账加 BTC 手续费。")
            }
        case .sell:
            guard entry.fromAccountID != nil, entry.toAccountID == nil,
                  entry.amountSats > 0, entry.receivedSats == 0 else {
                throw LedgerError.invalid("卖出需选择来源账户并输入正数 BTC；消费可将实收人民币填为 0。")
            }
        case .fee:
            guard entry.toAccountID == nil, entry.amountSats == 0,
                  entry.receivedSats == 0, entry.amountCNY == 0,
                  (entry.feeCurrency == .btc && entry.feeSats > 0 && entry.fromAccountID != nil)
                    || (entry.feeCurrency == .cny && entry.feeCNY > 0) else {
                throw LedgerError.invalid("独立费用需为正数；BTC 费用需选择支付账户。")
            }
        }
    }

    private static func validateDecimal(_ value: Decimal, maximum: Decimal, places: Int, name: String) throws {
        guard !value.isNaN, value >= 0, value <= maximum, Amounts.rounded(value, scale: places) == value else {
            throw LedgerError.invalid("\(name)超出支持范围或小数超过 \(places) 位。")
        }
    }

    private static func adding(_ first: Int64, _ second: Int64) throws -> Int64 {
        let (sum, overflow) = first.addingReportingOverflow(second)
        guard !overflow else { throw LedgerError.invalid("BTC 累计数量超出支持范围。") }
        return sum
    }

    private static func adding(_ first: Decimal, _ second: Decimal) throws -> Decimal {
        var lhs = first
        var rhs = second
        var sum = Decimal()
        let status = NSDecimalAdd(&sum, &lhs, &rhs, .bankers)
        guard status == .noError, !sum.isNaN else {
            throw LedgerError.invalid("累计金额超出精确计算范围。")
        }
        return sum
    }

    private static func debit(_ sats: Int64, account id: UUID, snapshot: inout LedgerSnapshot) throws {
        guard let balance = snapshot.balances[id], balance >= sats else {
            throw LedgerError.invalid("该账户在记录发生时余额不足；请检查日期、数量及之前的记录。")
        }
        snapshot.balances[id] = balance - sats
    }

    private static func credit(_ sats: Int64, account id: UUID, snapshot: inout LedgerSnapshot) throws {
        guard let balance = snapshot.balances[id] else { throw LedgerError.invalid("存入账户不存在。") }
        let updated = try adding(balance, sats)
        guard updated <= Amounts.maximumSats else { throw LedgerError.invalid("账户 BTC 数量超出支持范围。") }
        snapshot.balances[id] = updated
    }

    private static func addExternalFee(_ cny: Decimal, snapshot: inout LedgerSnapshot) throws {
        guard cny > 0 else { return }
        snapshot.investedCNY = try adding(snapshot.investedCNY, cny)
        if snapshot.totalSats > 0 {
            snapshot.costBasisCNY = try adding(snapshot.costBasisCNY, cny)
        } else {
            snapshot.realizedPnLCNY = try adding(snapshot.realizedPnLCNY, -cny)
        }
    }

    private static func absorbFinalBTCFee(snapshot: inout LedgerSnapshot) {
        if snapshot.totalSats == 0 {
            snapshot.realizedPnLCNY -= snapshot.costBasisCNY
            snapshot.costBasisCNY = 0
        }
    }
}
