import SwiftUI
import LedgerCore

struct EntryDetail: View {
    @EnvironmentObject private var store: AppStore
    let entry: LedgerEntry; let onEdit: () -> Void; let onDismiss: () -> Void
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: entry.kind.title, onClose: onDismiss)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 14) {
                        DataRow("日期与时间", Display.dateTime(entry.date))
                        if entry.kind == .buy {
                            DataRow("投入美元", Display.money(entry.amountUSD))
                            DataRow("原始人民币投入", Display.cny(entry.amountCNY))
                            DataRow("实际获得 BTC", "\(Display.btc(entry.receivedSats)) BTC")
                            DataRow("进入账户", store.accountName(entry.toAccountID))
                        } else {
                            DataRow("来源账户", store.accountName(entry.fromAccountID))
                            DataRow("目标账户", store.accountName(entry.toAccountID))
                            DataRow("转出 BTC", "\(Display.btc(entry.amountSats)) BTC")
                            DataRow("实际到账 BTC", "\(Display.btc(entry.receivedSats)) BTC")
                            DataRow("BTC 损耗", "\(Display.btc(entry.lossSats)) BTC")
                        }
                    }
                    if !entry.note.isEmpty {
                        Text(entry.note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack {
                Button("删除记录", role: .destructive) { confirmDelete = true }
                Spacer()
                Button("关闭", action: onDismiss)
                Button("编辑", action: onEdit).buttonStyle(.borderedProminent)
            }.controlSize(.large).padding(20).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("删除这条记录？所有余额和成本将重新计算。", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                do { try store.deleteEntry(entry); onDismiss() } catch { self.error = error.localizedDescription }
            }
        }
        .alert("未能删除记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct RulesView: View {
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "账目计算规则", onClose: onDismiss)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rule("购买", "输入人民币实际投入、BTC 实际获得和存入账户。保存时按购买时间可用的历史日参考汇率换算并固定美元投入；人民币原值保留。汇率不可可靠取得时保留草稿，不保存新记录。")
                    rule("转移", "来源账户减去转出 BTC，目标账户加上实际到账 BTC。BTC 损耗 = 转出 − 到账；转移不增加投入。")
                    rule("总持有与综合成本", "总持有 BTC = 累计购买 BTC − 累计损耗 BTC，也等于各账户余额之和。综合成本 = 累计投入美元 ÷ 总持有 BTC，转移损耗包含在综合成本内。")
                    rule("市值与盈亏", "行情、投入、综合成本、市值及盈亏统一显示美元。当前总市值 = 总持有 BTC × 当前 BTC 市价；总盈亏 = 当前总市值 − 累计投入美元；总盈亏率 = 总盈亏 ÷ 累计投入美元。缺少可靠换算或分母时显示 —。")
                    rule("K 线与历史状态", "市场 K 线叠加综合成本走势及购买、转移标记。鼠标指向历史时，持有量、投入、损耗、成本及盈亏都按截止该时间的记录计算。")
                    rule("每日盈亏", "从第一笔购买当天开始，按该笔购买的北京时间时分秒每天保留一条记录。使用当时持仓、当时本金与结算前最后已结束的一分钟收盘参考价，不使用未来一分钟；缺失日期留空。本次结算计入购买记账时，仅成本数字按投入变动使用红绿颜色，转移不触发。曲线显示相对本金的累计盈亏，未扣额外卖出费用。更正旧交易后历史金额同步重算；首笔购买时间改变后重选结算时刻并补齐对应行情。当前估算每分钟刷新。")
                    rule("修改与本地备份", "时间输入和显示精确到分钟，采用上海时区；历史时间保留原精度。修改购买时间或人民币投入会重新取得历史汇率；只修改 BTC 或账户时保留原美元投入。记录按时间及同时间录入顺序重算；历史账户余额不足时不会保存。BTC 精确到 1 satoshi。账本仅保存在此 Mac；JSON 可完整恢复，CSV 供查看历史记录。")
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }.frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack { Spacer(); Button("好", action: onDismiss).keyboardShortcut(.defaultAction) }
                .controlSize(.large).padding(20).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func rule(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}
