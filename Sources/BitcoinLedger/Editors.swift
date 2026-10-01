import SwiftUI
import LedgerCore

struct EntryEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let kind: EntryKind
    let existing: LedgerEntry?
    @State private var date = Date()
    @State private var from: UUID?
    @State private var to: UUID?
    @State private var cny = ""
    @State private var btc = ""
    @State private var received = ""
    @State private var fee = ""
    @State private var feeCurrency: FeeCurrency = .cny
    @State private var feePrice = ""
    @State private var category: FeeCategory = .trading
    @State private var note = ""
    @State private var error: String?
    var transferFee: Int64? {
        guard let outgoing = try? Amounts.satoshis(btc), let incoming = try? Amounts.satoshis(received), outgoing >= incoming else { return nil }
        return outgoing - incoming
    }
    var feeSats: Int64 { kind == .transfer ? (transferFee ?? 0) : ((try? Amounts.satoshis(fee.isEmpty ? "0" : fee)) ?? 0) }
    var needsFeePrice: Bool { (kind == .transfer || feeCurrency == .btc) && feeSats > 0 }
    var automaticFeePrice: Decimal? {
        guard let amount = try? Amounts.decimal(cny), let quantity = try? Amounts.satoshis(btc), quantity > 0, amount > 0 else { return nil }
        if kind == .buy { return amount / Amounts.btc(quantity + feeSats) }
        if kind == .sell { return amount / Amounts.btc(quantity) }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(existing == nil ? kind.title : "编辑\(kind.title)").font(.title2.weight(.semibold)); Spacer() }.padding(24)
            Form {
                Section {
                    DatePicker("日期时间", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    if kind != .buy {
                        accountPicker(kind == .transfer ? "From · 转出账户" : "账户", selection: $from)
                    }
                    if kind == .buy || kind == .transfer {
                        accountPicker(kind == .transfer ? "To · 到账账户" : "存入账户", selection: $to)
                    }
                }
                Section {
                    if kind == .buy {
                        TextField("购币金额 ¥（不含人民币手续费）", text: $cny)
                        TextField("实际获得 BTC（已扣 BTC 手续费）", text: $btc)
                    } else if kind == .sell {
                        TextField("卖出 / 花费 BTC（不含额外 BTC 手续费）", text: $btc)
                        TextField("实际到账人民币 ¥（已扣人民币手续费）", text: $cny)
                        Text("直接花费 BTC 时，到账人民币填 0。该笔成本计入已实现损益。").font(.caption).foregroundStyle(.secondary)
                    } else if kind == .transfer {
                        TextField("转出 BTC（账户实际扣除总量）", text: $btc)
                        TextField("实际到账 BTC", text: $received)
                        LabeledContent("自动计算手续费", value: transferFee.map { "\(Display.btc($0)) BTC" } ?? "—")
                        Text("到账部分只是移动位置；总持仓仅减少手续费。不能转入同一账户。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("手续费") {
                    if kind != .transfer {
                        Picker("手续费币种", selection: $feeCurrency) {
                            Text("人民币 CNY").tag(FeeCurrency.cny)
                            Text("Bitcoin BTC").tag(FeeCurrency.btc)
                        }.pickerStyle(.segmented)
                        TextField(feeCurrency == .cny ? "手续费 ¥" : "手续费 BTC", text: $fee)
                    }
                    if needsFeePrice {
                        TextField("发生时 BTC 人民币价格 ¥", text: $feePrice)
                        if let automatic = automaticFeePrice {
                            Text("留空按本笔成交价计算：\(Display.money(automatic)) / BTC；可填写实际发生时价格。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("请填写费用发生时的价格，用于保留历史价值。不会自动套用今天的行情。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if kind == .fee || kind == .transfer {
                        Picker("费用类别", selection: $category) {
                            ForEach(FeeCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                }
                Section { TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(2...4) }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12).textSelection(.enabled) }
            HStack {
                Text("BTC 精确到 1 satoshi · 人民币最多 2 位小数").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(20)
        }.frame(width: 650, height: 720)
        .onAppear { load() }
    }
    private func accountPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择账户").tag(nil as UUID?)
            ForEach(store.document.accounts.filter { !$0.isArchived || $0.id == selection.wrappedValue }) { account in Text("\(account.name) · \(account.isArchived ? "已删除" : account.kind.title)").tag(Optional(account.id)) }
        }
    }
    private func load() {
        guard let e = existing else {
            from = store.accounts.first?.id; to = kind == .transfer ? store.accounts.dropFirst().first?.id : store.accounts.first?.id
            feeCurrency = kind == .transfer ? .btc : .cny
            category = kind == .fee ? .other : kind == .transfer ? .network : .trading
            return
        }
        date = e.date; from = e.fromAccountID; to = e.toAccountID
        cny = Display.decimal(e.amountCNY); btc = Display.btc(e.amountSats); received = Display.btc(e.receivedSats)
        feeCurrency = e.feeCurrency; fee = e.feeCurrency == .btc ? Display.btc(e.feeSats) : Display.decimal(e.feeCNY)
        feePrice = e.feePriceCNY > 0 ? Display.decimal(e.feePriceCNY) : ""; category = e.feeCategory; note = e.note
    }
    private func save() {
        do {
            let amountSats = kind == .fee ? 0 : try Amounts.satoshis(btc)
            let receivedSats = kind == .transfer ? try Amounts.satoshis(received) : 0
            let amountCNY = kind == .buy || kind == .sell ? try Amounts.decimal(cny) : Decimal.zero
            let currency: FeeCurrency = kind == .transfer ? .btc : feeCurrency
            let feeBTC: Int64
            if kind == .transfer {
                guard amountSats >= receivedSats else { throw UIError.text("到账 BTC 不能大于转出 BTC。") }
                feeBTC = amountSats - receivedSats
            } else { feeBTC = currency == .btc ? try Amounts.satoshis(fee.isEmpty ? "0" : fee) : 0 }
            let feeCNY = currency == .cny ? try Amounts.decimal(fee.isEmpty ? "0" : fee) : Decimal.zero
            var price = Decimal.zero
            if feeBTC > 0 {
                if !feePrice.trimmingCharacters(in: .whitespaces).isEmpty { price = try Amounts.decimal(feePrice, maxPlaces: 8) }
                else if let automatic = automaticFeePrice { price = Amounts.rounded(automatic, scale: 8) }
                else { throw UIError.text("请填写 BTC 手续费发生时的人民币价格。") }
            }
            let nextSequence = (store.document.entries.map(\.sequence).max() ?? 0).addingReportingOverflow(1)
            guard existing != nil || !nextSequence.overflow else { throw UIError.text("记录顺序超过支持范围。") }
            let e = LedgerEntry(id: existing?.id ?? UUID(), date: date,
                                sequence: existing?.sequence ?? nextSequence.partialValue,
                                kind: kind, fromAccountID: kind == .buy ? nil : from,
                                toAccountID: kind == .buy || kind == .transfer ? to : nil,
                                amountSats: amountSats, receivedSats: receivedSats, amountCNY: amountCNY,
                                feeCurrency: currency, feeSats: feeBTC, feeCNY: feeCNY, feePriceCNY: price,
                                feeCategory: category, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            try store.saveEntry(e)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct AccountEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let existing: Account?
    @State private var name = ""
    @State private var kind: AccountKind = .exchange
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing == nil ? "添加账户" : "重命名账户").font(.title2.weight(.semibold))
            Form {
                TextField("账户名称", text: $name)
                Picker("账户类型", selection: $kind) { ForEach(AccountKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .disabled(existing != nil)
            }
            Text("只记录名称和余额，不需要地址、私钥、助记词或交易所权限。").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") {
                do {
                    try store.saveAccount(Account(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind))
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 470).onAppear { if let existing { name = existing.name; kind = existing.kind } }
    }
}
