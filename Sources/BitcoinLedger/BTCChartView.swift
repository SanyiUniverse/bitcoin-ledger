import SwiftUI
import Charts
import LedgerCore

@MainActor
private final class BTCChartModel: ObservableObject {
    @Published var history: MarketHistory? { didSet { historyRevision += 1 } }
    private(set) var historyRevision = 0
    @Published var loading = false
    @Published var error: String?
    private var cached: [MarketRange: MarketHistory] = [:]
    private var lastAttempt: [MarketRange: Date] = [:]
    private var nextRequestAt = Date.distantPast
    private var rateLimitFailures = 0
    private let cacheURL: URL?
    private let client = MarketHistoryClient()

    init() {
        if let path = ProcessInfo.processInfo.environment["BITCOIN_LEDGER_DATA_PATH"] {
            cacheURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("market-history-daily-v1.json")
        } else {
            cacheURL = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Bitcoin Ledger", isDirectory: true)
                .appendingPathComponent("market-history-daily-v1.json")
        }
        if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                let size = try cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 4_000_000 else { throw MarketHistoryError.invalidResponse }
                let all = try JSONDecoder().decode([MarketHistory].self, from: Data(contentsOf: cacheURL))
                for item in all where item.range == .all {
                    guard valid(item) else { throw MarketHistoryError.invalidResponse }
                    cached[item.range] = item
                }
                lastAttempt = Dictionary(uniqueKeysWithValues: cached.values.map { ($0.range, $0.fetchedAt) })
            } catch { self.error = "本地 K 线缓存无法读取，将重新请求行情。" }
        }
    }
    private func valid(_ item: MarketHistory) -> Bool {
        guard !item.candles.isEmpty, item.candles.count <= 10000,
              item.fetchedAt <= Date().addingTimeInterval(300),
              item.fetchedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        var previous = Date.distantPast
        for candle in item.candles {
            guard MarketHistoryClient.valid(candle), candle.closeDate > previous, candle.closeDate <= item.fetchedAt.addingTimeInterval(300) else { return false }
            previous = candle.closeDate
        }
        return true
    }
    func load(force: Bool = false) async {
        let range = MarketRange.all
        history = cached[range]
        if !force, let history, Date().timeIntervalSince(history.fetchedAt) < 14_400 {
            error = history.warning; return
        }
        guard !loading else { return }
        let allowedAt = max(nextRequestAt, (lastAttempt[range] ?? .distantPast).addingTimeInterval(60))
        guard Date() >= allowedAt else {
            error = "行情暂时使用缓存；\(max(1, Int(allowedAt.timeIntervalSinceNow.rounded(.up)))) 秒后可手动刷新。"
            return
        }
        loading = true
        lastAttempt[range] = Date()
        do {
            let fetched = try await client.fetch(range: range)
            let displayHistory: MarketHistory
            if fetched.warning != nil, let previous = cached[.all] {
                displayHistory = (try? MarketHistoryClient.combine(early: previous.candles, daily: fetched)) ?? fetched
            } else { displayHistory = fetched }
            cached[range] = displayHistory
            history = displayHistory
            rateLimitFailures = 0
            error = displayHistory.warning
            if let cacheURL {
                do {
                    try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheURL.deletingLastPathComponent().path)
                    let data = try JSONEncoder().encode(Array(cached.values))
                    try data.write(to: cacheURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
                } catch { self.error = "行情已加载，但本地缓存未能保存：\(error.localizedDescription)" }
            }
        } catch {
            if error as? MarketHistoryError == .httpStatus(429) {
                rateLimitFailures += 1
                nextRequestAt = Date().addingTimeInterval(min(900, 60 * pow(2, Double(rateLimitFailures))))
            }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// This viewport only changes what is displayed; all daily candles stay in history.
struct BTCChartViewport: Equatable {
    var start: Date
    var end: Date
    static let genesis = Date(timeIntervalSince1970: 1_230_940_800)

    init(start: Date, end: Date) { self.start = start; self.end = end }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    func zoom(factor: Double, around anchor: Date?, today: Date) -> Self {
        let total = max(86400, today.timeIntervalSince(Self.genesis))
        let width = min(total, max(86400, duration * factor))
        let focalDate = anchor.map { min(end, max(start, $0)) } ?? start.addingTimeInterval(duration / 2)
        let fraction = duration > 0 ? focalDate.timeIntervalSince(start) / duration : 0.5
        return Self.clamped(start: focalDate.addingTimeInterval(-width * fraction), duration: width, today: today)
    }
    func moving(_ direction: Double, today: Date) -> Self {
        Self.clamped(start: start.addingTimeInterval(duration * direction * 0.75), duration: duration, today: today)
    }
    func panning(points: Double, plotWidth: Double, today: Date) -> Self {
        guard plotWidth > 0, plotWidth.isFinite, points.isFinite else { return self }
        return Self.clamped(start: start.addingTimeInterval(-points / plotWidth * duration), duration: duration, today: today)
    }
    func stepping(_ direction: Int, period: MarketPeriod, today: Date) -> Self {
        Self.clamped(start: Self.stepDate(start, direction: direction, period: period), duration: duration, today: today)
    }
    static func stepDate(_ date: Date, direction: Int, period: MarketPeriod) -> Date {
        let component: Calendar.Component = period == .month ? .month : .day
        let units = direction * (period == .week ? 7 : 1)
        return MarketHistory.utcCalendar.date(byAdding: component, value: units, to: date) ?? date
    }
    private static func clamped(start: Date, duration: TimeInterval, today: Date) -> Self {
        let width = min(duration, today.timeIntervalSince(genesis))
        let lower = min(max(start, genesis), today.addingTimeInterval(-width))
        return Self(start: lower, end: lower.addingTimeInterval(width))
    }
}

/// The day summary cannot overflow Int64 even after repeated internal transfers.
/// Each source quantity is exact satoshis; only the aggregate uses Decimal BTC.
struct BTCDailyChartTotals {
    var purchaseCount = 0
    var transferCount = 0
    var investedCNY: Decimal = 0
    var purchasedBTC: Decimal = 0
    var transferredBTC: Decimal = 0
    var receivedBTC: Decimal = 0
    var lossBTC: Decimal = 0
    init(entries: [LedgerEntry], through cutoff: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for entry in entries where entry.date <= cutoff && calendar.isDate(entry.date, inSameDayAs: cutoff) {
            if entry.kind == .buy {
                purchaseCount += 1; investedCNY += entry.amountCNY
                purchasedBTC += Amounts.btc(entry.amountSats)
            } else {
                transferCount += 1; transferredBTC += Amounts.btc(entry.amountSats)
                receivedBTC += Amounts.btc(entry.receivedSats); lossBTC += Amounts.btc(entry.lossSats)
            }
        }
    }
}

/// A reference line stops at real candles and, for daily data, missing days.
struct BTCReferenceSegment: Identifiable {
    let id: Int
    var candles: [MarketCandle]
    static func make(candles: [MarketCandle], period: MarketPeriod) -> [Self] {
        var result: [Self] = []
        var canAppend = false
        for candle in candles {
            guard !candle.hasOHLC else { canAppend = false; continue }
            if canAppend, let previous = result.last?.candles.last,
               period != .day || candle.closeDate.timeIntervalSince(previous.closeDate) <= 86_401 {
                result[result.count - 1].candles.append(candle)
            } else { result.append(Self(id: result.count, candles: [candle])) }
            canAppend = true
        }
        return result
    }
}

private struct ChartEvent: Identifiable {
    let entry: LedgerEntry
    let y: Double
    var id: UUID { entry.id }
}

private struct BTCPlotCacheKey: Equatable {
    let historyRevision: Int
    let accounts: [Account]
    let entries: [LedgerEntry]
    let range: MarketRange
    let period: MarketPeriod
    let window: BTCChartViewport
}

private struct BTCPlotData {
    let id = UUID()
    let window: BTCChartViewport
    let period: MarketPeriod
    let candles: [MarketCandle]
    let referenceSegments: [BTCReferenceSegment]
    let costs: [CostChartPoint]
    let events: [ChartEvent]
    let yDomain: ClosedRange<Double>
}

/// A small revision invalidates market data, and the complete account/entry
/// values invalidate editing, deletion, and migration without inspecting count.
@MainActor
private final class BTCPlotCache: ObservableObject {
    private var key: BTCPlotCacheKey?
    private var cached: BTCPlotData?
    func data(history: MarketHistory, key incoming: BTCPlotCacheKey) -> BTCPlotData {
        if key == incoming, let cached { return cached }
        let candles = history.aggregatedCandles(period: incoming.period, from: incoming.window.start, through: incoming.window.end)
        let costs = (try? LedgerChartHistory.costPoints(accounts: incoming.accounts, entries: incoming.entries,
            from: incoming.window.start, through: incoming.window.end)) ?? []
        let events = ((try? LedgerChartHistory.events(accounts: incoming.accounts, entries: incoming.entries,
            history: history, from: incoming.window.start, through: incoming.window.end)) ?? []).map {
                ChartEvent(entry: $0.entry, y: NSDecimalNumber(decimal: $0.markerPriceCNY).doubleValue)
            }
        let highs = candles.map { NSDecimalNumber(decimal: $0.high).doubleValue }
            + costs.map { NSDecimalNumber(decimal: $0.costCNY).doubleValue } + events.map(\.y)
        let lows = candles.map { NSDecimalNumber(decimal: $0.low).doubleValue }
            + costs.map { NSDecimalNumber(decimal: $0.costCNY).doubleValue } + events.map(\.y)
        let minimum = lows.min() ?? 0, maximum = highs.max() ?? 1
        let pad = max((maximum - minimum) * 0.08, maximum * 0.01)
        let data = BTCPlotData(window: incoming.window, period: incoming.period, candles: candles,
            referenceSegments: BTCReferenceSegment.make(candles: candles, period: incoming.period),
            costs: costs, events: events, yDomain: max(0, minimum - pad)...(maximum + pad))
        key = incoming; cached = data
        return data
    }
}

/// Market bars share two batched paths per style rather than thousands of
/// SwiftUI chart nodes. Every observed daily/weekly/monthly bar is retained.
private struct BTCPricePlot: View, Equatable {
    let data: BTCPlotData
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.data.id == rhs.data.id }
    var body: some View {
        Chart {
            PointMark(x: .value("日期", data.window.start), y: .value("坐标", data.yDomain.lowerBound)).opacity(0)
            PointMark(x: .value("日期", data.window.end), y: .value("坐标", data.yDomain.upperBound)).opacity(0)
            ForEach(data.costs) { point in
                LineMark(x: .value("日期", point.date), y: .value("综合成本", double(point.costCNY)), series: .value("成本分段", point.segment))
                    .foregroundStyle(Color.orange).lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(data.events) { marker in eventMark(marker) }
        }
        .chartXScale(domain: data.window.start...data.window.end, range: .plotDimension(padding: 0))
        .chartYScale(domain: data.yDomain, range: .plotDimension(padding: 0))
        .chartPlotStyle { plot in
            plot.background {
                Canvas { context, size in drawMarket(context: context, size: size) }
                    .allowsHitTesting(false)
            }.clipped()
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let date = value.as(Date.self) { Text(axisDate(date)) } } } }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel() } }
    }
    private func drawMarket(context: GraphicsContext, size: CGSize) {
        let xScale = size.width / data.window.duration
        let yScale = size.height / (data.yDomain.upperBound - data.yDomain.lowerBound)
        func x(_ date: Date) -> CGFloat { date.timeIntervalSince(data.window.start) * xScale }
        func y(_ value: Decimal) -> CGFloat { (data.yDomain.upperBound - double(value)) * yScale }
        var up = Path(), down = Path(), partialUp = Path(), partialDown = Path()
        for candle in data.candles where candle.hasOHLC {
            let rising = candle.close >= candle.open
            var bar = Path()
            let center = x(candle.centerDate)
            bar.move(to: CGPoint(x: center, y: y(candle.high)))
            bar.addLine(to: CGPoint(x: center, y: y(candle.low)))
            let left = x(candle.startDate.addingTimeInterval(candle.interval * 0.12))
            let right = x(candle.closeDate.addingTimeInterval(-candle.interval * 0.12))
            let top = y(max(candle.open, candle.close)), bottom = y(min(candle.open, candle.close))
            bar.addRect(CGRect(x: left, y: top, width: max(0.5, right - left), height: max(0.7, bottom - top)))
            if candle.isComplete && candle.missingDays == 0 {
                if rising { up.addPath(bar) } else { down.addPath(bar) }
            } else {
                if rising { partialUp.addPath(bar) } else { partialDown.addPath(bar) }
            }
        }
        for (path, color, opacity) in [(up, Color.green, 1.0), (down, Color.red, 1.0),
                                       (partialUp, Color.green, 0.55), (partialDown, Color.red, 0.55)] {
            context.fill(path, with: .color(color.opacity(opacity)))
            context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: 1)
        }
        var references = Path(), points = Path()
        for segment in data.referenceSegments {
            if segment.candles.count == 1, let candle = segment.candles.first {
                points.addEllipse(in: CGRect(x: x(candle.closeDate) - 2, y: y(candle.close) - 2, width: 4, height: 4))
            } else {
                for (index, candle) in segment.candles.enumerated() {
                    let point = CGPoint(x: x(candle.closeDate), y: y(candle.close))
                    if index == 0 { references.move(to: point) } else { references.addLine(to: point) }
                }
            }
        }
        context.stroke(references, with: .color(.secondary), lineWidth: 1.5)
        context.fill(points, with: .color(.secondary))
    }
    @ChartContentBuilder
    private func eventMark(_ marker: ChartEvent) -> some ChartContent {
        if marker.entry.kind == .buy {
            PointMark(x: .value("日期", marker.entry.date), y: .value("事件", marker.y))
                .symbol(BasicChartSymbolShape.circle).symbolSize(CGFloat(65)).foregroundStyle(Color.blue)
        } else {
            PointMark(x: .value("日期", marker.entry.date), y: .value("事件", marker.y))
                .symbol(BasicChartSymbolShape.diamond).symbolSize(CGFloat(65)).foregroundStyle(Color.purple)
        }
    }
    private func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }
    private func axisDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = data.window.duration > 370 * 86400 ? "yyyy/M" : "M/d"
        return formatter.string(from: date)
    }
}

