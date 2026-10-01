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
                        Text("所有账户").font(.title2.weight(.semibold))
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
                                            Text(account.name).font(.headline)
                                            Spacer()
                                            Text("\(Display.btc(store.snapshot?.balances[account.id] ?? 0)) BTC").monospacedDigit()
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
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(entry.kind.title, systemImage: entry.kind.icon).font(.title2.weight(.semibold))
            VStack(spacing: 14) {
                DataRow("日期时间", entry.date.formatted(date: .complete, time: .standard))
                if entry.kind != .buy { DataRow("转出账户", store.accountName(entry.fromAccountID)) }
                if entry.kind == .buy || entry.kind == .transfer { DataRow("到账账户", store.accountName(entry.toAccountID)) }
                if entry.kind != .fee { DataRow(entry.kind == .buy ? "实际获得" : "转出 / 卖出", "\(Display.btc(entry.amountSats)) BTC") }
                if entry.kind == .transfer { DataRow("实际到账", "\(Display.btc(entry.receivedSats)) BTC") }
                if entry.kind == .buy || entry.kind == .sell { DataRow(entry.kind == .buy ? "购币金额（不含人民币手续费）" : "实际收到人民币", Display.money(entry.amountCNY)) }
                Divider()
                DataRow(entry.feeCategory.title, Display.fee(entry))
                if entry.feeSats > 0 {
                    DataRow("发生时 BTC / CNY", Display.money(entry.feePriceCNY))
                    DataRow("手续费人民币等值", "¥\(Display.decimal(entry.feeCNYEquivalent))")
                }
            }
            if !entry.note.isEmpty { Text(entry.note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("删除记录", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("编辑", action: onEdit).buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 610)
        .confirmationDialog("删除这条记录？所有余额和成本将重新计算。", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                do { try store.deleteEntry(entry); dismiss() } catch { self.error = error.localizedDescription }
            }
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
                    rule("按发生时间重算", "所有记录按日期时间和录入顺序重算。编辑或删除后也一样；如果会让任何账户在历史某个时点余额为负，则阻止保存。BTC 使用整数 satoshi，人民币使用十进制数。")
                    rule("买入与累计投入", "买入 BTC 填实际到账净数量；人民币填不含额外人民币手续费的购币金额。累计投入 = 购币金额 + 额外支付的人民币手续费。累计购买 BTC = 实际到账 BTC + 从本次买入扣除的 BTC 手续费。")
                    rule("平均买价与实际成本", "平均买入价格 = 累计购币金额 ÷ 累计购买 BTC，不含人民币手续费。实际成本价 = 剩余持仓总成本 ÷ 当前 BTC，包含已承担的费用损耗。无分母时显示 —。")
                    rule("转账与费用", "转账手续费 = 转出总量 − 实际到账。总 BTC 只减少手续费；转账不增加买入或投入。BTC 费用按发生时价格折算，仅用于费用统计，不再次增加人民币成本。剩余 BTC 承担原成本；全部消耗时将剩余成本计入已实现损失。")
                    rule("卖出与花费", "卖出数量不含额外 BTC 手续费；人民币是已经扣除人民币手续费的实际到账。卖出和额外 BTC 手续费一起按移动加权成本分摊；已实现盈亏 = 净到账人民币 − 分摊成本。花费 BTC 时人民币填 0。")
                    rule("持仓盈亏与费用占比", "当前价值 = 当前 BTC × 最新参考价格。未实现盈亏 = 当前价值 − 剩余持仓成本；收益率 = 未实现盈亏 ÷ 剩余持仓成本。手续费占比 = 累计手续费人民币等值 ÷ 累计人民币投入。")
                    rule("本地数据与备份", "账本仅保存在此 Mac 的 Application Support/Bitcoin Ledger 中。每次保存保留上一版；JSON 是可完整恢复的备份，CSV 供查看交易明细。导出的备份是明文，请存放在你信任的位置。")
                    rule("参考价格", "行情来自 Blockchain.com；显示成功获取时间，该 API 不提供成交时间。网络失败继续使用缓存。BTC 历史手续费价格会随记录保存，后续刷新行情不会改写。")
                }.padding(.trailing, 8)
            }
            HStack { Spacer(); Button("好") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 650, height: 670)
    }
    private func rule(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}
