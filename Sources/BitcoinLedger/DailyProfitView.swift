import SwiftUI
import Charts
import LedgerCore

@MainActor enum ProfitDates {
    private static let dayFormat = formatter("yyyy-MM-dd")
    private static let minuteFormat = formatter("HH:mm")
    private static let secondFormat = formatter("HH:mm:ss")
    private static func formatter(_ pattern: String) -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN")
        format.timeZone = TimeZone(identifier: "Asia/Shanghai")
        format.dateFormat = pattern
        return format
    }
    static func day(_ date: Date) -> String {
        dayFormat.string(from: date)
    }
    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let format = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 ? minuteFormat : secondFormat
        return format.string(from: date)
    }
    static func dateTime(_ date: Date) -> String { "\(day(date)) \(time(date))" }
    static func settlementHelp(_ date: Date?) -> String {
        let clock = date.map { time($0) } ?? "首笔购买时刻"
        return "每天北京时间 \(clock)，按首笔购买的时分秒结算。行情采用结算前最后已结束的一分钟收盘，不使用未来一分钟。"
    }
}

struct DailyProfitView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedDate: Date?
    @State private var tableSelectionRevision = 0
    @State private var chartScrollRevision = 0
    private var settlementClock: String { ProfitDates.time(store.dailyProfitSettlementAnchor) }
    private var chartSelection: Binding<Date?> {
        Binding(get: { selectedDate }, set: { date in
            guard date != selectedDate else { return }
            selectedDate = date
            if date != nil { chartScrollRevision &+= 1 }
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let rows = store.dailyProfitRows
            let compact = geometry.size.width < 720 || geometry.size.height < 540
            let padding: CGFloat = compact ? 8 : 12
            let spacing: CGFloat = compact ? 8 : 12
            let availableWidth = max(0, geometry.size.width - padding * 2 - spacing)
            let listWidth = availableWidth * 0.45
            VStack(alignment: .leading, spacing: spacing) {
                currentSummary(compact: compact).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: spacing) {
                    historyPanel(rows: rows, width: listWidth, compact: compact || listWidth < 350)
                        .frame(width: listWidth).frame(maxHeight: .infinity)
                    DailyProfitChart(rows: rows, fillHeight: true, compact: compact || availableWidth * 0.55 < 340,
                                     settlementAnchor: store.dailyProfitSettlementAnchor,
                                     selection: chartSelection, revealSelectionRevision: tableSelectionRevision)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(padding)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dailyProfit.page")
        }
        .task { await store.refreshDailyProfit(forceMissing: false) }
    }

    private func currentSummary(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack {
                Label("当前估算", systemImage: "bolt.circle").font(compact ? .subheadline : .headline)
                Spacer()
                Button {
                    Task {
                        await store.refreshPrice(force: true)
                        await store.refreshDailyProfit(forceMissing: true)
                    }
                } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(store.refreshing || store.dailyProfitRefreshing)
                    .controlSize(compact ? .mini : .small)
                    .accessibilityIdentifier("dailyProfit.refresh")
            }
            HStack(alignment: .top, spacing: compact ? 6 : 16) {
                currentMetric(compact ? "成本" : "当前成本", value: store.snapshot?.totalInvestedUSD, identifier: "cost", compact: compact)
                currentMetric(compact ? "市值" : "当前市值", value: store.quote.flatMap { store.snapshot?.value(price: $0.priceUSD) }, identifier: "value", compact: compact)
                currentMetric(compact ? "卖出盈亏" : "估算卖出盈亏", value: store.quote.flatMap { store.snapshot?.profit(price: $0.priceUSD) }, identifier: "profit", compact: compact, colored: true)
                currentMetric("盈亏率", value: store.quote.flatMap { store.snapshot?.profitRatio(price: $0.priceUSD) }, identifier: "ratio", compact: compact, percent: true, colored: true)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("未扣额外卖出费用")
                    if let quote = store.quote {
                        VStack(alignment: .trailing, spacing: 1) {
                            if compact {
                                Text("行情 · \(ProfitDates.day(quote.fetchedAt))")
                                Text(String(Display.dateTime(quote.fetchedAt).suffix(5)))
                            } else {
                                Text("行情获取于 \(Display.dateTime(quote.fetchedAt))")
                            }
                        }.help("\(quote.source) · 获取于 \(Display.dateTime(quote.fetchedAt))")
                            .accessibilityIdentifier("dailyProfit.quoteTime")
                    }
                }
                .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary)
                .frame(width: compact ? 100 : 170, alignment: .trailing)
            }
            if let deadline = store.priceRetryAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
                    Text(seconds > 0 ? "行情暂时使用缓存；\(seconds) 秒后自动重试。" : "正在自动重试行情…")
                        .font(compact ? .caption2 : .caption).foregroundStyle(.orange).monospacedDigit()
                }
            } else if let error = store.priceError {
                Text(error).font(compact ? .caption2 : .caption).foregroundStyle(.orange)
                    .lineLimit(2).help(error)
            }
            if let settlement = store.dailyProfitSettlementToday, store.dailyProfitNow < settlement {
                Text(compact ? "今日尚未结算 · 每天 \(settlementClock) 保留一条记录" : "今日尚未结算 · 北京时间 \(settlementClock) 保留一条固定记录")
                    .font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
                    .help(ProfitDates.settlementHelp(store.dailyProfitSettlementAnchor))
            }
        }
        .padding(compact ? 8 : 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private func currentMetric(_ title: String, value: Decimal?, identifier: String, compact: Bool,
                               percent: Bool = false, colored: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(percent ? Display.percent(value) : Display.money(value))
                .font(.system(size: compact ? 18 : 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(colored ? DashboardMetric.profitColor(value) : .primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("dailyProfit.current.\(identifier)")
    }

    private func historyPanel(rows: [DailyProfitRow], width: CGFloat, compact: Bool) -> some View {
        let padding: CGFloat = compact ? 8 : 10
        let columnsWidth = max(0, width - padding * 2 - 16)
        return VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack {
                Text("每日明细").font(compact ? .subheadline : .headline)
                Spacer()
                if store.dailyProfitRefreshing { ProgressView().controlSize(.small) }
                Text("\(rows.count) 天").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.dailyProfitError {
                Text(error).font(compact ? .caption2 : .caption).foregroundStyle(.orange)
            }
            if let deadline = store.dailyProfitRetryAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
                    Text(seconds > 0 ? "\(seconds) 秒后自动补齐每日行情。" : "正在自动补齐每日行情…")
                        .font(compact ? .caption2 : .caption).foregroundStyle(.orange).monospacedDigit()
                }
            } else if let progress = store.dailyProfitProgress {
                Text(progress).font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
            }
            if !compact {
                HStack(spacing: 4) {
                    historyCell("日期 · \(settlementClock)", width: columnsWidth * 0.25)
                    historyCell("成本", width: columnsWidth * 0.19)
                    historyCell("市值", width: columnsWidth * 0.19)
                    historyCell("盈亏", width: columnsWidth * 0.20)
                    historyCell("盈亏率", width: columnsWidth * 0.17)
                }.font(.caption2).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: compact ? 6 : 0) {
                        if rows.isEmpty {
                            Text(store.entries.isEmpty ? "记录第一笔购买后，开始生成每日盈亏。" : "等待今日 \(settlementClock) 结算。")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                        ForEach(Array(rows.reversed())) { row in
                            Button { selectRow(row.date) } label: {
                                if compact {
                                    compactHistoryRow(row)
                                } else {
                                    HStack(alignment: .top, spacing: 4) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            historyCell(ProfitDates.day(row.date), width: columnsWidth * 0.25)
                                            if let caption = statusCaption(row) {
                                                Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
                                            }
                                        }.frame(width: columnsWidth * 0.25, alignment: .leading)
                                        historyCell(Display.money(row.costUSD), width: columnsWidth * 0.19,
                                            color: Self.costColor(row))
                                        historyCell(Display.money(row.marketValueUSD), width: columnsWidth * 0.19)
                                        historyCell(Display.money(row.profitUSD), width: columnsWidth * 0.20,
                                            color: DashboardMetric.profitColor(row.profitUSD))
                                        historyCell(Display.percent(row.profitRatio), width: columnsWidth * 0.17,
                                            color: DashboardMetric.profitColor(row.profitRatio))
                                    }.font(.system(size: 11)).monospacedDigit().padding(.vertical, 7)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(selectedDate == row.date ? Color.blue.opacity(0.12) : Color.clear)
                                }
                            }
                            .buttonStyle(.plain).contentShape(Rectangle()).id(row.date).help(detail(row))
                            .accessibilityIdentifier("dailyProfit.row.\(ProfitDates.day(row.date))")
                            .accessibilityValue(selectedDate == row.date ? "已选中" : "")
                            if !compact { Divider() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("dailyProfit.table")
                .onChange(of: chartScrollRevision) { _, _ in
                    if let selectedDate { proxy.scrollTo(selectedDate, anchor: .center) }
                }
            }
            .frame(maxHeight: .infinity)
            Text(compact ? "\(settlementClock) · 固定价格" : "按当时持仓和本金计算；旧交易更正后同步更新。")
                .font(.caption2).foregroundStyle(.secondary)
                .help(ProfitDates.settlementHelp(store.dailyProfitSettlementAnchor)
                    + " 每条记录使用当时持仓与本金；更正首笔购买的时间后，重选每日结算时刻并补齐对应行情。")
        }
        .padding(padding).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain).accessibilityIdentifier("dailyProfit.list")
    }

    private func historyCell(_ text: String, width: CGFloat, color: Color = .primary) -> some View {
        Text(text).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(color)
            .frame(width: width, alignment: .leading).help(text)
    }

    private func compactHistoryRow(_ row: DailyProfitRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ProfitDates.day(row.date)).fontWeight(.medium)
                Spacer(minLength: 0)
                if let caption = statusCaption(row) { Text(caption).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 4) {
                HStack(spacing: 2) {
                    Text("成本")
                    Text(Display.money(row.costUSD)).foregroundStyle(Self.costColor(row))
                }
                Spacer(minLength: 0)
                Text("市值 \(Display.money(row.marketValueUSD))")
            }
            HStack(spacing: 4) {
                Text("盈亏 \(Display.money(row.profitUSD))").foregroundStyle(DashboardMetric.profitColor(row.profitUSD))
                Spacer(minLength: 0)
                Text("率 \(Display.percent(row.profitRatio))").foregroundStyle(DashboardMetric.profitColor(row.profitRatio))
            }
        }
        .font(.system(size: 10)).monospacedDigit()
        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
        .background(selectedDate == row.date ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7))
        .help(detail(row))
    }

    static func costColor(_ row: DailyProfitRow) -> Color {
        guard row.costUSD != nil else { return .secondary }
        guard row.purchaseCount > 0 else { return .primary }
        guard let change = row.purchaseCostChangeUSD else { return .secondary }
        guard change != 0 else { return .primary }
        return DashboardMetric.profitColor(change)
    }

    private func selectRow(_ date: Date) {
        selectedDate = date
        tableSelectionRevision &+= 1
    }

    private func statusCaption(_ row: DailyProfitRow) -> String? {
        switch row.status {
        case .available: nil
        case .pendingPrice: "待补齐行情"
        case .missingPrice: "结算行情缺失"
        case .pendingCost: "等待购买汇率"
        case .beforeFirstPurchase: "结算时尚未购买"
        }
    }
    private func detail(_ row: DailyProfitRow) -> String {
        let observation = row.observation
        return "\(ProfitDates.dateTime(row.date)) · \(Display.btc(row.totalSats)) BTC"
            + (row.purchaseCount > 0 ? "\n本条结算计入 \(row.purchaseCount) 笔购买记账" : "")
            + (observation.map { "\n\($0.source) · 获取于 \(Display.dateTime($0.fetchedAt))" } ?? "")
    }
}

