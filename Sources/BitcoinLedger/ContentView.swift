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

enum DashboardMetric: String, CaseIterable, Identifiable {
    case marketValue, invested, cost, profit, profitRatio, purchased, loss, currentPrice
    static let storageKey = "dashboard.metricOrder.v1"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .marketValue: "当前总市值"
        case .invested: "累计投入"
        case .cost: "综合成本"
        case .profit: "总盈亏"
        case .profitRatio: "总盈亏率"
        case .purchased: "累计购买BTC"
        case .loss: "累计损耗BTC"
        case .currentPrice: "当前BTC市价"
        }
    }
    static func ordered(from raw: String) -> [Self] {
        var seen = Set<Self>()
        let stored = raw.split(separator: ",").compactMap { Self(rawValue: String($0)) }
        return (stored + allCases).filter { seen.insert($0).inserted }
    }
    static func reordered(_ raw: String, moving source: Self, to target: Self) -> String {
        var order = ordered(from: raw)
        guard source != target, let sourceIndex = order.firstIndex(of: source), let targetIndex = order.firstIndex(of: target) else {
            return order.map(\.rawValue).joined(separator: ",")
        }
        order.remove(at: sourceIndex)
        order.insert(source, at: targetIndex)
        return order.map(\.rawValue).joined(separator: ",")
    }
    static func profitColor(_ value: Decimal?) -> Color {
        guard let value, value != 0 else { return .primary }
        return value > 0 ? .green : .red
    }
}

