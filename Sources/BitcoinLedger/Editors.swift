import SwiftUI
import AppKit
import LedgerCore

/// Native minute-level entry preserves the Date binding's existing precision.
struct LedgerDateTimePicker: NSViewRepresentable {
    @Binding var date: Date
    var isEnabled = true

    static func minuteDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.datePickerMode = .single
        picker.locale = Locale(identifier: "zh_CN")
        picker.timeZone = TimeZone(identifier: "Asia/Shanghai")
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setAccessibilityIdentifier("entry.date")
        return picker
    }
    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if picker.dateValue != date { picker.dateValue = date }
        picker.isEnabled = isEnabled
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: LedgerDateTimePicker
        init(_ parent: LedgerDateTimePicker) { self.parent = parent }
        @objc func changed(_ picker: NSDatePicker) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            // Reconfirming the visible minute must not erase hidden historical precision.
            guard calendar.dateInterval(of: .minute, for: picker.dateValue)?.start
                    != calendar.dateInterval(of: .minute, for: parent.date)?.start else { return }
            parent.date = LedgerDateTimePicker.minuteDate(picker.dateValue)
        }
    }
}

struct EntryEditor: View {
    @EnvironmentObject private var store: AppStore
    let kind: EntryKind
    let existing: LedgerEntry?
    @Binding var saveTask: Task<Void, Never>?
    let onDismiss: () -> Void
    @FocusState private var amountFocused: Bool
    @State private var entryID = UUID()
    @State private var date = LedgerDateTimePicker.minuteDate(Date())
    @State private var from: UUID?
    @State private var to: UUID?
    @State private var cny = ""
    @State private var btc = ""
    @State private var received = ""
    @State private var note = ""
    @State private var error: String?
    @State private var isSaving = false

    private var transferLoss: Int64? {
        guard let outgoing = try? Amounts.satoshis(btc), let incoming = try? Amounts.satoshis(received), outgoing >= incoming else { return nil }
        return outgoing - incoming
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: existing == nil ? kind.title : "编辑\(kind.title)", onClose: dismiss)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Divider()
            Form {
                Section {
                    LabeledContent("日期与时间") {
                        LedgerDateTimePicker(date: $date, isEnabled: !isSaving).frame(minWidth: 230, minHeight: 24)
                    }
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
                    Text(kind == .buy ? "人民币最多 2 位 · 按购买时间可用的日参考汇率固定美元投入" : "BTC 最多 8 位小数")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(isSaving).frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                if isSaving { ProgressView().controlSize(.small).accessibilityLabel("正在保存记录") }
                Button("取消", action: dismiss).accessibilityIdentifier("panel.cancel")
                Button(isSaving ? "正在保存…" : "保存记录") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!store.canEdit || isSaving).accessibilityIdentifier("panel.save")
            }.controlSize(.large).padding(.horizontal, 20).padding(.vertical, 14)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("无法保存记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { load() }
        .onDisappear { saveTask?.cancel() }
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
        guard !isSaving else { return }
        do {
            let draft = try makeEntry()
            isSaving = true
            saveTask = Task {
                defer { isSaving = false; saveTask = nil }
                do {
                    try await store.saveEntryResolvingCurrency(draft)
                    try Task.checkCancellation()
                    onDismiss()
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
        catch { self.error = error.localizedDescription }
    }
    private func dismiss() {
        saveTask?.cancel()
        onDismiss()
    }
}
