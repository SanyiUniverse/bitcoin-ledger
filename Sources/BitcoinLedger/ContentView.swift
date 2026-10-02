import SwiftUI
import LedgerCore

enum Page: String, CaseIterable, Identifiable {
    case dashboard = "总览", history = "历史记录"
    var id: String { rawValue }
    var icon: String { self == .dashboard ? "square.grid.2x2" : "clock" }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var page: Page? = .dashboard
    @State private var panel: LedgerPanel?
    @FocusState private var navigationFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in Label(page.rawValue, systemImage: page.icon).tag(page) }
                .focused($navigationFocused)
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
                    } description: { Text(error) } actions: { Button("从备份恢复…") { store.importJSON() } }
                } else {
                    switch page ?? .dashboard {
                    case .dashboard: DashboardView(onAdd: { present(.entry($0, nil)) })
                    case .history: HistoryView(entries: store.entries, onEntry: { present(.detail($0)) })
                    }
                }
            }
            .navigationTitle((page ?? .dashboard).rawValue)
            .toolbar {
                ToolbarItemGroup {
                    Button { present(.rules) } label: { Image(systemName: "info.circle") }.help("计算规则").disabled(panel != nil)
                    Menu {
                        Button("导出完整备份 · JSON…") { store.exportJSON() }.disabled(!store.canEdit)
                        Button("导出历史记录 · CSV…") { store.exportCSV() }.disabled(!store.canEdit)
                        Divider()
                        Button("从备份恢复…") { store.importJSON() }
                    } label: { Label("备份", systemImage: "square.and.arrow.up") }
                    .disabled(panel != nil)
                }
            }
        }
        .disabled(panel != nil)
        .allowsHitTesting(panel == nil)
        .accessibilityHidden(panel != nil)
        .overlay {
            if let panel {
                LedgerPanelOverlay(panel: panel, onDismiss: dismissPanel,
                                   onEdit: { present(.entry($0.kind, $0)) })
                    .environmentObject(store)
            }
        }
        .onDisappear { store.isPresentingPanel = false }
        .alert("Bitcoin Ledger", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("好", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
    }

    private func present(_ destination: LedgerPanel.Destination) {
        navigationFocused = false
        panel = LedgerPanel(destination: destination)
        store.isPresentingPanel = true
    }
    private func dismissPanel() {
        panel = nil
        store.isPresentingPanel = false
        navigationFocused = true
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLocations = false
    let onAdd: (EntryKind) -> Void

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            let row = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let notice = store.migrationNotice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let state = store.snapshot {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("总持有 BTC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Button { showLocations.toggle() } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(Display.btc(state.totalSats)).font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                                    Text("BTC").font(.title3).foregroundStyle(.secondary)
                                    Image(systemName: showLocations ? "chevron.up" : "chevron.down").font(.headline).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityLabel("Bitcoin 总持有量 \(Display.btc(state.totalSats)) BTC，\(showLocations ? "收起" : "查看")账户余额")
                            .accessibilityIdentifier("dashboard.balance")
                            Text(showLocations ? "点击收起账户余额" : "点击总持有 BTC 查看账户余额").font(.caption).foregroundStyle(.secondary)
                            if showLocations {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(store.accounts) { account in
                                        DataRow(account.name, "\(Display.btc(state.balances[account.id] ?? 0)) BTC")
                                    }
                                }.padding(.vertical, 12)
                                .accessibilityIdentifier("dashboard.accounts")
                                Divider()
                            }
                            row {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("当前总市值").font(.caption).foregroundStyle(.secondary)
                                    Text(Display.money(store.quote.map { state.value(price: $0.priceCNY) })).font(.title2).monospacedDigit()
                                }
                                HStack {
                                    VStack(alignment: compact ? .leading : .trailing, spacing: 4) {
                                        Text("当前 BTC 市价 \(Display.money(store.quote?.priceCNY))").font(.subheadline).monospacedDigit()
                                        if let quote = store.quote {
                                            Text("获取于 \(quote.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · \(quote.source)").font(.caption).foregroundStyle(.secondary)
                                            if Date().timeIntervalSince(quote.fetchedAt) > 900 { Text("缓存价格，等待刷新").font(.caption).foregroundStyle(.orange) }
                                        } else { Text("联网后显示参考行情").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Button { Task { await store.refreshPrice(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                                        .disabled(store.refreshing).help("刷新价格（每分钟最多一次）")
                                }.frame(maxWidth: .infinity, alignment: compact ? .leading : .trailing)
                            }
                            if let error = store.priceError { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(24).background(.background, in: RoundedRectangle(cornerRadius: 16))
                        row {
                            HStack(spacing: 8) {
                                LedgerActionButton(title: "购买", icon: "bitcoinsign.circle") { onAdd(.buy) }
                                    .accessibilityIdentifier("dashboard.buy")
                                LedgerActionButton(title: "转移", icon: "arrow.left.arrow.right.circle") { onAdd(.transfer) }
                                    .accessibilityIdentifier("dashboard.transfer")
                            }.fixedSize(horizontal: true, vertical: false)
                                .disabled(!store.canEdit || store.accounts.isEmpty)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14, alignment: .leading)],
                                      alignment: .leading, spacing: 12) {
                                metric("累计投入人民币", Display.money(state.totalInvestedCNY))
                                metric("综合成本 ¥/BTC", Display.money(state.averageCostCNY))
                                metric("累计购买 BTC", Display.btc(state.totalPurchasedSats))
                                metric("累计损耗 BTC", Display.btc(state.totalLossSats))
                                metric("总盈亏", Display.money(store.quote.map { state.profit(price: $0.priceCNY) }))
                                metric("总盈亏率", Display.percent(store.quote.flatMap { state.profitRatio(price: $0.priceCNY) }))
                            }.textSelection(.enabled)
                        }
                        BTCChartView()
                    }
                }.padding(compact ? 20 : 28).frame(maxWidth: 1150)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LedgerActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
        }.buttonStyle(.borderedProminent).controlSize(.regular)
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
    private var accountLabel: String {
        entry.kind == .buy ? store.accountName(entry.toAccountID)
            : "\(store.accountName(entry.fromAccountID)) → \(store.accountName(entry.toAccountID))"
    }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: entry.kind.icon).font(.headline).frame(width: 34, height: 34).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.kind.title).font(.headline)
                Text(accountLabel).foregroundStyle(.secondary)
                Text(entry.date.formatted(date: .numeric, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if entry.kind == .buy {
                    Text("+\(Display.btc(entry.receivedSats)) BTC").monospacedDigit()
                    Text("投入 \(Display.money(entry.amountCNY))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("转出 \(Display.btc(entry.amountSats)) BTC").monospacedDigit()
                    Text("到账 \(Display.btc(entry.receivedSats)) BTC").font(.caption).foregroundStyle(.secondary)
                    Text("损耗 \(Display.btc(entry.lossSats)) BTC").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 10).contentShape(Rectangle())
    }
}

struct HistoryView: View {
    let entries: [LedgerEntry]; let onEntry: (LedgerEntry) -> Void
    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("还没有记录", systemImage: "clock", description: Text("从总览的「购买」开始记录。"))
        } else {
            List { ForEach(entries) { entry in Button { onEntry(entry) } label: { EntryRow(entry: entry) }.buttonStyle(.plain) } }.listStyle(.inset)
        }
    }
}
