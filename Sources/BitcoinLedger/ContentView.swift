import SwiftUI
import LedgerCore

enum Page: String, CaseIterable, Identifiable {
    case dashboard = "总览", history = "历史记录", accounts = "账户"
    var id: String { rawValue }
    var icon: String { switch self { case .dashboard: "square.grid.2x2"; case .history: "clock"; case .accounts: "wallet.bifold" } }
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
                    case .dashboard: DashboardView(onAddAccount: { accountSheet = AccountSheet() }, onEntry: { selectedEntry = $0 })
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
                        }
                    } label: { Label("新增记录", systemImage: "plus") }
                    .disabled(store.accounts.isEmpty || !store.canEdit)
                    .help(store.accounts.isEmpty ? "先在账户页添加一个账户" : "新增账目")
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
    let onAddAccount: () -> Void
    let onEntry: (LedgerEntry) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let state = store.snapshot {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("BITCOIN 总资产").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Display.btc(state.totalSats)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("BTC").font(.title3).foregroundStyle(.secondary)
                        }
                        HStack(alignment: .center) {
                            Text(Display.money(store.quote.map { state.marketValue(price: $0.priceCNY) })).font(.title2).monospacedDigit()
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
                    HStack(spacing: 16) {
                        MetricCard(title: "持仓总成本", value: Display.money(state.costBasisCNY), detail: "移动加权成本")
                        MetricCard(title: "未实现盈亏", value: Display.money(store.quote.map { state.unrealizedPnL(price: $0.priceCNY) }), detail: "当前价值 − 持仓成本")
                        MetricCard(title: "收益率", value: Display.percent(store.quote.flatMap { state.returnRatio(price: $0.priceCNY) }), detail: "未实现盈亏 ÷ 持仓成本")
                    }
                    GroupBox {
                        VStack(spacing: 15) {
                            ForEach(AccountKind.allCases, id: \.self) { kind in
                                DisclosureGroup {
                                    ForEach(store.accounts.filter { $0.kind == kind }) { account in
                                        HStack { Text(account.name); Spacer(); Text("\(Display.btc(state.balances[account.id] ?? 0)) BTC").monospacedDigit() }.padding(.vertical, 4)
                                    }
                                    if !store.accounts.contains(where: { $0.kind == kind }) { Text("还没有\(kind.title)").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                                } label: {
                                    HStack {
                                        Label("\(kind.english) / \(kind.title)", systemImage: kind.icon)
                                        Spacer()
                                        Text("\(Display.btc(store.accounts.filter { $0.kind == kind }.reduce(0) { $0 + (state.balances[$1.id] ?? 0) })) BTC").monospacedDigit()
                                    }.font(.headline)
                                }
                            }
                        }.padding(12)
                    } label: { Text("BTC 所在位置").font(.headline) }
                    HStack(alignment: .top, spacing: 16) {
                        GroupBox {
                            VStack(spacing: 12) {
                                DataRow("累计人民币投入", Display.money(state.investedCNY))
                                DataRow("累计购买 BTC", "\(Display.btc(state.purchasedSats)) BTC")
                                DataRow("平均买入价格", Display.money(state.averageBuyPriceCNY))
                                DataRow("实际成本价", Display.money(state.actualCostPriceCNY))
                                DataRow("已实现盈亏", Display.money(state.realizedPnLCNY))
                            }.padding(12)
                        } label: { Text("成本").font(.headline) }
                        GroupBox {
                            VStack(spacing: 12) {
                                DataRow("累计手续费折合", Display.money(state.totalFeeCNY))
                                DataRow("累计消耗 BTC", "\(Display.btc(state.totalFeeSats)) BTC")
                                DataRow("手续费占投入", Display.percent(state.feeRatio))
                                Text("BTC 手续费按发生时价格折算；不重复计入人民币成本。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(12)
                        } label: { Text("手续费").font(.headline) }
                    }
                    if store.accounts.isEmpty {
                        ContentUnavailableView { Label("从一个账户开始", systemImage: "wallet.bifold") } description: {
                            Text("添加交易所或自托管钱包，再点击右上角 ＋ 记下第一笔买入。")
                        } actions: { Button("添加账户", action: onAddAccount).buttonStyle(.borderedProminent) }
                    } else if !store.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最近记录").font(.headline)
                            ForEach(Array(store.entries.prefix(4))) { entry in
                                Button { onEntry(entry) } label: { EntryRow(entry: entry) }.buttonStyle(.plain)
                                if entry.id != store.entries.prefix(4).last?.id { Divider() }
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1150)
        }.background(Color(nsColor: .windowBackgroundColor))
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
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.kind.icon).font(.headline).frame(width: 34, height: 34).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.kind == .sell && entry.amountCNY == 0 ? "花费 BTC" : entry.kind.title).font(.headline)
                Text(entry.kind == .transfer ? "\(store.accountName(entry.fromAccountID)) → \(store.accountName(entry.toAccountID))" : store.accountName(entry.kind == .buy ? entry.toAccountID : entry.fromAccountID)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.kind == .fee ? Display.fee(entry) : "\(entry.kind == .buy ? "+" : "")\(Display.btc(entry.amountSats)) BTC").monospacedDigit()
                Text(entry.kind == .buy || entry.kind == .sell ? Display.money(entry.amountCNY) : "手续费 \(Display.fee(entry))").font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.date.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
        }.padding(.vertical, 10).contentShape(Rectangle())
    }
}
struct HistoryView: View {
    let entries: [LedgerEntry]; let onEntry: (LedgerEntry) -> Void
    var body: some View {
        if entries.isEmpty { ContentUnavailableView("还没有记录", systemImage: "clock", description: Text("点击右上角 ＋ 记录买入、转账、卖出或手续费。")) }
        else {
            List { ForEach(entries) { entry in Button { onEntry(entry) } label: { EntryRow(entry: entry) }.buttonStyle(.plain) } }.listStyle(.inset)
        }
    }
}
