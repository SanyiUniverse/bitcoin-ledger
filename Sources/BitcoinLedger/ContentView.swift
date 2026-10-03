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
    case cost, marketValue, profit, profitRatio
    static let storageKey = "dashboard.metricOrder.v2"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cost: "总成本"
        case .marketValue: "当前市值"
        case .profit: "浮盈"
        case .profitRatio: "浮盈率"
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
            let compact = geometry.size.width < 760
            let padding: CGFloat = compact ? 12 : 16
            // Small windows remain readable; normal windows fit the dashboard.
            let minimumHeight: CGFloat = compact ? 1000 : (geometry.size.width < 860 ? 730 : 600)
            let scrollNeeded = expandedChart || geometry.size.height < minimumHeight || showLocations
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let notice = store.migrationNotice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let state = store.snapshot {
                        VStack(alignment: .leading, spacing: 12) {
                            if compact {
                                holdings(state)
                                metricGrid(state, valueSize: 22, spacing: 12)
                            } else {
                                HStack(alignment: .bottom, spacing: 22) {
                                    holdings(state)
                                        .frame(width: min(320, max(260, geometry.size.width * 0.34)), alignment: .leading)
                                    Divider().frame(height: 110)
                                    metricGrid(state, valueSize: geometry.size.width < 860 ? 22 : 26)
                                        .frame(minHeight: 110, alignment: .bottom)
                                }
                            }
                            if showLocations {
                                Divider().opacity(0.6)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], alignment: .leading, spacing: 10) {
                                    ForEach(store.accounts) { account in
                                        VStack(alignment: .leading, spacing: 7) {
                                            Label(account.name, systemImage: "wallet.bifold").font(.subheadline).foregroundStyle(.secondary)
                                            Text("\(Display.btc(state.balances[account.id] ?? 0)) BTC")
                                                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                                                .lineLimit(1).minimumScaleFactor(0.75)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                                .accessibilityIdentifier("dashboard.accounts")
                            }
                            if let error = store.priceError { Text(error).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(.horizontal, compact ? 16 : 20).padding(.vertical, 16)
                            .background(.background, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.045)))
                            .fixedSize(horizontal: false, vertical: true)
                        BTCChartView(expandedChart: $expandedChart)
                            .frame(maxWidth: .infinity, maxHeight: expandedChart ? nil : .infinity)
                    }
                }
                .frame(height: scrollNeeded ? nil : max(0, geometry.size.height - padding * 2), alignment: .top)
                .padding(padding).frame(maxWidth: .infinity)
            }
            .scrollDisabled(!scrollNeeded)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func holdings(_ state: LedgerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("总持有 BTC").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Button { withAnimation(.easeInOut(duration: 0.18)) { showLocations.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(Display.btc(state.totalSats))
                        .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("BTC").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Image(systemName: showLocations ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityLabel("Bitcoin 总持有量 \(Display.btc(state.totalSats)) BTC，\(showLocations ? "收起" : "查看")钱包余额")
            .accessibilityIdentifier("dashboard.balance")
            .help("点击总持有 BTC 查看或收起各钱包余额")
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(spacing: 10) {
                    LedgerActionButton(title: "购买", icon: "plus.circle") { onAdd(.buy) }
                        .accessibilityIdentifier("dashboard.buy")
                    LedgerActionButton(title: "转移", icon: "arrow.left.arrow.right") { onAdd(.transfer) }
                        .accessibilityIdentifier("dashboard.transfer")
                }
                .frame(width: 146, alignment: .leading)
                .disabled(!store.canEdit || store.accounts.isEmpty)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(metricValue(.cost, state: state))
                        .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.65)
                    Text("总成本").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("dashboard.metric.cost")
                .help(metricHelp(.cost))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricGrid(_ state: LedgerSnapshot, valueSize: CGFloat, spacing: CGFloat = 24) -> some View {
        let metrics = DashboardMetric.ordered(from: metricOrder).filter { $0 != .cost }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(metrics) { metric in
                    metricCell(metric, state: state, valueSize: valueSize)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    quoteSummary.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 16)
                    lossSummary(state).fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    quoteSummary
                    lossSummary(state)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lossSummary(_ state: LedgerSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("累计损耗：").font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Display.btc(state.totalLossSats))
                    .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text("BTC").font(.caption2).foregroundStyle(.secondary)
            }.accessibilityIdentifier("dashboard.loss")
            Text("占持有 \(Display.percent(state.lossRatio))")
                .font(.caption2.weight(.medium)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.orange.opacity(0.10), in: Capsule())
                .accessibilityIdentifier("dashboard.lossRatio")
                .help("累计损耗 BTC ÷ 当前总持有 BTC；无持有时不计算比例")
        }
    }

    private var quoteSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("BTC 市价：").font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(Display.money(store.quote?.priceUSD))
                    .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.65)
                Button { Task { await store.refreshPrice(force: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption2)
                }
                    .buttonStyle(.plain).disabled(store.refreshing)
                    .accessibilityIdentifier("dashboard.quoteRefresh")
                    .help("刷新价格（每分钟最多一次）")
                if let quote = store.quote, Date().timeIntervalSince(quote.fetchedAt) > 900 {
                    Text("缓存").font(.caption2).foregroundStyle(.orange)
                }
            }
        }.help(quoteHelp)
    }

    private func metricCell(_ metric: DashboardMetric, state: LedgerSnapshot, valueSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(metric.title).font(.subheadline).foregroundStyle(.secondary)
            Text(metricValue(metric, state: state)).font(.system(size: valueSize, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(metricColor(metric, state: state))
                .lineLimit(1).minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier("dashboard.metric.\(metric.rawValue)")
        .help(metricHelp(metric) + "；拖动调整指标顺序")
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
        guard let quote = store.quote else { return "联网后显示美元参考行情" }
        return "美元参考行情 · 获取于 \(Display.dateTime(quote.fetchedAt)) · \(quote.source)"
    }
    private func metricHelp(_ metric: DashboardMetric) -> String {
        switch metric {
        case .cost: "实际花费的总金额，按购买时保存的汇率折合美元；转移不增加成本"
        case .marketValue: "当前持有 BTC × 当前 BTC 美元市价"
        case .profit: "当前市值 − 总成本，亏损显示负数"
        case .profitRatio: "浮盈 ÷ 总成本"
        }
    }
    private func metricValue(_ metric: DashboardMetric, state: LedgerSnapshot) -> String {
        switch metric {
        case .marketValue: Display.money(store.quote.map { state.value(price: $0.priceUSD) })
        case .cost: Display.money(state.totalInvestedUSD)
        case .profit: Display.money(store.quote.flatMap { state.profit(price: $0.priceUSD) })
        case .profitRatio: Display.percent(store.quote.flatMap { state.profitRatio(price: $0.priceUSD) })
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
