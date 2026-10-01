import Foundation

public enum LedgerEngine {
    /// Cash-recovery accounting: CNY principal moves between BTC and USDT.
    /// CNY receipts, expenses and exhausted fee pools determine realized results.
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
            guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, account.name.count <= 100 else {
                throw LedgerError.invalid("账户名称不能为空，且最多 100 个字符。")
            }
            let normalized = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard account.isArchived || accountNames.insert(normalized).inserted else {
                throw LedgerError.invalid("账户名称不能重复（不区分大小写）。")
            }
        }
        for entry in entries { try validate(entry, accountIDs: accountIDs) }
        let ordered = entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result = LedgerSnapshot(balances: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, 0) }))
        for entry in ordered {
            let valuation: EntryValuation
            switch entry.kind {
            case .adjustUSDT:
                // amountUSDT is the reference balance seen when entering this
                // record. The target, not that old reference, anchors replay.
                let priorBalance = result.usdtBalance
                let priorCost = result.usdtCostBasisCNY
                result.usdtBalance = entry.receivedUSDT
                if result.usdtBalance == 0 {
                    result.realizedPnLCNY = try adding(result.realizedPnLCNY, -priorCost)
                    result.usdtCostBasisCNY = 0
                }
                valuation = EntryValuation(costCNY: priorCost, beforeUSDT: priorBalance,
                                           afterUSDT: result.usdtBalance)
            case .buyUSDT:
                // The C2C amount is total cash paid, including its CNY fee.
                result.investedCNY = try adding(result.investedCNY, entry.amountCNY)
                try creditUSDT(entry.receivedUSDT, cost: entry.amountCNY, snapshot: &result)
                valuation = try value(entry, cost: entry.amountCNY, feeBasis: entry.amountCNY,
                                      feeQuantity: try adding(entry.receivedUSDT, entry.feeUSDT))
            case .buy:
                let grossSats = try adding(entry.amountSats, entry.feeSats)
                let acquisitionCost: Decimal
                let purchasePrincipal: Decimal
                let feeBasis: Decimal
                let feeQuantity: Decimal
                switch entry.settlementCurrency {
                case .cny:
                    acquisitionCost = try adding(entry.amountCNY, entry.feeCNY)
                    purchasePrincipal = entry.amountCNY
                    result.investedCNY = try adding(result.investedCNY, acquisitionCost)
                    feeBasis = acquisitionCost
                    feeQuantity = Amounts.btc(grossSats)
                case .usdt:
                    let priorBasis = result.usdtCostBasisCNY
                    let priorUSDT = result.usdtBalance
                    let transferredCost = try consumeUSDT(entry.amountUSDT, snapshot: &result)
                    acquisitionCost = try adding(transferredCost, entry.feeCNY)
                    // A CNY fee is extra external cash; a USDT fee is inside total debit.
                    result.investedCNY = try adding(result.investedCNY, entry.feeCNY)
                    let includedFeeCost = try portion(priorBasis, quantity: entry.feeUSDT, total: priorUSDT)
                    purchasePrincipal = transferredCost - includedFeeCost
                    if entry.feeCurrency == .usdt {
                        feeBasis = priorBasis
                        feeQuantity = priorUSDT
                    } else {
                        feeBasis = acquisitionCost
                        feeQuantity = Amounts.btc(grossSats)
                    }
                }
                try credit(entry.amountSats, account: entry.toAccountID!, snapshot: &result)
                result.totalSats = try adding(result.totalSats, entry.amountSats)
                result.purchasedSats = try adding(result.purchasedSats, grossSats)
                result.purchasePrincipalCNY = try adding(result.purchasePrincipalCNY, purchasePrincipal)
                result.costBasisCNY = try adding(result.costBasisCNY, acquisitionCost)
                valuation = try value(entry, cost: acquisitionCost, feeBasis: feeBasis, feeQuantity: feeQuantity)
            case .transfer:
                let priorBasis = result.costBasisCNY
                let priorBTC = Amounts.btc(result.totalSats)
                let transferredCost = try portion(priorBasis, quantity: Amounts.btc(entry.amountSats), total: priorBTC)
                try debit(entry.amountSats, account: entry.fromAccountID!, snapshot: &result)
                try credit(entry.receivedSats, account: entry.toAccountID!, snapshot: &result)
                result.totalSats -= entry.feeSats
                try addExternalFee(entry.feeCNY, snapshot: &result)
                try clearExhaustedBTC(snapshot: &result)
                valuation = try value(entry, cost: transferredCost, feeBasis: priorBasis, feeQuantity: priorBTC)
            case .sell:
                let priorBasis = result.costBasisCNY
                let priorBTC = Amounts.btc(result.totalSats)
                let debitSats = try adding(entry.amountSats, entry.feeSats)
                let disposedCost = try consumeBTC(debitSats, account: entry.fromAccountID!, snapshot: &result)
                switch entry.settlementCurrency {
                case .cny:
                    result.returnedCNY = try adding(result.returnedCNY, entry.amountCNY)
                    result.realizedPnLCNY = try adding(result.realizedPnLCNY, entry.amountCNY - disposedCost)
                    valuation = try value(entry, cost: disposedCost, feeBasis: priorBasis, feeQuantity: priorBTC)
                case .usdt:
                    let receivedCost = try adding(disposedCost, entry.feeCNY)
                    result.investedCNY = try adding(result.investedCNY, entry.feeCNY)
                    try creditUSDT(entry.receivedUSDT, cost: receivedCost, snapshot: &result)
                    // No actual CNY receipt, no assumed USDT exchange rate.
                    if entry.feeCurrency == .usdt {
                        valuation = try value(entry, cost: disposedCost, feeBasis: receivedCost,
                                              feeQuantity: try adding(entry.receivedUSDT, entry.feeUSDT))
                    } else {
                        valuation = try value(entry, cost: disposedCost, feeBasis: priorBasis, feeQuantity: priorBTC)
                    }
                }
            case .sellUSDT:
                let priorBasis = result.usdtCostBasisCNY
                let priorUSDT = result.usdtBalance
                let disposedCost = try consumeUSDT(entry.amountUSDT, snapshot: &result)
                // USDT debit includes its USDT fee; CNY proceeds are already net.
                result.returnedCNY = try adding(result.returnedCNY, entry.amountCNY)
                result.realizedPnLCNY = try adding(result.realizedPnLCNY, entry.amountCNY - disposedCost)
                valuation = try value(entry, cost: disposedCost, feeBasis: priorBasis, feeQuantity: priorUSDT)
            case .fee:
                switch entry.feeCurrency {
                case .btc:
                    let priorBasis = result.costBasisCNY
                    let priorBTC = Amounts.btc(result.totalSats)
                    let feeCost = try portion(priorBasis, quantity: Amounts.btc(entry.feeSats), total: priorBTC)
                    try debit(entry.feeSats, account: entry.fromAccountID!, snapshot: &result)
                    result.totalSats -= entry.feeSats
                    try clearExhaustedBTC(snapshot: &result)
                    valuation = try value(entry, cost: feeCost, feeBasis: priorBasis, feeQuantity: priorBTC)
                case .usdt:
                    let priorBasis = result.usdtCostBasisCNY
                    let priorUSDT = result.usdtBalance
                    guard priorUSDT >= entry.feeUSDT else {
                        throw LedgerError.invalid("记录发生时 USDT 余额不足，无法支付手续费。")
                    }
                    let feeCost = try portion(priorBasis, quantity: entry.feeUSDT, total: priorUSDT)
                    result.usdtBalance -= entry.feeUSDT
                    // Surviving USDT absorb the quantity loss, as BTC already does.
                    if result.usdtBalance == 0 {
                        result.realizedPnLCNY = try adding(result.realizedPnLCNY, -result.usdtCostBasisCNY)
                        result.usdtCostBasisCNY = 0
                    }
                    valuation = try value(entry, cost: feeCost, feeBasis: priorBasis, feeQuantity: priorUSDT)
                case .cny:
                    try addExternalFee(entry.feeCNY, snapshot: &result)
                    valuation = try value(entry, cost: entry.feeCNY)
                }
            }
            result.entryValuations[entry.id] = valuation
            result.totalFeeCNY = try adding(result.totalFeeCNY, valuation.feeCNYEquivalent)
            result.totalFeeSats = try adding(result.totalFeeSats, entry.feeSats)
            result.totalFeeUSDT = try adding(result.totalFeeUSDT, entry.feeUSDT)
            try checkInvariants(result)
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
        try validateDecimal(entry.feePriceCNY, maximum: Amounts.maximumPrice, places: 8, name: "手续费人民币换算价")
        for (number, name) in [(entry.amountUSDT, "USDT 扣款"), (entry.receivedUSDT, "USDT 到账"), (entry.feeUSDT, "USDT 手续费")] {
            try validateDecimal(number, maximum: Amounts.maximumUSDT, places: 8, name: name)
        }
        if entry.feeValuationSource == .costBasis && entry.feePriceCNY != 0 {
            throw LedgerError.invalid("按本金自动估算的费用不填写手工换算价。")
        }
        switch entry.feeCurrency {
        case .cny:
            guard entry.feeSats == 0, entry.feeUSDT == 0, entry.feePriceCNY == 0 else {
                throw LedgerError.invalid("人民币手续费不能同时填写 BTC 或 USDT 费用及换算价。")
            }
        case .btc:
            guard entry.feeCNY == 0, entry.feeUSDT == 0,
                  (entry.feeSats > 0
                    ? (entry.feeValuationSource == .costBasis || entry.feePriceCNY > 0)
                    : entry.feePriceCNY == 0) else {
                throw LedgerError.invalid("BTC 费用需选择本金估算或有效的历史价格；不能同时填写其他币种费用。")
            }
        case .usdt:
            guard entry.feeCNY == 0, entry.feeSats == 0,
                  entry.feePriceCNY == 0, entry.feeValuationSource == .costBasis else {
                throw LedgerError.invalid("USDT 费用按人民币本金自动估算，不能同时填写其他币种费用。")
            }
        }
        switch entry.kind {
        case .adjustUSDT:
            guard entry.fromAccountID == nil, entry.toAccountID == nil,
                  entry.amountSats == 0, entry.receivedSats == 0, entry.amountCNY == 0,
                  entry.feeCurrency == .cny, entry.feeCNY == 0, entry.feeSats == 0,
                  entry.feeUSDT == 0, entry.feePriceCNY == 0,
                  entry.settlementCurrency == .cny, entry.feeValuationSource == .manualPrice else {
                throw LedgerError.invalid("USDT 余额调整只填写参考余额、实际余额和备注，不填写交易金额、账户或手续费。")
            }
        case .buyUSDT:
            guard entry.settlementCurrency == .cny, entry.fromAccountID == nil, entry.toAccountID == nil,
                  entry.amountSats == 0, entry.receivedSats == 0, entry.amountUSDT == 0,
                  entry.receivedUSDT > 0, entry.amountCNY > 0, entry.feeCurrency != .btc,
                  entry.feeCNY <= entry.amountCNY,
                  try adding(entry.receivedUSDT, entry.feeUSDT) <= Amounts.maximumUSDT else {
                throw LedgerError.invalid("购买 USDT 需填写总实付人民币及净到账 USDT；人民币费用已包含在实付中。")
            }
        case .buy:
            guard entry.toAccountID != nil, entry.fromAccountID == nil,
                  entry.amountSats > 0, entry.receivedSats == 0, entry.receivedUSDT == 0,
                  try adding(entry.amountSats, entry.feeSats) <= Amounts.maximumSats else {
                throw LedgerError.invalid("买入需选择 BTC 存入账户，并输入实际净到账 BTC。")
            }
            switch entry.settlementCurrency {
            case .cny:
                guard entry.amountCNY > 0, entry.amountUSDT == 0, entry.feeCurrency != .usdt else {
                    throw LedgerError.invalid("人民币直买需填写购买本金，且仅支持人民币或 BTC 手续费。")
                }
            case .usdt:
                guard entry.amountCNY == 0, entry.amountUSDT > 0, entry.feeUSDT < entry.amountUSDT else {
                    throw LedgerError.invalid("USDT 买 BTC 需填写包含 USDT 手续费的总扣款；手续费必须少于总扣款。")
                }
            }
        case .transfer:
            guard entry.settlementCurrency == .cny, entry.fromAccountID != nil, entry.toAccountID != nil,
                  entry.fromAccountID != entry.toAccountID,
                  entry.amountSats > 0, entry.receivedSats > 0, entry.receivedSats <= entry.amountSats,
                  entry.amountSats - entry.receivedSats == entry.feeSats,
                  entry.amountCNY == 0, entry.amountUSDT == 0, entry.receivedUSDT == 0,
                  entry.feeCurrency != .usdt else {
                throw LedgerError.invalid("转账需不同账户，转出总额等于净到账加 BTC 费用；USDT 费用请独立记录。")
            }
        case .sell:
            guard entry.fromAccountID != nil, entry.toAccountID == nil,
                  entry.amountSats > 0, entry.receivedSats == 0, entry.amountUSDT == 0 else {
                throw LedgerError.invalid("卖出需选择 BTC 来源账户并输入正数 BTC 成交量。")
            }
            switch entry.settlementCurrency {
            case .cny:
                guard entry.receivedUSDT == 0, entry.feeCurrency != .usdt else {
                    throw LedgerError.invalid("人民币直卖不填写 USDT 金额或 USDT 手续费。")
                }
            case .usdt:
                guard entry.amountCNY == 0, entry.receivedUSDT > 0,
                      try adding(entry.receivedUSDT, entry.feeUSDT) <= Amounts.maximumUSDT else {
                    throw LedgerError.invalid("卖 BTC 收 USDT 需填写净到账 USDT，不填写人民币回款。")
                }
            }
        case .sellUSDT:
            guard entry.settlementCurrency == .cny, entry.fromAccountID == nil, entry.toAccountID == nil,
                  entry.amountSats == 0, entry.receivedSats == 0, entry.receivedUSDT == 0,
                  entry.amountUSDT > 0, entry.feeCurrency != .btc, entry.feeUSDT <= entry.amountUSDT,
                  entry.amountCNY == 0 || entry.feeUSDT < entry.amountUSDT else {
                throw LedgerError.invalid("兑回人民币需填写 USDT 总扣款及实际净回款；不能填写 BTC 数量或费用。")
            }
        case .fee:
            guard entry.settlementCurrency == .cny, entry.toAccountID == nil, entry.amountSats == 0,
                  entry.receivedSats == 0, entry.amountCNY == 0, entry.amountUSDT == 0, entry.receivedUSDT == 0,
                  (entry.feeCurrency == .btc && entry.feeSats > 0 && entry.fromAccountID != nil)
                    || (entry.feeCurrency == .cny && entry.feeCNY > 0)
                    || (entry.feeCurrency == .usdt && entry.feeUSDT > 0 && entry.fromAccountID == nil) else {
                throw LedgerError.invalid("独立费用需为正数；BTC 费用需选付款账户，USDT 使用统一余额。")
            }
        }
    }

    private static func value(_ entry: LedgerEntry, cost: Decimal,
                              feeBasis: Decimal = 0, feeQuantity: Decimal = 0) throws -> EntryValuation {
        if entry.feeCurrency == .cny {
            return EntryValuation(costCNY: cost, feeCNYEquivalent: entry.feeCNY,
                                  feeUnitCostCNY: entry.feeCNY > 0 ? 1 : 0)
        }
        let quantity = entry.feeCurrency == .btc ? Amounts.btc(entry.feeSats) : entry.feeUSDT
        guard quantity > 0 else { return EntryValuation(costCNY: cost) }
        if entry.feeValuationSource == .manualPrice {
            return EntryValuation(costCNY: cost, feeCNYEquivalent: entry.feeCNYEquivalent,
                                  feeUnitCostCNY: entry.feePriceCNY)
        }
        let equivalent = try portion(feeBasis, quantity: quantity, total: feeQuantity)
        return EntryValuation(costCNY: cost, feeCNYEquivalent: equivalent,
                              feeUnitCostCNY: Amounts.rounded(feeBasis / feeQuantity))
    }

    /// Final disposal takes all residual basis; partial allocations round to 12.
    private static func portion(_ basis: Decimal, quantity: Decimal, total: Decimal) throws -> Decimal {
        guard quantity > 0 else { return 0 }
        guard total > 0, quantity <= total, basis >= 0 else {
            throw LedgerError.invalid("记录发生时资产余额不足，无法分摊人民币本金。")
        }
        if quantity == total { return basis }
        let result = Amounts.rounded(basis * quantity / total)
        guard !result.isNaN, result >= 0, result <= basis else {
            throw LedgerError.invalid("人民币本金分摊超出精确计算范围。")
        }
        return result
    }

    private static func consumeUSDT(_ quantity: Decimal, snapshot: inout LedgerSnapshot) throws -> Decimal {
        guard quantity > 0, snapshot.usdtBalance >= quantity else {
            throw LedgerError.invalid("记录发生时 USDT 余额不足；请检查购入记录、日期和总扣款。")
        }
        let cost = try portion(snapshot.usdtCostBasisCNY, quantity: quantity, total: snapshot.usdtBalance)
        snapshot.usdtBalance -= quantity
        snapshot.usdtCostBasisCNY -= cost
        return cost
    }

    private static func creditUSDT(_ quantity: Decimal, cost: Decimal, snapshot: inout LedgerSnapshot) throws {
        snapshot.usdtBalance = try adding(snapshot.usdtBalance, quantity)
        snapshot.usdtCostBasisCNY = try adding(snapshot.usdtCostBasisCNY, cost)
    }

    private static func consumeBTC(_ sats: Int64, account: UUID, snapshot: inout LedgerSnapshot) throws -> Decimal {
        let cost = try portion(snapshot.costBasisCNY, quantity: Decimal(sats), total: Decimal(snapshot.totalSats))
        try debit(sats, account: account, snapshot: &snapshot)
        snapshot.totalSats -= sats
        snapshot.costBasisCNY -= cost
        return cost
    }

    private static func validateDecimal(_ number: Decimal, maximum: Decimal, places: Int, name: String) throws {
        guard !number.isNaN, number >= 0, number <= maximum, Amounts.rounded(number, scale: places) == number else {
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
        guard status == .noError, !sum.isNaN else { throw LedgerError.invalid("累计金额超出精确计算范围。") }
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

    /// Preserve v1 standalone CNY-fee behavior; conversion-specific fees above
    /// capitalize the asset acquired in that conversion instead.
    private static func addExternalFee(_ cny: Decimal, snapshot: inout LedgerSnapshot) throws {
        guard cny > 0 else { return }
        snapshot.investedCNY = try adding(snapshot.investedCNY, cny)
        if snapshot.totalSats > 0 {
            snapshot.costBasisCNY = try adding(snapshot.costBasisCNY, cny)
        } else {
            snapshot.realizedPnLCNY = try adding(snapshot.realizedPnLCNY, -cny)
        }
    }

    private static func clearExhaustedBTC(snapshot: inout LedgerSnapshot) throws {
        if snapshot.totalSats == 0 {
            snapshot.realizedPnLCNY = try adding(snapshot.realizedPnLCNY, -snapshot.costBasisCNY)
            snapshot.costBasisCNY = 0
        }
    }

    private static func checkInvariants(_ snapshot: LedgerSnapshot) throws {
        guard snapshot.totalSats >= 0, snapshot.totalSats <= Amounts.maximumSats,
              snapshot.usdtBalance >= 0, snapshot.usdtBalance <= Amounts.maximumUSDT,
              snapshot.costBasisCNY >= 0, snapshot.usdtCostBasisCNY >= 0,
              snapshot.totalSats > 0 || snapshot.costBasisCNY == 0,
              snapshot.usdtBalance > 0 || snapshot.usdtCostBasisCNY == 0 else {
            throw LedgerError.invalid("资产数量或人民币本金超出支持范围。")
        }
        let accountTotal = try snapshot.balances.values.reduce(Int64(0)) { try adding($0, $1) }
        guard accountTotal == snapshot.totalSats else { throw LedgerError.invalid("账户余额与 BTC 总量不一致。") }
        let assetBasis = try adding(snapshot.costBasisCNY, snapshot.usdtCostBasisCNY)
        let netCash = try adding(snapshot.investedCNY, -snapshot.returnedCNY)
        guard assetBasis == (try adding(netCash, snapshot.realizedPnLCNY)) else {
            throw LedgerError.invalid("BTC、USDT 本金与人民币投入、回款、兑现收益不一致。")
        }
    }
}
