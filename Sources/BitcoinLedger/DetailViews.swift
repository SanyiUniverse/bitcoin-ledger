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
                        DataRow("日期", entry.date.formatted(date: .complete, time: .omitted))
                        if entry.kind == .buy {
                            DataRow("投入人民币", Display.money(entry.amountCNY))
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
                    rule("购买", "每次只记录人民币实际投入、BTC 实际获得和存入账户。累计投入人民币与累计购买 BTC 分别为所有购买记录之和。")
                    rule("转移", "来源账户减去转出 BTC，目标账户加上实际到账 BTC。BTC 损耗 = 转出 − 到账；转移不增加人民币投入。")
                    rule("总持有与综合成本", "总持有 BTC = 累计购买 BTC − 累计损耗 BTC，也等于各账户余额之和。综合成本 = 累计投入人民币 ÷ 总持有 BTC，转移损耗包含在综合成本内。")
                    rule("市值与盈亏", "当前总市值 = 总持有 BTC × 当前 BTC 市价。总盈亏 = 当前总市值 − 累计投入人民币。总盈亏率 = 总盈亏 ÷ 累计投入人民币；没有分母时显示 —。")
                    rule("K 线与历史状态", "市场 K 线叠加综合成本走势及购买、转移标记。鼠标指向历史时，持有量、投入、损耗、成本及盈亏都按截止该时间的记录计算。")
                    rule("修改与本地备份", "记录按日期及同时间录入顺序重算。编辑、删除或导入导致历史账户余额不足时不会保存。BTC 精确到 1 satoshi。账本只保存在此 Mac；JSON 可完整恢复，CSV 供查看历史记录。")
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