struct DailyProfitChart: View {
    let rows: [DailyProfitRow]
    var fillHeight = false
    var compact = false
    var settlementAnchor: Date? = nil
    var selection: Binding<Date?>? = nil
    var revealSelectionRevision = 0
    @State private var localSelectedDate: Date?
    @State private var viewport: BTCChartViewport?
    struct Point: Identifiable {
        var id: Date { date }
        let date: Date
        let value: Double
        let segment: Int
    }
    struct PlotData {
        let points: [Point]
        let visibleRows: [DailyProfitRow]
        let profitDomain: ClosedRange<Double>
        let symbolSize: CGFloat
        let hasPrices: Bool
    }
    /// Every absent value starts a new line series, so a gap is never interpolated.
    static func points(_ rows: [DailyProfitRow]) -> [Point] {
        var segment = 0
        var previous: Date?
        return rows.compactMap { row in
            guard let profit = row.profitUSD else { segment += 1; previous = nil; return nil }
            if let previous, row.date.timeIntervalSince(previous) > 86_401 { segment += 1 }
            previous = row.date
            return Point(date: row.date, value: NSDecimalNumber(decimal: profit).doubleValue, segment: segment)
        }
    }
    /// One render projection is shared by marks, axes, input and details.
    static func plotData(rows: [DailyProfitRow], window: ClosedRange<Date>) -> PlotData {
        let allPoints = Self.points(rows)
        let points = allPoints.filter { window.contains($0.date) }
        let visibleRows = rows.filter { window.contains($0.date) }
        var lower = 0.0, upper = 0.0
        for point in points { lower = min(lower, point.value); upper = max(upper, point.value) }
        let padding = max(0.01, (upper - lower) * 0.08)
        return PlotData(points: points, visibleRows: visibleRows,
            profitDomain: (lower - padding)...(upper + padding), symbolSize: points.count > 180 ? 8 : 22,
            hasPrices: !allPoints.isEmpty)
    }
    private var selectedDate: Date? {
        if let selection { return selection.wrappedValue }
        return localSelectedDate
    }
    private var settlementDate: Date? { settlementAnchor ?? rows.first?.date }
    private var settlementClock: String { settlementDate.map { ProfitDates.time($0) } ?? "首笔购买时刻" }
    private var fullWindow: BTCChartViewport {
        let first = rows.first?.date ?? Date()
        let last = rows.last?.date ?? first
        return first == last
            ? BTCChartViewport(start: first.addingTimeInterval(-43_200), end: last.addingTimeInterval(43_200))
            : BTCChartViewport(start: first, end: last)
    }
    private var minimumDuration: TimeInterval { min(3 * 86_400, fullWindow.duration) }
    private var window: BTCChartViewport {
        viewport?.zoom(factor: 1, around: nil, today: fullWindow.end,
            minimumDuration: minimumDuration, lowerBound: fullWindow.start) ?? fullWindow
    }
    private var domain: ClosedRange<Date> { window.start...window.end }
    private var axisDates: [Date] {
        guard rows.count > 1 else { return [rows.first?.date ?? Date()] }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        var days: Set<String> = []
        return [0.2, 0.5, 0.8].map { domain.lowerBound.addingTimeInterval(span * $0) }
            .filter { days.insert(ProfitDates.day($0)).inserted }
    }
    private var navigationControls: some View {
        HStack(spacing: compact ? 4 : 8) { navigationButtons }
            .frame(maxWidth: .infinity, alignment: .leading).disabled(rows.isEmpty)
    }
    private var navigationButtons: some View {
        Group {
            navigationButton("向前", icon: "chevron.left", id: "back", disabled: window.start <= fullWindow.start) { move(-1) }
            navigationButton("放大", icon: "plus.magnifyingglass", id: "zoomIn", disabled: window.duration <= minimumDuration + 0.1) { zoom(0.5) }
            navigationButton("缩小", icon: "minus.magnifyingglass", id: "zoomOut", disabled: window.duration >= fullWindow.duration - 0.1) { zoom(2) }
            navigationButton("重置", icon: "arrow.counterclockwise", id: "reset", disabled: viewport == nil) { viewport = nil }
            navigationButton("向后", icon: "chevron.right", id: "forward", disabled: window.end >= fullWindow.end) { move(1) }
        }
    }
    private func navigationButton(_ title: String, icon: String, id: String, disabled: Bool,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if compact { Image(systemName: icon).frame(width: 16) }
            else { Text(title) }
        }
        .font(compact ? .caption2 : .caption).controlSize(compact ? .mini : .small)
        .disabled(disabled).help(title == "重置" ? "显示全部历史" : title)
        .accessibilityLabel(title).accessibilityIdentifier("dailyProfit.chart.\(id)")
    }
    var body: some View {
        let visibleWindow = domain
        let data = Self.plotData(rows: rows, window: visibleWindow)
        let selected = selectedDate.flatMap { date in rows.first { $0.date == date } }
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            if compact {
                HStack {
                    Text(!data.hasPrices && !rows.isEmpty ? "盈亏曲线 · 待行情" : "盈亏曲线 · $").font(.subheadline)
                    Spacer(minLength: 2)
                    if let first = rows.first {
                        Text(rows.count == 1 ? String(ProfitDates.day(first.date).suffix(5))
                            : "\(String(ProfitDates.day(window.start).suffix(5))) — \(String(ProfitDates.day(window.end).suffix(5)))")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .help("\(ProfitDates.day(window.start)) — \(ProfitDates.day(window.end))")
                            .accessibilityIdentifier("dailyProfit.chart.range")
                    }
                }.help(ProfitDates.settlementHelp(settlementDate) + " 相对当时本金的累计盈亏，单位为美元。")
            } else {
                Text("每日盈亏曲线").font(.headline)
                Text(!data.hasPrices && !rows.isEmpty ? "结算行情待补齐 · 北京时间每天 \(settlementClock)"
                    : "北京时间每天 \(settlementClock) · 相对当时本金的累计盈亏 · 美元")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(ProfitDates.settlementHelp(settlementDate))
            }
            navigationControls
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").font(compact ? .title3 : .largeTitle)
                    Text("等待每日记录").font(compact ? .subheadline : .headline)
                    Text(rows.isEmpty ? "首笔购买结算后显示第一个数据点。" : "补齐结算行情后显示曲线；缺失日期保持留空。")
                        .font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: fillHeight ? 120 : nil, maxHeight: fillHeight ? .infinity : nil)
                .frame(height: fillHeight ? nil : 260)
            } else {
                Chart {
                    RuleMark(y: .value("盈亏", 0)).foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    ForEach(data.points) { point in
                        LineMark(x: .value("日期", point.date), y: .value("盈亏", point.value),
                                 series: .value("连续区间", point.segment))
                            .foregroundStyle(Color.accentColor).interpolationMethod(.linear)
                        PointMark(x: .value("日期", point.date), y: .value("盈亏", point.value))
                            .foregroundStyle(point.value < 0 ? Color.red : point.value > 0 ? Color.green : Color.secondary)
                            .symbolSize(data.symbolSize)
                    }
                    if let selected {
                        RuleMark(x: .value("查看日期", selected.date)).foregroundStyle(Color.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartXScale(domain: visibleWindow, range: .plotDimension(padding: 0))
                .chartYScale(domain: data.profitDomain)
                .chartPlotStyle { plot in plot.clipped() }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plotFrame = proxy.plotFrame {
                            let plot = geometry[plotFrame]
                            let snapshot = BTCChartInputSnapshot(timeWindow: visibleWindow, priceDomain: data.profitDomain,
                                visibleOHLCCount: 0, visibleOHLCDomain: nil, manualPriceScale: false,
                                detailsDate: selected?.date, detailsSats: selected?.totalSats,
                                detailsPriceUSD: selected?.priceUSD, detailsInvestedUSD: selected?.costUSD,
                                visibleCandleCount: data.points.count)
                            BTCChartInput(
                                onHover: { point in
                                    guard let point, let date = date(atX: point.x, plotWidth: plot.width) else { return }
                                    selectNearest(to: date, candidates: data.visibleRows.isEmpty ? rows : data.visibleRows)
                                },
                                onPan: { delta in
                                    apply(window.panning(points: delta, plotWidth: plot.width,
                                        today: fullWindow.end, lowerBound: fullWindow.start))
                                },
                                onMagnify: { factor, point in
                                    zoom(factor, around: date(atX: point.x, plotWidth: plot.width))
                                },
                                onStep: { direction in move(Double(direction)) },
                                onDismissDetails: {},
                                snapshot: snapshot
                            )
                            .frame(width: plot.width, height: plot.height)
                            .position(x: plot.midX, y: plot.midY)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: axisDates) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(compact ? String(ProfitDates.day(date).suffix(5)) : ProfitDates.day(date))
                                    .font(compact ? .system(size: 9) : .caption)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine(); AxisTick(); AxisValueLabel().font(compact ? .system(size: 9) : .caption)
                    }
                }
                .frame(minHeight: fillHeight ? (compact ? 144 : 200) : nil, maxHeight: fillHeight ? .infinity : nil)
                .frame(height: fillHeight ? nil : 280)
                .accessibilityIdentifier("dailyProfit.chart")
                .help("捏合缩放日期，双指左右移动；移动鼠标或点击查看当日明细。")
            }
            if !rows.isEmpty && !compact {
                Text(rows.count == 1 ? ProfitDates.day(rows[0].date)
                    : "\(ProfitDates.day(window.start)) — \(ProfitDates.day(window.end))")
                    .font(compact ? .system(size: 9) : .caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("dailyProfit.chart.range")
            }
            if let row = selected ?? data.visibleRows.last ?? rows.last {
                HStack(alignment: .firstTextBaseline, spacing: compact ? 4 : 12) {
                    Text(compact ? ProfitDates.day(row.date) : ProfitDates.dateTime(row.date)).foregroundStyle(.secondary)
                        .help(ProfitDates.settlementHelp(row.date))
                    if compact { Spacer(minLength: 0) }
                    Text(Display.money(row.profitUSD)).foregroundStyle(DashboardMetric.profitColor(row.profitUSD))
                    Text(Display.percent(row.profitRatio)).foregroundStyle(DashboardMetric.profitColor(row.profitRatio))
                }.font(compact ? .system(size: 10) : .subheadline).monospacedDigit()
                .accessibilityIdentifier("dailyProfit.chartDetail")
                Text("本金 \(Display.money(row.costUSD)) · 市值 \(Display.money(row.marketValueUSD))")
                    .font(compact ? .system(size: 9) : .caption).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 8 : 16).frame(maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: selectedDate) { _, date in reveal(date) }
        .onChange(of: revealSelectionRevision) { _, _ in reveal(selectedDate) }
        .onChange(of: rows.map(\.date)) { _, dates in
            if let selectedDate, !dates.contains(selectedDate) {
                if let selection { selection.wrappedValue = nil }
                else { localSelectedDate = nil }
            }
        }
    }
    private func date(atX point: CGFloat, plotWidth: CGFloat) -> Date? {
        guard point.isFinite, plotWidth.isFinite, plotWidth > 0 else { return nil }
        let fraction = min(1, max(0, point / plotWidth))
        return window.start.addingTimeInterval(window.duration * fraction)
    }
    private func zoom(_ factor: Double, around date: Date? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        apply(window.zoom(factor: factor, around: date, today: fullWindow.end,
            minimumDuration: minimumDuration, lowerBound: fullWindow.start))
    }
    private func move(_ direction: Double) {
        apply(window.moving(direction, today: fullWindow.end, lowerBound: fullWindow.start))
    }
    private func apply(_ newWindow: BTCChartViewport) {
        viewport = newWindow == fullWindow ? nil : newWindow
    }
    private func selectNearest(to date: Date, candidates: [DailyProfitRow]) {
        guard let row = candidates.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              row.date != selectedDate else { return }
        if let selection { selection.wrappedValue = row.date }
        else { localSelectedDate = row.date }
    }
    private func reveal(_ date: Date?) {
        guard let date, rows.contains(where: { $0.date == date }), !domain.contains(date) else { return }
        let duration = window.duration
        let centered = BTCChartViewport(start: date.addingTimeInterval(-duration / 2),
                                        end: date.addingTimeInterval(duration / 2))
        apply(centered.zoom(factor: 1, around: nil, today: fullWindow.end,
            minimumDuration: minimumDuration, lowerBound: fullWindow.start))
    }
}
