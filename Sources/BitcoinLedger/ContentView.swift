import SwiftUI
import LedgerCore

enum Page: String, CaseIterable, Identifiable {
    case dashboard = "总览", usdt = "USDT", sales = "卖出记录", history = "历史记录", accounts = "BTC 账户"
    var id: String { rawValue }
    var icon: String { switch self { case .dashboard: "square.grid.2x2"; case .usdt: "arrow.left.arrow.right.circle"; case .sales: "arrow.up.right.circle"; case .history: "clock"; case .accounts: "wallet.bifold" } }
}
struct EntrySheet: Identifiable { let id = UUID(); var kind: EntryKind; var entry: LedgerEntry? }
struct AccountSheet: Identifiable { let id = UUID(); var account: Account? }

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var page: Page? = .dashboard
    @State private var entrySheet: EntrySheet?
    @State private var accountSheet: AccountSheet?
    @State private var selectedEntry: LedgerEntry?
    @State private var showRules = false
    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in Label(page.rawValue, systemImage: page.icon).tag(page) }
                .navigationSplitViewColumnWidth(min: 160, ideal: 185, max: 220)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Bitcoin Ledger", systemImage: "bitcoinsign.circle").font(.headline)
                        Text("仅在此 Mac 保存账本").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }
        } detail: {
            Group {
                if let error = store.startupError {
                    ContentUnavailableView {
                        Label("账本需要恢复", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(error) } actions: { Button("Import Backup…") { store.importJSON() } }
                } else {
                    switch page ?? .dashboard {
                    case .dashboard: DashboardView(onAddAccount: { accountSheet = AccountSheet() }, onAdd: { entrySheet = EntrySheet(kind: $0) })
                    case .usdt: USDTView(onAdd: { entrySheet = EntrySheet(kind: $0) }, onEntry: { selectedEntry = $0 })
                    case .sales: SalesView(onAddAccount: { accountSheet = AccountSheet() }, onAdd: { entrySheet = EntrySheet(kind: $0) }, onEntry: { selectedEntry = $0 })
                    case .history: HistoryView(entries: store.entries, onEntry: { selectedEntry = $0 })
                    case .accounts: AccountsView(onAdd: { accountSheet = AccountSheet() }, onEdit: { accountSheet = AccountSheet(account: $0) }, onEntry: { selectedEntry = $0 })
                    }
                }
            }
            .navigationTitle((page ?? .dashboard).rawValue)
            .toolbar {
                ToolbarItemGroup {
                    Button { showRules = true } label: { Image(systemName: "info.circle") }.help("计算规则")
                    Menu {
                        Button("Export Backup · JSON…") { store.exportJSON() }.disabled(!store.canEdit)
                        Button("导出交易历史 · CSV…") { store.exportCSV() }.disabled(!store.canEdit)
                        Divider()
                        Button("Import Backup…") { store.importJSON() }
                    } label: { Label("备份", systemImage: "square.and.arrow.up") }
                    Menu {
                        ForEach(EntryKind.allCases, id: \.self) { kind in
                            Button { entrySheet = EntrySheet(kind: kind) } label: { Label(kind.title, systemImage: kind.icon) }
                                .disabled(store.accounts.isEmpty && (kind == .buy || kind == .transfer || kind == .sell))
                        }
                    } label: { Label("新增记录", systemImage: "plus") }
                    .disabled(!store.canEdit)
                    .help("新增人民币、USDT 或 BTC 账目")
                }
            }
        }
        .sheet(item: $entrySheet) { item in EntryEditor(kind: item.kind, existing: item.entry).environmentObject(store) }
        .sheet(item: $accountSheet) { item in AccountEditor(existing: item.account).environmentObject(store) }
        .sheet(item: $selectedEntry) { entry in
            EntryDetail(entry: entry, onEdit: {
                selectedEntry = nil
                entrySheet = EntrySheet(kind: entry.kind, entry: entry)
            }).environmentObject(store)
        }
        .sheet(isPresented: $showRules) { RulesView() }
        .alert("Bitcoin Ledger", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("好", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLocations = false
    let onAddAccount: () -> Void
    let onAdd: (EntryKind) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let state = store.snapshot {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("BITCOIN 持仓").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Button { showLocations.toggle() } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Display.btc(state.totalSats)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text("BTC").font(.title3).foregroundStyle(.secondary)
                                Image(systemName: showLocations ? "chevron.up" : "chevron.down").font(.headline).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityLabel("Bitcoin 总持有量 \(Display.btc(state.totalSats)) BTC，\(showLocations ? "收起" : "查看")资产位置")
                        Text(showLocations ? "点击收起资产位置" : "点击 BTC 总量查看资产位置").font(.caption).foregroundStyle(.secondary)
                        if showLocations {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(AccountKind.allCases, id: \.self) { kind in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack {
                                            Label("\(kind.english) / \(kind.title)", systemImage: kind.icon)
                                            Spacer()
                                            Text("\(Display.btc(store.accounts.filter { $0.kind == kind }.reduce(0) { $0 + (state.balances[$1.id] ?? 0) })) BTC").monospacedDigit()
                                        }.font(.headline)
                                        ForEach(store.accounts.filter { $0.kind == kind }) { account in
                                            HStack {
                                                Text(account.name)
                                                Spacer()
                                                Text("\(Display.btc(state.balances[account.id] ?? 0)) BTC").monospacedDigit()
                                            }.padding(.leading, 26)
                                        }
                                        if !store.accounts.contains(where: { $0.kind == kind }) {
                                            Text("还没有\(kind.title)").foregroundStyle(.secondary).padding(.leading, 26)
                                        }
                                    }
                                }
                                if store.accounts.isEmpty { Button("添加 BTC 账户", action: onAddAccount) }
                            }.padding(.vertical, 12)
                            Divider()
                        }
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("当前 BTC 市值").font(.caption).foregroundStyle(.secondary)
                                Text(Display.money(store.quote.map { state.marketValue(price: $0.priceCNY) })).font(.title2).monospacedDigit()
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("1 BTC ≈ \(Display.money(store.quote?.priceCNY))").font(.subheadline).monospacedDigit()
                                if let quote = store.quote {
                                    Text("获取于 \(quote.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · \(quote.source)").font(.caption).foregroundStyle(.secondary)
                                    if Date().timeIntervalSince(quote.fetchedAt) > 900 { Text("缓存价格，等待刷新").font(.caption).foregroundStyle(.orange) }
                                } else { Text("联网后显示参考行情").font(.caption).foregroundStyle(.secondary) }
                            }
                            Button { Task { await store.refreshPrice(force: true) } } label: {
                                Image(systemName: "arrow.clockwise")
                            }.disabled(store.refreshing).help("刷新价格（每分钟最多一次）")
                        }
                        if let error = store.priceError { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(24).background(.background, in: RoundedRectangle(cornerRadius: 16))
                    VStack(spacing: 10) {
                        HStack(spacing: 16) {
                            LedgerActionButton(title: "买入 USDT", detail: "记录实际投入的人民币", icon: "arrow.down.circle") { onAdd(.buyUSDT) }
                            LedgerActionButton(title: "买入 BTC", detail: store.accounts.isEmpty ? "先添加一个 BTC 账户" : "使用 USDT 或人民币购入", icon: "bitcoinsign.circle") {
                                if store.accounts.isEmpty { onAddAccount() } else { onAdd(.buy) }
                            }
                        }
                        HStack(spacing: 12) {
                            Button { if store.accounts.isEmpty { onAddAccount() } else { onAdd(.transfer) } } label: {
                                Label("转账", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity, minHeight: 32)
                            }
                            Button { if store.accounts.isEmpty { onAddAccount() } else { onAdd(.sell) } } label: {
                                Label("卖出 BTC", systemImage: "arrow.up.right").frame(maxWidth: .infinity, minHeight: 32)
                            }
                            Button { onAdd(.fee) } label: {
                                Label("其他手续费", systemImage: "minus.circle").frame(maxWidth: .infinity, minHeight: 32)
                            }
                        }.buttonStyle(.bordered).controlSize(.large)
                    }.disabled(!store.canEdit)
                    HStack(spacing: 16) {
                        MetricCard(title: "BTC 持仓本金", value: Display.money(state.costBasisCNY), detail: "每 BTC 实际成本 \(Display.money(state.actualCostPriceCNY))")
                        MetricCard(title: "持仓浮动盈亏", value: Display.money(store.quote.map { state.unrealizedPnL(price: $0.priceCNY) }), detail: "BTC 市值 − BTC 持仓本金")
                        MetricCard(title: "持仓浮动收益率", value: Display.percent(store.quote.flatMap { state.returnRatio(price: $0.priceCNY) }), detail: "浮动盈亏 ÷ BTC 持仓本金")
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 24) {
                                VStack(spacing: 12) {
                                    DataRow("累计手续费人民币等值", Display.money(state.totalFeeCNY))
                                    DataRow("手续费占累计投入", Display.percent(state.feeRatio))
                                }.frame(maxWidth: .infinity)
                                VStack(spacing: 12) {
                                    DataRow("累计消耗 BTC", "\(Display.btc(state.totalFeeSats)) BTC")
                                    DataRow("累计消耗 USDT", "\(Display.usdt(state.totalFeeUSDT)) USDT")
                                }.frame(maxWidth: .infinity)
                            }
                            Text("费用按本笔交易或扣款前人民币成本折算，也可手动记录历史价格。已计入的额外成本不会重复增加投入。").font(.caption).foregroundStyle(.secondary)
                        }.padding(12)
                    } label: { Text("手续费与损耗").font(.headline) }
                }
            }.padding(28).frame(maxWidth: 1150)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SalesView: View {
    @EnvironmentObject private var store: AppStore
    let onAddAccount: () -> Void
    let onAdd: (EntryKind) -> Void
    let onEntry: (LedgerEntry) -> Void
    private var entries: [LedgerEntry] { store.entries.filter { $0.kind == .sell || $0.kind == .sellUSDT } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let state = store.snapshot {
                    HStack(spacing: 16) {
                        MetricCard(title: "累计人民币回款", value: Display.money(state.returnedCNY), detail: "卖出 BTC 或 USDT 后实际收回的人民币")
                        MetricCard(title: "已兑人民币盈亏", value: Display.money(state.realizedPnLCNY), detail: "人民币回款 − 本金；含消费及费用耗尽损失")
                    }
                    HStack(spacing: 16) {
                        LedgerActionButton(title: "卖出 BTC", detail: store.accounts.isEmpty ? "先添加一个 BTC 账户" : "记录收到的 USDT 或人民币", icon: "arrow.up.right.circle") {
                            if store.accounts.isEmpty { onAddAccount() } else { onAdd(.sell) }
                        }
                        LedgerActionButton(title: "USDT 换回人民币", detail: "记录 USDT 扣款与人民币实收", icon: "yensign.circle") { onAdd(.sellUSDT) }
                    }.disabled(!store.canEdit)
                    Text("BTC 卖回 USDT 时继续保留原人民币本金；换回人民币后才确认该笔兑现盈亏。直接花费 BTC 和费用耗尽余额时，相应本金计入损失。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if entries.isEmpty {
                        ContentUnavailableView("还没有卖出记录", systemImage: "arrow.up.right.circle", description: Text("卖出 BTC 或把 USDT 换回人民币后，记录会显示在这里。"))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("卖出与回款记录").font(.headline)
                            ForEach(entries) { entry in
                                Button { onEntry(entry) } label: { EntryRow(entry: entry) }.buttonStyle(.plain)
                                if entry.id != entries.last?.id { Divider() }
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1150)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct USDTView: View {
    @EnvironmentObject private var store: AppStore
    let onAdd: (EntryKind) -> Void
    let onEntry: (LedgerEntry) -> Void
    private var entries: [LedgerEntry] {
        store.entries.filter { $0.kind == .buyUSDT || $0.kind == .sellUSDT || $0.settlementCurrency == .usdt || $0.feeCurrency == .usdt }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let state = store.snapshot {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("USDT 周转余额").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Display.usdt(state.usdtBalance)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("USDT").font(.title3).foregroundStyle(.secondary)
                        }
                        Text("记录人民币与 BTC 之间的周转资金。").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24).background(.background, in: RoundedRectangle(cornerRadius: 16))
                    HStack(spacing: 16) {
                        LedgerActionButton(title: "买入 USDT", detail: "记录人民币支出与 USDT 到账", icon: "arrow.down.circle") { onAdd(.buyUSDT) }
                        LedgerActionButton(title: "换回人民币", detail: "记录 USDT 扣款与人民币实收", icon: "arrow.up.circle") { onAdd(.sellUSDT) }
                    }.disabled(!store.canEdit)
                    HStack(spacing: 16) {
                        MetricCard(title: "剩余人民币本金", value: Display.money(state.usdtCostBasisCNY), detail: "当前 USDT 承接的原始本金")
                        MetricCard(title: "每 USDT 平均本金", value: Display.money(state.averageUSDTCostCNY), detail: "剩余本金 ÷ USDT 余额")
                    }
                    Text("这里显示账本本金，不是 USDT 当前市值。BTC 卖回 USDT 时保留原始本金，兑换成人民币后才确认已兑盈亏。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if entries.isEmpty {
                        ContentUnavailableView("还没有 USDT 记录", systemImage: "arrow.left.arrow.right.circle", description: Text("从一次人民币买入开始，不需要先创建 BTC 账户。"))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("USDT 相关记录").font(.headline)
                            ForEach(entries) { entry in
                                Button { onEntry(entry) } label: { EntryRow(entry: entry) }.buttonStyle(.plain)
                                if entry.id != entries.last?.id { Divider() }
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1150)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
struct LedgerActionButton: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 24, weight: .medium)).frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).font(.caption).opacity(0.85)
                }
                Spacer(minLength: 4)
                Image(systemName: "plus").font(.headline)
            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(.horizontal, 8)
        }.buttonStyle(.borderedProminent).controlSize(.large)
    }
}
struct MetricCard: View {
    let title: String; let value: String; let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().textSelection(.enabled)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}
