import SwiftUI
import LedgerCore

struct AccountsView: View {
    @EnvironmentObject private var store: AppStore
    let onAdd: () -> Void; let onEdit: (Account) -> Void; let onEntry: (LedgerEntry) -> Void
    @State private var selected: UUID?
    @State private var pendingDelete: Account?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BTC 账户").font(.title2.weight(.semibold))
                        Text("\(Display.btc(store.snapshot?.totalSats ?? 0)) BTC").font(.title3).monospacedDigit()
                    }
                    Spacer()
                    Button("添加账户", systemImage: "plus", action: onAdd)
                }
                ForEach(AccountKind.allCases, id: \.self) { kind in
                    GroupBox {
                        VStack(spacing: 8) {
                            ForEach(store.accounts.filter { $0.kind == kind }) { account in
                                HStack {
                                    Button { selected = selected == account.id ? nil : account.id } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(account.name).font(.headline)
                                                Text("\(Display.btc(store.snapshot?.balances[account.id] ?? 0)) BTC").monospacedDigit()
                                            }
                                            Spacer()
                                            Image(systemName: selected == account.id ? "chevron.down" : "chevron.right").font(.caption)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Menu {
                                        Button("重命名") { onEdit(account) }
                                        Button("删除空账户", role: .destructive) { pendingDelete = account }
                                            .disabled((store.snapshot?.balances[account.id] ?? 0) != 0)
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26)
                                }.padding(10)
                            }
                            if !store.accounts.contains(where: { $0.kind == kind }) { Text("还没有账户").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        }
                    } label: { Label("\(kind.english) / \(kind.title)", systemImage: kind.icon).font(.headline) }
                }
                if let selected {
                    VStack(alignment: .leading) {
                        Text("\(store.accountName(selected)) · 历史记录").font(.headline)
                        let entries = store.entries.filter { $0.fromAccountID == selected || $0.toAccountID == selected }
                        if entries.isEmpty { Text("还没有记录").foregroundStyle(.secondary).padding(.vertical) }
                        ForEach(entries) { entry in Button { onEntry(entry) } label: { EntryRow(entry: entry) }.buttonStyle(.plain); Divider() }
                    }
                }
                Text("可删除余额为零的账户。其历史记录仍会保留，确保账目可追溯。").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .confirmationDialog("删除此空账户？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let account = pendingDelete { do { try store.deleteAccount(account) } catch { store.message = error.localizedDescription } }
                pendingDelete = nil
            }
        }
    }
}