/// Uses the same picker instances while placing details beside controls when
/// space permits and below them on narrow windows.
private struct BTCControlsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let left = subviews.first?.sizeThatFits(ProposedViewSize(width: 180, height: nil)) ?? .zero
        guard subviews.count > 1 else { return CGSize(width: width, height: max(60, left.height)) }
        let horizontal = width >= 520
        let right = subviews[1].sizeThatFits(ProposedViewSize(width: horizontal ? width - 192 : width, height: nil))
        return CGSize(width: width, height: horizontal ? max(60, max(left.height, right.height)) : left.height + 8 + right.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(at: bounds.origin, proposal: ProposedViewSize(width: 180, height: nil))
        guard subviews.count > 1 else { return }
        if bounds.width >= 520 {
            subviews[1].place(at: CGPoint(x: bounds.minX + 192, y: bounds.minY), proposal: ProposedViewSize(width: bounds.width - 192, height: nil))
        } else {
            let leftHeight = first.sizeThatFits(ProposedViewSize(width: 180, height: nil)).height
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + leftHeight + 8), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

struct BTCChartView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model = BTCChartModel()
    @StateObject private var plotCache = BTCPlotCache()
    @State private var range: MarketRange = .month
    @State private var period: MarketPeriod = .day
    @State private var hoverDate: Date?
    @State private var selectedDate: Date?
    @State private var viewport: BTCChartViewport?
    @State private var today = Date()
    @State private var expandedChart = false
    private let costColor = Color.orange

    private var window: BTCChartViewport {
        viewport ?? BTCChartViewport(start: range.startDate(today: today), end: today)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { title; Spacer(); actionControls }
            BTCControlsLayout {
                controls.frame(width: 180, alignment: .leading)
                if let history = model.history, let selectedDate { historicalDetails(history, date: selectedDate) }
            }
            ViewThatFits(in: .horizontal) {
                HStack { legend; Spacer(); zoomControls }
                VStack(alignment: .leading, spacing: 8) { legend; zoomControls }
            }
            if let history = model.history {
                marketChart(history)
                Text("\(dayText(window.start)) — \(dayText(window.end)) · \(period.title)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("双指左右移动、捏合缩放；点击图后 ← / → 逐根移动。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                sourceCaption(history)
            } else {
                VStack(spacing: 12) {
                    if model.loading { ProgressView() }
                    Text(model.loading ? "正在读取 BTC 人民币历史 K 线…" : "暂无 K 线行情")
                    Text("联网成功后显示真实开、高、低、收价格。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 350)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .task { await model.load() }
        .onChange(of: range) { _, _ in
            today = Date(); viewport = nil; hoverDate = nil; selectedDate = nil
        }
        .onChange(of: period) { _, _ in today = Date(); viewport = nil; hoverDate = nil; selectedDate = nil }
        .onChange(of: model.history?.fetchedAt) { _, _ in today = Date() }
    }
    private var title: some View { Text("BTC 人民币 K 线").font(.headline) }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) { rangeControl; periodControl }
    }
    private var rangeControl: some View {
        HStack(spacing: 8) {
            Text("时间范围").fixedSize().frame(width: 60, alignment: .leading)
            Picker("时间范围", selection: $range) {
                ForEach(MarketRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 112)
        }
    }
    private var periodControl: some View {
        HStack(spacing: 8) {
            Text("K 线周期").fixedSize().frame(width: 60, alignment: .leading)
            Picker("K 线周期", selection: $period) {
                ForEach(MarketPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 96)
        }
    }
    private var actionControls: some View {
        HStack(spacing: 8) {
            Button { expandedChart.toggle() } label: {
                Image(systemName: expandedChart ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }.help(expandedChart ? "收起图幅" : "展开图幅").accessibilityLabel(expandedChart ? "收起图幅" : "展开图幅")
            Button { Task { await model.load(force: true) } } label: {
                if model.loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.disabled(model.loading).help("刷新历史行情").accessibilityLabel("刷新 K 线")
        }
    }
    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { moveWindow(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(window.start <= BTCChartViewport.genesis).help("较早的时间")
                .accessibilityLabel("向前移动图表时间窗")
            Button { changeZoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(window.duration <= 86400).help("放大时间细节")
                .accessibilityLabel("放大 K 线")
            Button { changeZoom(2) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(window.duration >= today.timeIntervalSince(BTCChartViewport.genesis)).help("缩小时间细节")
                .accessibilityLabel("缩小 K 线")
            Button("重置") { viewport = nil; hoverDate = nil; selectedDate = nil }
                .help("回到所选时间范围")
            Button { moveWindow(1) } label: { Image(systemName: "chevron.right") }
                .disabled(window.end >= today).help("较近的时间")
                .accessibilityLabel("向后移动图表时间窗")
        }.controlSize(.small)
    }
    private func changeZoom(_ factor: Double) {
        viewport = window.zoom(factor: factor, around: selectedDate, today: today)
        hoverDate = nil
        if let selectedDate, selectedDate < window.start || selectedDate > window.end { self.selectedDate = nil }
    }
    private func moveWindow(_ direction: Double) {
        viewport = window.moving(direction, today: today)
        hoverDate = nil; selectedDate = nil
    }
    private func stepWindow(_ direction: Int) {
        let previous = window
        let moved = previous.stepping(direction, period: period, today: today)
        guard moved != previous else { return }
        viewport = moved; hoverDate = nil
        if let selectedDate {
            let stepped = BTCChartViewport.stepDate(selectedDate, direction: direction, period: period)
            self.selectedDate = min(moved.end, max(moved.start, stepped))
        } else { selectedDate = moved.start.addingTimeInterval(moved.duration / 2) }
    }
    private var legend: some View {
        HStack(spacing: 12) {
            Label("市价", systemImage: "chart.bar.xaxis").foregroundStyle(.secondary)
            Label("综合成本", systemImage: "minus").foregroundStyle(costColor)
            Label("购买", systemImage: "circle.fill").foregroundStyle(.blue)
            Label("转移", systemImage: "diamond.fill").foregroundStyle(.purple)
        }.font(.caption)
    }
    private func marketChart(_ history: MarketHistory) -> some View {
        let data = plotCache.data(history: history, key: BTCPlotCacheKey(historyRevision: model.historyRevision,
            accounts: store.document.accounts, entries: store.document.entries, range: range, period: period, window: window))
        return BTCPricePlot(data: data).equatable()
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let plot = geometry[frame]
                    if let hoverDate, let x = proxy.position(forX: hoverDate) {
                        Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: plot.height)
                            .position(x: plot.minX + x, y: plot.midY).allowsHitTesting(false)
                    }
                    BTCChartInput(
                        onHover: { point in
                            guard let point, let date = proxy.value(atX: point.x, as: Date.self) else { hoverDate = nil; return }
                            hoverDate = min(window.end, max(window.start, date)); selectedDate = hoverDate
                        },
                        onPan: { delta in
                            viewport = window.panning(points: delta, plotWidth: plot.width, today: today)
                            hoverDate = nil
                            if let selectedDate, selectedDate < window.start || selectedDate > window.end { self.selectedDate = nil }
                        },
                        onMagnify: { factor, point in
                            let anchor = proxy.value(atX: point.x, as: Date.self) ?? selectedDate
                            viewport = window.zoom(factor: factor, around: anchor, today: today)
                            hoverDate = nil
                            if let selectedDate, selectedDate < window.start || selectedDate > window.end { self.selectedDate = nil }
                        },
                        onStep: { direction in stepWindow(direction) },
                        onDismissDetails: { hoverDate = nil; selectedDate = nil }
                    )
                    .frame(width: plot.width, height: plot.height)
                    .position(x: plot.midX, y: plot.midY)
                }
            }
        }
        .frame(height: expandedChart ? 620 : 360)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("BTC 人民币 K 线、综合成本与购买转移事件。当前 \(period.title)，\(data.candles.count) 根可见行情。移动鼠标后在周期选择旁查看历史状态。")
    }
    private func sourceCaption(_ history: MarketHistory) -> some View {
        Text("Yahoo Finance · CoinMetrics · ECB · 获取 \(dateText(history.fetchedAt)) · 灰线/灰点为参考收盘，缺失留空。")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func historicalDetails(_ history: MarketHistory, date: Date) -> some View {
        let state = try? LedgerEngine.calculate(accounts: store.document.accounts, entries: store.document.entries, asOf: date)
        let candle = history.latestClose(asOf: date)
        let price = candle?.close
        let totals = BTCDailyChartTotals(entries: store.document.entries, through: date)
        return VStack(alignment: .leading, spacing: 4) {
            Text("截止 \(dateText(date)) · \(candle.map { "\($0.hasOHLC ? "日行情" : "参考收盘（非 OHLC）") \(dateText($0.closeDate))\($0.isComplete ? "" : "（未收盘）")" } ?? "暂无此前行情")")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 4) {
                metricCell("BTC 市价", Display.money(price))
                metricCell("综合成本", Display.money(state?.averageCostCNY))
                metricCell("总持有 BTC", state.map { Display.btc($0.totalSats) } ?? "—")
                metricCell("累计投入人民币", Display.money(state?.totalInvestedCNY))
                metricCell("累计损耗 BTC", state.map { Display.btc($0.totalLossSats) } ?? "—")
                metricCell("盈亏金额", Display.money(price.flatMap { state?.profit(price: $0) }))
                metricCell("盈亏率", Display.percent(price.flatMap { state?.profitRatio(price: $0) }))
            }
            if totals.purchaseCount > 0 {
                Text("当天购买：\(Display.money(totals.investedCNY)) → \(btcText(totals.purchasedBTC)) BTC")
                    .font(.caption2).fixedSize(horizontal: false, vertical: true)
            }
            if totals.transferCount > 0 {
                Text("当天转移：转出 \(btcText(totals.transferredBTC)) · 到账 \(btcText(totals.receivedBTC)) · 损耗 \(btcText(totals.lossBTC)) BTC")
                    .font(.caption2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
    }
    private func metricCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func btcText(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 8; formatter.maximumFractionDigits = 8
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    private func dayText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!; formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