struct DataRow: View {
    let title: String; let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View { HStack(alignment: .firstTextBaseline) { Text(title).foregroundStyle(.secondary); Spacer(minLength: 12); Text(value).monospacedDigit().textSelection(.enabled) } }
}
struct EntryRow: View {
    @EnvironmentObject private var store: AppStore
    let entry: LedgerEntry
    private var title: String {
        entry.kind == .sell && entry.settlementCurrency == .cny && entry.amountCNY == 0 ? "花费 BTC" : entry.kind.title
    }
    private var accountLabel: String {
        switch entry.kind {
        case .buy: store.accountName(entry.toAccountID)
        case .sell: store.accountName(entry.fromAccountID)
        case .transfer: "\(store.accountName(entry.fromAccountID)) → \(store.accountName(entry.toAccountID))"
        case .buyUSDT: "人民币 → USDT"
        case .sellUSDT: "USDT → 人民币"
        case .fee:
            entry.feeCurrency == .usdt ? "USDT 周转资金" : entry.fromAccountID == nil ? "人民币费用" : store.accountName(entry.fromAccountID)
        }
    }
    private var quantity: String {
        switch entry.kind {
        case .buy: "+\(Display.btc(entry.amountSats)) BTC"
        case .sell: "−\(Display.btc(entry.amountSats)) BTC"
        case .transfer: "\(Display.btc(entry.amountSats)) BTC"
        case .fee: "−\(Display.fee(entry))"
        case .buyUSDT: "+\(Display.usdt(entry.receivedUSDT)) USDT"
        case .sellUSDT: "−\(Display.usdt(entry.amountUSDT)) USDT"
        }
    }
    private var settlement: String? {
        switch entry.kind {
        case .buy: entry.settlementCurrency == .usdt ? "支出 \(Display.usdt(entry.amountUSDT)) USDT" : "购币 \(Display.money(entry.amountCNY))"
        case .sell: entry.settlementCurrency == .usdt ? "实收 \(Display.usdt(entry.receivedUSDT)) USDT" : "实收 \(Display.money(entry.amountCNY))"
        case .buyUSDT: "支出 \(Display.money(entry.amountCNY))"
        case .sellUSDT: "实收 \(Display.money(entry.amountCNY))"
        case .transfer: "到账 \(Display.btc(entry.receivedSats)) BTC"
        case .fee: nil
        }
    }
    private var principal: String? {
        guard let valuation = store.valuation(for: entry) else { return nil }
        switch entry.kind {
        case .buy, .buyUSDT: return "人民币本金 \(Display.money(valuation.costCNY))"
        case .sell, .sellUSDT: return "移出本金 \(Display.money(valuation.costCNY))"
        case .transfer: return "转出本金 \(Display.money(valuation.costCNY))"
        case .fee: return "费用折合 \(Display.money(valuation.feeCNYEquivalent))"
        }
    }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.kind.icon).font(.headline).frame(width: 34, height: 34).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(accountLabel).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(quantity).monospacedDigit()
                if let settlement { Text(settlement).font(.caption).foregroundStyle(.secondary) }
                if let principal { Text(principal).font(.caption).foregroundStyle(.secondary) }
                if entry.kind == .transfer { Text("手续费 \(Display.fee(entry))").font(.caption).foregroundStyle(.secondary) }
            }
            Text(entry.date.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
        }.padding(.vertical, 10).contentShape(Rectangle())
    }
}
struct HistoryView: View {
    let entries: [LedgerEntry]; let onEntry: (LedgerEntry) -> Void
    var body: some View {
        if entries.isEmpty { ContentUnavailableView("还没有记录", systemImage: "clock", description: Text("从总览的「买入 USDT」或「买入 BTC」按钮开始记录。")) }
        else {
            List { ForEach(entries) { entry in Button { onEntry(entry) } label: { EntryRow(entry: entry) }.buttonStyle(.plain) } }.listStyle(.inset)
        }
    }
}