struct EntryDetail: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let entry: LedgerEntry; let onEdit: () -> Void
    @State private var confirmDelete = false
    @State private var error: String?
    private var valuation: EntryValuation? { store.valuation(for: entry) }
    private var title: String {
        entry.kind == .sell && entry.settlementCurrency == .cny && entry.amountCNY == 0 ? "花费 BTC" : entry.kind.title
    }
    private var hasFee: Bool { entry.feeSats > 0 || entry.feeCNY > 0 || entry.feeUSDT > 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(title, systemImage: entry.kind.icon).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 14) {
                        DataRow("日期时间", entry.date.formatted(date: .complete, time: .standard))
                        transactionRows
                        if let valuation, entry.kind != .fee {
                            Divider()
                            DataRow(principalLabel, Display.money(valuation.costCNY))
                            if entry.kind == .sell && entry.settlementCurrency == .usdt {
                                DataRow("计入 USDT 的人民币本金", Display.money(valuation.costCNY + entry.feeCNY))
                                Text("卖回 USDT 延续这笔 BTC 的原始本金；额外支付的人民币手续费一并计入，暂不确认已兑人民币盈亏。")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            } else if entry.kind == .transfer {
                                Text("本金继续由 BTC 持仓承接。转账不是买卖，余额只减少手续费。")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            } else if entry.kind == .adjustUSDT {
                                Text(entry.receivedUSDT > 0 ? "调整后的 USDT 继续承接原人民币本金，每 USDT 平均本金会重新计算。" : "USDT 余额清零，原人民币本金计入调整损失。")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                Text("这条调整不增加人民币投入或回款，也不冲减原手续费记录。修改历史后，目标余额保持不变，差额与后续成本折算重新计算。")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if hasFee {
                            Divider()
                            DataRow(entry.feeCategory.title, Display.fee(entry))
                            if let valuation {
                                DataRow("手续费人民币等值", "¥\(Display.decimal(valuation.feeCNYEquivalent))")
                            }
                            if entry.feeSats > 0 && entry.feeValuationSource == .manualPrice {
                                DataRow("记录时 BTC / CNY", Display.money(entry.feePriceCNY))
                            } else if entry.feeSats > 0 || entry.feeUSDT > 0 {
                                Text("费用按本笔交易或扣款前的人民币成本自动折算。")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if !entry.note.isEmpty {
                        Text(entry.note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.trailing, 4)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("删除记录", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("编辑", action: onEdit).buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 650, height: 640)
        .confirmationDialog("删除这条记录？所有余额和成本将重新计算。", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                do { try store.deleteEntry(entry); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private var transactionRows: some View {
        switch entry.kind {
        case .buy:
            DataRow("到账账户", store.accountName(entry.toAccountID))
            DataRow("实际获得 BTC", "\(Display.btc(entry.amountSats)) BTC")
            if entry.settlementCurrency == .usdt {
                DataRow("实际扣除 USDT（含 USDT 手续费）", "\(Display.usdt(entry.amountUSDT)) USDT")
                if entry.feeCNY > 0 { DataRow("额外支付人民币手续费", Display.money(entry.feeCNY)) }
            } else {
                DataRow("购币金额（不含人民币手续费）", Display.money(entry.amountCNY))
            }
        case .sell:
            DataRow("转出账户", store.accountName(entry.fromAccountID))
            DataRow("卖出 / 花费 BTC", "\(Display.btc(entry.amountSats)) BTC")
            if entry.settlementCurrency == .usdt {
                DataRow("实际到账 USDT（已扣手续费）", "\(Display.usdt(entry.receivedUSDT)) USDT")
            } else {
                DataRow("实际收到人民币", Display.money(entry.amountCNY))
            }
        case .transfer:
            DataRow("转出账户", store.accountName(entry.fromAccountID))
            DataRow("到账账户", store.accountName(entry.toAccountID))
            DataRow("实际转出 BTC", "\(Display.btc(entry.amountSats)) BTC")
            DataRow("实际到账 BTC", "\(Display.btc(entry.receivedSats)) BTC")
        case .buyUSDT:
            DataRow("购入 USDT 支付人民币", Display.money(entry.amountCNY))
            DataRow("实际到账 USDT", "\(Display.usdt(entry.receivedUSDT)) USDT")
        case .sellUSDT:
            DataRow("实际扣除 USDT（含 USDT 手续费）", "\(Display.usdt(entry.amountUSDT)) USDT")
            DataRow("实际收到人民币", Display.money(entry.amountCNY))
        case .adjustUSDT:
            if let valuation, let before = valuation.beforeUSDT, let after = valuation.afterUSDT {
                DataRow("调整前 USDT 余额", "\(Display.usdt(before)) USDT")
                DataRow("调整后实际余额", "\(Display.usdt(after)) USDT")
                let change = after - before
                DataRow("本次调整差额", "\(change > 0 ? "+" : change < 0 ? "−" : "")\(Display.usdt(change < 0 ? -change : change)) USDT")
                if entry.amountUSDT != before {
                    DataRow("最初录入时的参考余额", "\(Display.usdt(entry.amountUSDT)) USDT")
                }
            }
        case .fee:
            if let id = entry.fromAccountID { DataRow("支付账户", store.accountName(id)) }
            else { DataRow("支付来源", entry.feeCurrency == .usdt ? "USDT 周转余额" : "人民币") }
        }
    }
    private var principalLabel: String {
        switch entry.kind {
        case .buy: "计入 BTC 的人民币本金"
        case .buyUSDT: "计入 USDT 的人民币本金"
        case .sell: "移出 BTC 的人民币本金"
        case .sellUSDT: "移出 USDT 的人民币本金"
        case .transfer: "转出 BTC 对应的人民币本金"
        case .fee: "费用对应的人民币本金"
        case .adjustUSDT: entry.receivedUSDT > 0 ? "保留的人民币本金" : "核销的人民币本金 / 调整损失"
        }
    }
}

struct RulesView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("账目计算规则").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rule("按真实现金本金记账", "这里追踪实际投入人民币、实际收回人民币，以及尚由 BTC 和 USDT 承接的本金。它是个人现金本金账本，不是税务核算，也不会按交易时的市场价重置本金。")
                    rule("投入与回款", "人民币购入 USDT、直接购入 BTC，以及额外支付的人民币手续费，增加累计投入。实际兑换并收到人民币，增加累计回款。使用已有 USDT 买 BTC，不会再次增加人民币投入。")
                    rule("USDT 的本金", "USDT 余额与人民币本金独立记录。每 USDT 平均本金 = 剩余人民币本金 ÷ USDT 余额，它不是 USDT 当前市值。使用 USDT 时，按使用前的平均本金分摊。")
                    rule("修改 USDT 余额", "余额有出入时，可录入实际余额并保留一条调整记录。只要调整后余额大于零，原人民币本金全部保留；余额清零时，原本金计入调整损失。修改更早的历史记录后，目标余额保持不变，调整前余额与差额会重新计算。调整不会改动原有买卖或手续费记录，也不会改变人民币投入、回款和 BTC 持仓。")
                    rule("BTC 与 USDT 互换", "USDT 买入 BTC，把支出 USDT 对应的原始人民币本金转入 BTC；BTC 卖回 USDT，把卖出 BTC 对应的原始本金转入 USDT。额外人民币手续费一并计入承接的本金。这些互换不确认已兑人民币盈亏。")
                    rule("人民币回款与损失", "卖出 BTC 或 USDT 收到人民币时，按卖出前的平均本金分摊本次移出本金。已兑人民币盈亏 = 实际回款 − 对应本金，并包含直接消费 BTC、费用耗尽 BTC 或 USDT、手动清零 USDT 的剩余本金损失，以及无 BTC 持仓时独立支付的人民币费用。BTC 换回 USDT 本身不确认盈亏。人民币填写扣除手续费后的实际到账，避免重复扣费。")
                    rule("转账与手续费", "BTC 转账手续费 = 实际转出总量 − 实际到账；到账部分只是移动账户，转账不增加投入。BTC 和 USDT 费用按本笔交易或扣款前的人民币成本自动折算，也可选择手动记录历史价格。自动折算会随之前的账目修改重新计算，不随实时行情变化；手动记录的价格会保留。累计手续费保留原发生总额；余额调整不会把返还扣减为净手续费。")
                    rule("BTC 持仓的浮动盈亏", "当前 BTC 市值 = BTC 数量 × 最新参考价格。持仓浮动盈亏 = BTC 市值 − BTC 持仓本金；浮动收益率 = 浮动盈亏 ÷ BTC 持仓本金。它与已经兑现的人民币盈亏分开展示。手续费占比 = 累计手续费人民币等值 ÷ 累计人民币投入；没有分母时显示 —。")
                    rule("每次修改都重新计算", "记录按日期时间、同时间录入顺序重算。编辑、删除或导入若会导致任一时点 BTC 账户或 USDT 余额不足，就不保存。BTC 精确到 1 satoshi，USDT 与人民币采用十进制数。原有人民币直接买卖 BTC 的记录仍可查看和编辑。")
                    rule("本地数据与备份", "账本仅保存在此 Mac 的 Application Support/Bitcoin Ledger 中。每次保存保留上一版；JSON 是可完整恢复的备份，CSV 供查看交易明细。导出的备份是明文，请存放在你信任的位置。")
                    rule("参考价格", "BTC 人民币参考行情来自 Blockchain.com；显示成功获取时间，该 API 不提供成交时间。网络失败继续显示缓存。参考行情只用于 BTC 市值和浮动盈亏，不改变任何原始本金。")
                }.padding(.trailing, 8)
            }
            HStack { Spacer(); Button("好") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 650, height: 670)
    }
    private func rule(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}
