import SwiftUI
import LedgerCore

struct EntryEditor: View {
    @EnvironmentObject private var store: AppStore
    let kind: EntryKind
    let existing: LedgerEntry?
    let onDismiss: () -> Void
    @FocusState private var amountFocused: Bool
    @State private var entryID = UUID()
    @State private var date = Date()
    @State private var from: UUID?
    @State private var to: UUID?
    @State private var cny = ""
    @State private var btc = ""
    @State private var received = ""
    @State private var note = ""
    @State private var error: String?

    private var transferLoss: Int64? {
        guard let outgoing = try? Amounts.satoshis(btc), let incoming = try? Amounts.satoshis(received), outgoing >= incoming else { return nil }
        return outgoing - incoming
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: existing == nil ? kind.title : "编辑\(kind.title)", onClose: onDismiss)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Divider()
            Form {
                Section {
                    DatePicker("日期", selection: $date, in: ...Date(), displayedComponents: [.date])
                        .accessibilityIdentifier("entry.date")
                    if kind == .buy {
                        TextField("本次投入人民币 ¥", text: $cny).focused($amountFocused)
                            .accessibilityIdentifier("entry.cny")
                        TextField("本次实际获得 BTC", text: $btc)
                            .accessibilityIdentifier("entry.btc")
                        accountPicker("BTC 进入账户", selection: $to)
                            .accessibilityIdentifier("entry.to")
                    } else {
                        accountPicker("来源账户", selection: $from)
                            .accessibilityIdentifier("entry.from")
                        accountPicker("目标账户", selection: $to)
                            .accessibilityIdentifier("entry.to")
                        TextField("转出 BTC", text: $btc).focused($amountFocused)
                            .accessibilityIdentifier("entry.btc")
                        TextField("实际到账 BTC", text: $received)
                            .accessibilityIdentifier("entry.received")
                        LabeledContent("BTC 损耗", value: transferLoss.map { "\(Display.btc($0)) BTC" } ?? "—")
                        TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(2...3)
                            .accessibilityIdentifier("entry.note")
                    }
                }
                Section {
                    Text("BTC 最多 8 位小数 · 人民币最多 2 位").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("取消", action: onDismiss).accessibilityIdentifier("panel.cancel")
                Button("保存记录") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!store.canEdit).accessibilityIdentifier("panel.save")
            }.controlSize(.large).padding(.horizontal, 20).padding(.vertical, 14)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("无法保存记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { load() }
        .task { await Task.yield(); amountFocused = true }
    }

    private func accountPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择账户").tag(nil as UUID?)
            ForEach(store.accounts) { account in Text(account.name).tag(Optional(account.id)) }
        }
    }
    private func load() {
        guard let entry = existing else {
            let exchange = store.accounts.first { $0.name == "欧易" } ?? store.accounts.first
            from = exchange?.id
            to = kind == .transfer
                ? (store.accounts.first { $0.name == "自有钱包" && $0.id != exchange?.id }
                   ?? store.accounts.first { $0.id != exchange?.id })?.id
                : exchange?.id
            return
        }
        entryID = entry.id; date = entry.date; from = entry.fromAccountID; to = entry.toAccountID
        cny = Display.decimal(entry.amountCNY)
        btc = Display.btc(kind == .buy ? entry.receivedSats : entry.amountSats)
        received = Display.btc(entry.receivedSats); note = entry.note
    }
    private func makeEntry() throws -> LedgerEntry {
        let amount = try Amounts.satoshis(btc)
        let actual = kind == .buy ? amount : try Amounts.satoshis(received)
        let investment = kind == .buy ? try Amounts.decimal(cny) : Decimal.zero
        if kind == .transfer, actual > amount { throw UIError.text("到账 BTC 不能大于转出 BTC。") }
        let next = (store.document.entries.map(\.sequence).max() ?? 0).addingReportingOverflow(1)
        guard existing != nil || !next.overflow else { throw UIError.text("记录顺序超过支持范围。") }
        return LedgerEntry(id: entryID, date: date, sequence: existing?.sequence ?? next.partialValue,
                           kind: kind, fromAccountID: kind == .transfer ? from : nil, toAccountID: to,
                           amountSats: amount, receivedSats: actual, amountCNY: investment,
                           note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func save() {
        do { try store.saveEntry(makeEntry()); onDismiss() }
        catch { self.error = error.localizedDescription }
    }
}
