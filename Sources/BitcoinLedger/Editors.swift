import SwiftUI
import LedgerCore

struct EntryEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let kind: EntryKind
    let existing: LedgerEntry?
    @State private var entryID = UUID()
    @State private var date = Date()
    @State private var from: UUID?
    @State private var to: UUID?
    @State private var cny = ""
    @State private var usdt = ""
    @State private var btc = ""
    @State private var received = ""
    @State private var settlement: SettlementCurrency = .usdt
    @State private var fee = ""
    @State private var feeCurrency: FeeCurrency = .btc
    @State private var feeSource: FeeValuationSource = .costBasis
    @State private var feePrice = ""
    @State private var category: FeeCategory = .trading
    @State private var note = ""
    @State private var error: String?

    private var isBTCTrade: Bool { kind == .buy || kind == .sell }
    private var isUSDTExchange: Bool { kind == .buyUSDT || kind == .sellUSDT }
    private var transferFee: Int64? {
        guard let outgoing = try? Amounts.satoshis(btc), let incoming = try? Amounts.satoshis(received), outgoing >= incoming else { return nil }
        return outgoing - incoming
    }
    private var allowedFees: [FeeCurrency] {
        if isUSDTExchange { return [.cny, .usdt] }
        if kind == .transfer { return [.btc, .cny] }
        if isBTCTrade && settlement == .cny { return [.cny, .btc] }
        return [.btc, .usdt, .cny]
    }
    private var btcFeeIsPositive: Bool {
        feeCurrency == .btc && (kind == .transfer ? (transferFee ?? 0) > 0 : ((try? Amounts.satoshis(fee)) ?? 0) > 0)
    }
    private var automaticLegacyPrice: Decimal? {
        guard isBTCTrade, settlement == .cny,
              let money = try? Amounts.decimal(cny), money > 0,
              let sats = try? Amounts.satoshis(btc), sats > 0 else { return nil }
        let feeSats = feeCurrency == .btc ? ((try? Amounts.satoshis(fee.isEmpty ? "0" : fee)) ?? 0) : 0
        return money / Amounts.btc(kind == .buy ? sats + feeSats : sats)
    }
    private var preview: (entry: LedgerEntry, valuation: EntryValuation)? {
        guard let entry = try? makeEntry() else { return nil }
        var entries = store.document.entries.filter { $0.id != entry.id }
        entries.append(entry)
        guard let snapshot = try? LedgerEngine.calculate(accounts: store.document.accounts, entries: entries),
              let valuation = snapshot.entryValuations[entry.id] else { return nil }
        return (entry, valuation)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(existing == nil ? kind.title : "编辑\(kind.title)").font(.title2.weight(.semibold)); Spacer() }.padding(24)
            Form {
                Section {
                    DatePicker("日期时间", selection: $date, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    if isBTCTrade {
                        Picker(kind == .buy ? "使用什么买入" : "收到什么", selection: $settlement) {
                            Text("USDT").tag(SettlementCurrency.usdt)
                            Text("人民币 CNY").tag(SettlementCurrency.cny)
                        }.pickerStyle(.segmented)
                    }
                    if kind == .sell || kind == .transfer || (kind == .fee && feeCurrency == .btc) {
                        accountPicker(kind == .transfer ? "From · 转出账户" : "BTC 账户", selection: $from)
                    }
                    if kind == .buy || kind == .transfer {
                        accountPicker(kind == .transfer ? "To · 到账账户" : "BTC 存入账户", selection: $to)
                    }
                }
                Section {
                    switch kind {
                    case .buyUSDT:
                        TextField("实际支付人民币 ¥（含人民币手续费）", text: $cny)
                        TextField("实际到账 USDT（已扣 USDT 手续费）", text: $usdt)
                        Text("按实际支出建立人民币成本，USDT 统一记在一个余额中。").font(.caption).foregroundStyle(.secondary)
                    case .sellUSDT:
                        TextField("扣除 USDT 总量（含 USDT 手续费）", text: $usdt)
                        TextField("实际到账人民币 ¥（已扣人民币手续费）", text: $cny)
                        Text("本次净回款减去扣除 USDT 对应的本金，就是人民币兑现盈亏。").font(.caption).foregroundStyle(.secondary)
                    case .buy:
                        if settlement == .usdt {
                            TextField("扣除 USDT 总量（含 USDT 手续费）", text: $usdt)
                            Text("人民币成本按当时 USDT 余额的平均成本自动分摊，不重复增加投入。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("购币金额 ¥（不含人民币手续费）", text: $cny)
                        }
                        TextField("实际获得 BTC（已扣 BTC 手续费）", text: $btc)
                    case .sell:
                        TextField("卖出 / 花费 BTC（不含额外 BTC 手续费）", text: $btc)
                        if settlement == .usdt {
                            TextField("实际到账 USDT（已扣 USDT 手续费）", text: $usdt)
                            Text("原人民币本金转入到账 USDT，此时不确认人民币兑现收益。").font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("实际到账人民币 ¥（已扣人民币手续费）", text: $cny)
                            Text("直接花费 BTC 时，到账人民币填 0；该笔本金计入已实现损失。").font(.caption).foregroundStyle(.secondary)
                        }
                    case .transfer:
                        TextField("转出 BTC（账户实际扣除总量）", text: $btc)
                        TextField("实际到账 BTC", text: $received)
                        LabeledContent("BTC 差额 / 手续费", value: transferFee.map { "\(Display.btc($0)) BTC" } ?? "—")
                        Text("到账部分只移动位置；BTC 手续费减少数量，不减少原本金。额外人民币手续费计入成本。").font(.caption).foregroundStyle(.secondary)
                    case .fee:
                        Text("费用按原币记录。BTC / USDT 费用由同币种剩余余额承担成本；全部耗尽时确认成本损失。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("手续费") {
                    Picker("手续费币种", selection: $feeCurrency) {
                        ForEach(allowedFees, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if kind != .transfer || feeCurrency != .btc {
                        TextField("手续费 \(feeCurrency.title)", text: $fee)
                    }
                    if btcFeeIsPositive {
                        Picker("人民币折算依据", selection: $feeSource) {
                            Text("自动按人民币成本").tag(FeeValuationSource.costBasis)
                            Text("手工历史行情").tag(FeeValuationSource.manualPrice)
                        }
                        if feeSource == .manualPrice {
                            TextField("发生时 BTC 人民币价格 ¥", text: $feePrice)
                            if let automaticLegacyPrice {
                                Text("留空按本笔人民币成交价：\(Display.money(automaticLegacyPrice)) / BTC。").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("保留这次输入的历史价格，不会用今天行情替换。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if feeCurrency == .usdt {
                        Text("人民币等值按本次成本链自动计算；修改早期记录会重新分摊。").font(.caption).foregroundStyle(.secondary)
                    }
                    if isBTCTrade && settlement == .usdt && feeCurrency == .cny {
                        Text("人民币手续费视为额外实际支出，加入本次获得资产的成本。").font(.caption).foregroundStyle(.secondary)
                    }
                    if kind == .fee || kind == .transfer {
                        Picker("费用类别", selection: $category) {
                            ForEach(FeeCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                }
                if let preview {
                    Section("自动计算") {
                        LabeledContent(kind == .sell || kind == .sellUSDT ? "本次扣除资产的人民币成本" : "本次人民币成本", value: Display.money(preview.valuation.costCNY))
                        LabeledContent("手续费人民币等值", value: Display.money(preview.valuation.feeCNYEquivalent))
                        if kind == .sellUSDT || (kind == .sell && settlement == .cny) {
                            LabeledContent("本次兑现盈亏", value: Display.money(preview.entry.amountCNY - preview.valuation.costCNY))
                        }
                    }
                }
                Section { TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(2...4) }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 12).textSelection(.enabled) }
            HStack {
                Text("BTC / USDT 最多 8 位小数 · 人民币最多 2 位").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.padding(20)
        }.frame(width: 680, height: 760)
        .onAppear { load() }
        .onChange(of: settlement) { _, _ in
            if !allowedFees.contains(feeCurrency) { feeCurrency = .btc; fee = "" }
        }
    }
    private func accountPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择账户").tag(nil as UUID?)
            ForEach(store.document.accounts.filter { !$0.isArchived || $0.id == selection.wrappedValue }) { account in
                Text("\(account.name) · \(account.isArchived ? "已删除" : account.kind.title)").tag(Optional(account.id))
            }
        }
    }
    private func load() {
        guard let e = existing else {
            from = store.accounts.first?.id
            to = kind == .transfer ? store.accounts.dropFirst().first?.id : store.accounts.first?.id
            feeCurrency = isUSDTExchange ? .cny : .btc
            category = kind == .fee ? .other : kind == .transfer ? .network : .trading
            return
        }
        entryID = e.id; date = e.date; from = e.fromAccountID; to = e.toAccountID
        settlement = e.settlementCurrency
        cny = Display.decimal(e.amountCNY); btc = Display.btc(e.amountSats); received = Display.btc(e.receivedSats)
        usdt = Display.decimal(kind == .buyUSDT || kind == .sell ? e.receivedUSDT : e.amountUSDT)
        feeCurrency = e.feeCurrency
        switch e.feeCurrency {
        case .btc: fee = Display.btc(e.feeSats)
        case .cny: fee = Display.decimal(e.feeCNY)
        case .usdt: fee = Display.decimal(e.feeUSDT)
        }
        feeSource = e.feeValuationSource
        feePrice = e.feePriceCNY > 0 ? Display.decimal(e.feePriceCNY) : ""
        category = e.feeCategory; note = e.note
    }
    private func makeEntry() throws -> LedgerEntry {
        let amountSats = isBTCTrade || kind == .transfer ? try Amounts.satoshis(btc) : 0
        let receivedSats = kind == .transfer ? try Amounts.satoshis(received) : 0
        let amountCNY = isUSDTExchange || (isBTCTrade && settlement == .cny) ? try Amounts.decimal(cny) : Decimal.zero
        let usdtQuantity = isUSDTExchange || (isBTCTrade && settlement == .usdt) ? try Amounts.decimal(usdt, maxPlaces: 8) : Decimal.zero
        let feeBTC: Int64
        if kind == .transfer {
            guard amountSats >= receivedSats else { throw UIError.text("到账 BTC 不能大于转出 BTC。") }
            feeBTC = amountSats - receivedSats
            if feeCurrency == .cny && feeBTC != 0 { throw UIError.text("有 BTC 差额时请选择 BTC 手续费；额外人民币费用可单独记录。") }
        } else { feeBTC = feeCurrency == .btc ? try Amounts.satoshis(fee.isEmpty ? "0" : fee) : 0 }
        let feeCNY = feeCurrency == .cny ? try Amounts.decimal(fee.isEmpty ? "0" : fee) : Decimal.zero
        let feeUSDT = feeCurrency == .usdt ? try Amounts.decimal(fee.isEmpty ? "0" : fee, maxPlaces: 8) : Decimal.zero
        let source: FeeValuationSource = feeCurrency == .usdt ? .costBasis : feeCurrency == .btc ? feeSource : .manualPrice
        var price = Decimal.zero
        if feeBTC > 0 && source == .manualPrice {
            if !feePrice.trimmingCharacters(in: .whitespaces).isEmpty { price = try Amounts.decimal(feePrice, maxPlaces: 8) }
            else if let automaticLegacyPrice { price = Amounts.rounded(automaticLegacyPrice, scale: 8) }
            else { throw UIError.text("请填写 BTC 手续费发生时的人民币价格，或选择自动按人民币成本。") }
        }
        let next = (store.document.entries.map(\.sequence).max() ?? 0).addingReportingOverflow(1)
        guard existing != nil || !next.overflow else { throw UIError.text("记录顺序超过支持范围。") }
        return LedgerEntry(id: entryID, date: date, sequence: existing?.sequence ?? next.partialValue,
                           kind: kind, fromAccountID: kind == .sell || kind == .transfer || (kind == .fee && feeCurrency == .btc) ? from : (kind == .fee && feeCurrency == .cny ? existing?.fromAccountID : nil),
                           toAccountID: kind == .buy || kind == .transfer ? to : nil,
                           amountSats: amountSats, receivedSats: receivedSats, amountCNY: amountCNY,
                           feeCurrency: feeCurrency, feeSats: feeBTC, feeCNY: feeCNY, feePriceCNY: price,
                           feeCategory: category, note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                           settlementCurrency: isBTCTrade ? settlement : .cny,
                           amountUSDT: kind == .sellUSDT || (kind == .buy && settlement == .usdt) ? usdtQuantity : 0,
                           receivedUSDT: kind == .buyUSDT || (kind == .sell && settlement == .usdt) ? usdtQuantity : 0,
                           feeUSDT: feeUSDT, feeValuationSource: source)
    }
    private func save() {
        do { try store.saveEntry(makeEntry()); dismiss() }
        catch { self.error = error.localizedDescription }
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