/// Only a token issued by the active local drag can reorder a metric.
struct DashboardMetricDrag {
    let metric: DashboardMetric
    let token: String
    init(_ metric: DashboardMetric) {
        self.metric = metric
        token = "BitcoinLedger.metric.\(metric.rawValue).\(UUID().uuidString)"
    }
    func itemProvider() -> NSItemProvider { NSItemProvider(object: token as NSString) }
    func reordered(_ tokens: [String], rawOrder: String, target: DashboardMetric) -> String? {
        guard tokens.count == 1, tokens.first == token else { return nil }
        return DashboardMetric.reordered(rawOrder, moving: metric, to: target)
    }
}

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLocations = false
    @State private var expandedChart = false
    @State private var activeMetricDrag: DashboardMetricDrag?
    @AppStorage(DashboardMetric.storageKey) private var metricOrder = ""
    let onAdd: (EntryKind) -> Void

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            let padding: CGFloat = compact ? 12 : 16
            // Small windows remain readable; normal windows fit the dashboard.
            let scrollNeeded = expandedChart || geometry.size.height < (compact ? 540 : 440)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let notice = store.migrationNotice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let state = store.snapshot {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center, spacing: compact ? 10 : 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("总持有 BTC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Button { showLocations.toggle() } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                                            Text(Display.btc(state.totalSats)).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                                            Text("BTC").font(.title3).foregroundStyle(.secondary)
                                            Image(systemName: showLocations ? "chevron.up" : "chevron.down").font(.headline).foregroundStyle(.secondary)
                                            Spacer(minLength: 0)
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    .accessibilityLabel("Bitcoin 总持有量 \(Display.btc(state.totalSats)) BTC，\(showLocations ? "收起" : "查看")账户余额")
                                    .accessibilityIdentifier("dashboard.balance")
                                    .help("点击总持有 BTC 查看或收起账户余额")
                                    HStack(spacing: 8) {
                                        LedgerActionButton(title: "购买", icon: "bitcoinsign.circle") { onAdd(.buy) }
                                            .accessibilityIdentifier("dashboard.buy")
                                        LedgerActionButton(title: "转移", icon: "arrow.left.arrow.right.circle") { onAdd(.transfer) }
                                            .accessibilityIdentifier("dashboard.transfer")
                                    }.disabled(!store.canEdit || store.accounts.isEmpty)
                                }.frame(width: compact ? 180 : 250, alignment: .leading)
                                Divider()
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 8, alignment: .leading)],
                                          alignment: .leading, spacing: 8) {
                                    ForEach(DashboardMetric.ordered(from: metricOrder)) { metric in
                                        metricCell(metric, state: state)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if showLocations {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(store.accounts) { account in
                                        DataRow(account.name, "\(Display.btc(state.balances[account.id] ?? 0)) BTC")
                                    }
                                }.padding(.vertical, 4)
                                .accessibilityIdentifier("dashboard.accounts")
                            }
                            if let error = store.priceError { Text(error).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 16))
                            .fixedSize(horizontal: false, vertical: true)
                        BTCChartView(expandedChart: $expandedChart)
                            .frame(maxWidth: .infinity, maxHeight: expandedChart ? nil : .infinity)
                    }
                }
                .frame(height: scrollNeeded ? nil : max(0, geometry.size.height - padding * 2), alignment: .top)
                .padding(padding).frame(maxWidth: 1150)
            }
            .scrollDisabled(!scrollNeeded)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func metricCell(_ metric: DashboardMetric, state: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(metric.title).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if metric == .currentPrice {
                    Button { Task { await store.refreshPrice(force: true) } } label: { Image(systemName: "arrow.clockwise").font(.caption2) }
                        .buttonStyle(.plain).disabled(store.refreshing)
                        .accessibilityIdentifier("dashboard.quoteRefresh")
                        .help("刷新价格（每分钟最多一次）")
                }
            }
            Text(metricValue(metric, state: state)).font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(metricColor(metric, state: state))
                .fixedSize(horizontal: false, vertical: true)
            if metric == .currentPrice, let quote = store.quote, Date().timeIntervalSince(quote.fetchedAt) > 900 {
                Text("缓存价格，等待刷新").font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("dashboard.metric.\(metric.rawValue)")
        .help(metric == .currentPrice ? quoteHelp : "拖动调整指标顺序")
        .onDrag {
            let drag = DashboardMetricDrag(metric)
            activeMetricDrag = drag
            return drag.itemProvider()
        }
        .dropDestination(for: String.self) { tokens, _ in
            defer { activeMetricDrag = nil }
            guard let reordered = activeMetricDrag?.reordered(tokens, rawOrder: metricOrder, target: metric) else { return false }
            metricOrder = reordered
            return true
        }
    }
    private var quoteHelp: String {
        guard let quote = store.quote else { return "联网后显示参考行情；拖动调整指标顺序" }
        return "美元参考行情 · 获取于 \(Display.dateTime(quote.fetchedAt)) · \(quote.source)；拖动调整指标顺序"
    }
    private func metricValue(_ metric: DashboardMetric, state: LedgerSnapshot) -> String {
        switch metric {
        case .marketValue: Display.money(store.quote.map { state.value(price: $0.priceUSD) })
        case .invested: Display.money(state.totalInvestedUSD)
        case .cost: Display.money(state.averageCostUSD) + "/BTC"
        case .profit: Display.money(store.quote.flatMap { state.profit(price: $0.priceUSD) })
        case .profitRatio: Display.percent(store.quote.flatMap { state.profitRatio(price: $0.priceUSD) })
        case .purchased: Display.btc(state.totalPurchasedSats)
        case .loss: Display.btc(state.totalLossSats)
        case .currentPrice: Display.money(store.quote?.priceUSD)
        }
    }
    private func metricColor(_ metric: DashboardMetric, state: LedgerSnapshot) -> Color {
        switch metric {
        case .profit: DashboardMetric.profitColor(store.quote.flatMap { state.profit(price: $0.priceUSD) })
        case .profitRatio: DashboardMetric.profitColor(store.quote.flatMap { state.profitRatio(price: $0.priceUSD) })
        default: .primary
        }
    }
}

struct LedgerActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
        }.buttonStyle(.borderedProminent).controlSize(.small)
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
                Text(Display.dateTime(entry.date)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if entry.kind == .buy {
                    Text("+\(Display.btc(entry.receivedSats)) BTC").monospacedDigit()
                    Text("投入 \(Display.money(entry.amountUSD)) · 原 \(Display.cny(entry.amountCNY))")
                        .font(.caption).foregroundStyle(.secondary)
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
