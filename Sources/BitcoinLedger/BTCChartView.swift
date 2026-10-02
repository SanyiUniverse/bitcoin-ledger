import SwiftUI
import Charts
import LedgerCore

private struct BTCChartLoad: Equatable, Hashable, Sendable {
    let period: MarketPeriod
    let window: BTCChartViewport
    var sourcePeriod: MarketPeriod { period.isIntraday ? period : .day }
}

private struct BTCMarketCacheRecord: Codable {
    let period: MarketPeriod
    let from: Date
    let through: Date
    let history: MarketHistory
    var window: BTCChartViewport { BTCChartViewport(start: from, end: through) }
    func covers(_ load: BTCChartLoad) -> Bool {
        period == load.sourcePeriod && (!period.isIntraday || from <= load.window.start && through >= load.window.end)
    }
}

@MainActor
private final class BTCChartModel: ObservableObject {
    @Published var history: MarketHistory? { didSet { historyRevision += 1 } }
    private(set) var historyRevision = 0
    @Published var loading = false
    @Published var error: String?
    @Published private(set) var rejected: BTCChartLoad?
    private(set) var displayedWindow: BTCChartViewport?
    private(set) var coverageWindow: BTCChartViewport?
    private var cached: [MarketPeriod: BTCMarketCacheRecord] = [:]
    private var lastAttempt: [BTCChartLoad: Date] = [:]
    private var lastPeriodAttempt: [MarketPeriod: Date] = [:]
    private var requested: BTCChartLoad?
    private var activeLoad: BTCChartLoad?
    private var fetchTask: Task<(MarketHistory, BTCChartViewport), Error>?
    private var nextRequestAt = Date.distantPast
    private var rateLimitFailures = 0
    private let cacheDirectory: URL?
    private let client = MarketHistoryClient()

    static func fileName(period: MarketPeriod) -> String {
        if !period.isIntraday { return "market-history-daily-usd-v1.json" }
        if period == .minute { return "market-history-minute-usd-v1.json" }
        return "market-history-intraday-\(period.rawValue)-usd-v1.json"
    }
    init() {
        if let path = ProcessInfo.processInfo.environment["BITCOIN_LEDGER_DATA_PATH"] {
            cacheDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
        } else {
            cacheDirectory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Bitcoin Ledger", isDirectory: true)
        }
        for period in MarketPeriod.allCases where period.isIntraday || period == .day {
            guard let url = cacheDirectory?.appendingPathComponent(Self.fileName(period: period)), FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8_000_000 else { throw MarketHistoryError.invalidResponse }
                let bytes = try Data(contentsOf: url)
                let record: BTCMarketCacheRecord
                if period == .day {
                    guard let item = try JSONDecoder().decode([MarketHistory].self, from: bytes).first else { throw MarketHistoryError.invalidResponse }
                    record = BTCMarketCacheRecord(period: .day, from: MarketRange.genesisDate, through: item.fetchedAt, history: item)
                } else { record = try JSONDecoder().decode(BTCMarketCacheRecord.self, from: bytes) }
                guard valid(record), record.period == period else { throw MarketHistoryError.invalidResponse }
                cached[period] = record; lastPeriodAttempt[period] = itemFetchedAt(record)
            } catch { self.error = "本地美元 K 线缓存无法读取，将重新请求行情。" }
        }
    }
    private func itemFetchedAt(_ record: BTCMarketCacheRecord) -> Date { record.history.fetchedAt }
    private func valid(_ record: BTCMarketCacheRecord) -> Bool {
        let item = record.history
        guard record.period == item.period, record.from >= MarketRange.genesisDate, record.from < record.through,
              record.through <= Date().addingTimeInterval(300), record.from.timeIntervalSince1970.isFinite,
              record.through.timeIntervalSince1970.isFinite, !item.candles.isEmpty,
              item.candles.count <= (record.period.isIntraday ? 16000 : 10000),
              item.fetchedAt <= Date().addingTimeInterval(300), item.fetchedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        var previous = Date.distantPast
        for candle in item.candles {
            guard MarketHistoryClient.valid(candle), candle.closeDate > previous,
                  candle.closeDate <= min(item.fetchedAt, record.through).addingTimeInterval(1),
                  candle.startDate >= record.from.addingTimeInterval(-record.period.nominalSeconds) else { return false }
            if record.period.isIntraday {
                let startMinute = candle.startDate.timeIntervalSince1970 / 60
                guard candle.interval <= record.period.nominalSeconds + 1, abs(startMinute - startMinute.rounded()) < 0.000001 else { return false }
            }
            previous = candle.closeDate
        }
        return true
    }
    private func publish(_ record: BTCMarketCacheRecord, for load: BTCChartLoad) {
        history = record.history; coverageWindow = record.window; displayedWindow = load.window
        rejected = nil; error = record.history.warning
    }
    func load(period: MarketPeriod = .day, window: BTCChartViewport, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let load = BTCChartLoad(period: period, window: window)
        requested = load
        if loading, activeLoad != load { fetchTask?.cancel() }
        let sourcePeriod = load.sourcePeriod
        if !sourcePeriod.isIntraday || window.duration / sourcePeriod.nominalSeconds <= 16000 {
            if let previous = cached[sourcePeriod], previous.covers(load) {
                publish(previous, for: load)
                if !force, Date().timeIntervalSince(previous.history.fetchedAt) < (sourcePeriod.isIntraday ? 60 : 14400) { return }
            }
        } else {
            rejected = load; error = MarketHistoryError.rangeTooLarge.localizedDescription
            return
        }
        guard !loading else { return }
        let allowedAt = max(nextRequestAt, (lastAttempt[load] ?? .distantPast).addingTimeInterval(60),
                            force ? (lastPeriodAttempt[sourcePeriod] ?? .distantPast).addingTimeInterval(60) : .distantPast)
        guard Date() >= allowedAt else {
            error = "行情暂时使用缓存；\(max(1, Int(allowedAt.timeIntervalSinceNow.rounded(.up)))) 秒后可手动刷新。"
            return
        }
        if lastAttempt.count > 48 { lastAttempt = lastAttempt.filter { Date().timeIntervalSince($0.value) < 60 } }
        loading = true; error = history?.warning
        let previousAttempt = lastAttempt[load]
        let previousPeriodAttempt = lastPeriodAttempt[sourcePeriod]
        lastAttempt[load] = Date(); lastPeriodAttempt[sourcePeriod] = Date()
        do {
            activeLoad = load
            let work = Task { [client] () throws -> (MarketHistory, BTCChartViewport) in
                let fetched: MarketHistory
                let expected: BTCChartViewport
                if !sourcePeriod.isIntraday {
                    fetched = try await client.fetch(range: .all)
                    expected = BTCChartViewport(start: MarketRange.genesisDate, end: fetched.fetchedAt)
                } else if sourcePeriod == .minute, window.start >= Date().addingTimeInterval(-7 * 86400 - 60), window.end >= Date().addingTimeInterval(-60), window.end <= Date() {
                    let start = Date().addingTimeInterval(-7 * 86400)
                    fetched = try await client.fetchMinutes()
                    expected = BTCChartViewport(start: min(window.start, Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 60) * 60)), end: fetched.fetchedAt)
                } else {
                    fetched = try await client.fetchIntraday(period: sourcePeriod, from: window.start, through: window.end)
                    expected = window
                }
                try Task.checkCancellation()
                return (fetched, expected)
            }
            fetchTask = work
            let (fetched, expected) = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            let displayHistory: MarketHistory
            if sourcePeriod == .day, fetched.warning != nil, let previous = cached[.day] {
                displayHistory = (try? MarketHistoryClient.combine(early: previous.history.candles, daily: fetched)) ?? fetched
            } else { displayHistory = fetched }
            let record = BTCMarketCacheRecord(period: sourcePeriod, from: expected.start, through: expected.end, history: displayHistory)
            guard valid(record) else { throw MarketHistoryError.invalidResponse }
            cached[sourcePeriod] = record; rateLimitFailures = 0
            if let latest = requested, record.covers(latest) { publish(record, for: latest) }
            if let directory = cacheDirectory {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                    let bytes = sourcePeriod == .day ? try JSONEncoder().encode([displayHistory]) : try JSONEncoder().encode(record)
                    guard bytes.count <= 8_000_000 else { throw MarketHistoryError.invalidResponse }
                    let url = directory.appendingPathComponent(Self.fileName(period: sourcePeriod))
                    try bytes.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch { if requested == load { self.error = "行情已加载，但本地缓存未能保存：\(error.localizedDescription)" } }
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                lastAttempt[load] = previousAttempt; lastPeriodAttempt[sourcePeriod] = previousPeriodAttempt
            } else {
                if error as? MarketHistoryError == .httpStatus(429) {
                    rateLimitFailures += 1
                    nextRequestAt = Date().addingTimeInterval(min(900, 60 * pow(2, Double(rateLimitFailures))))
                }
                if requested == load {
                    rejected = load; self.error = error.localizedDescription
                }
            }
        }
        fetchTask = nil; activeLoad = nil; loading = false
        if let pending = requested, pending != load {
            Task {
                guard self.requested == pending else { return }
                await self.load(period: pending.period, window: pending.window)
            }
        }
    }
}

// This viewport only changes what is displayed; all daily candles stay in history.
struct BTCChartViewport: Equatable, Hashable, Sendable {
    var start: Date
    var end: Date
    static let genesis = Date(timeIntervalSince1970: 1_230_940_800)

    init(start: Date, end: Date) { self.start = start; self.end = end }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    func zoom(factor: Double, around anchor: Date?, today: Date, minimumDuration: TimeInterval = 86400, lowerBound: Date = Self.genesis) -> Self {
        let total = max(minimumDuration, today.timeIntervalSince(lowerBound))
        let width = min(total, max(minimumDuration, duration * factor))
        let focalDate = anchor.map { min(end, max(start, $0)) } ?? start.addingTimeInterval(duration / 2)
        let fraction = duration > 0 ? focalDate.timeIntervalSince(start) / duration : 0.5
        return Self.clamped(start: focalDate.addingTimeInterval(-width * fraction), duration: width, today: today, lowerBound: lowerBound)
    }
    func moving(_ direction: Double, today: Date, lowerBound: Date = Self.genesis) -> Self {
        Self.clamped(start: start.addingTimeInterval(duration * direction * 0.75), duration: duration, today: today, lowerBound: lowerBound)
    }
    func panning(points: Double, plotWidth: Double, today: Date, lowerBound: Date = Self.genesis) -> Self {
        guard plotWidth > 0, plotWidth.isFinite, points.isFinite else { return self }
        return Self.clamped(start: start.addingTimeInterval(-points / plotWidth * duration), duration: duration, today: today, lowerBound: lowerBound)
    }
    func stepping(_ direction: Int, period: MarketPeriod, today: Date, lowerBound: Date = Self.genesis) -> Self {
        Self.clamped(start: Self.stepDate(start, direction: direction, period: period), duration: duration, today: today, lowerBound: lowerBound)
    }
    static func stepDate(_ date: Date, direction: Int, period: MarketPeriod) -> Date {
        if period.isIntraday { return date.addingTimeInterval(Double(direction) * period.nominalSeconds) }
        let component: Calendar.Component
        let units: Int
        switch period {
        case .month: component = .month; units = direction
        case .quarter: component = .month; units = direction * 3
        case .year: component = .year; units = direction
        case .week: component = .day; units = direction * 7
        case .day3: component = .day; units = direction * 3
        default: component = .day; units = direction
        }
        return MarketHistory.utcCalendar.date(byAdding: component, value: units, to: date) ?? date
    }
    private static func clamped(start: Date, duration: TimeInterval, today: Date, lowerBound: Date = Self.genesis) -> Self {
        let width = min(duration, today.timeIntervalSince(lowerBound))
        let lower = min(max(start, lowerBound), today.addingTimeInterval(-width))
        return Self(start: lower, end: lower.addingTimeInterval(width))
    }
}

/// A manual price window is independent of the dataset's default range.
/// Horizontal panning never changes it; zooming preserves a price anchor.
struct BTCPriceViewport: Equatable {
    let lower: Double
    let upper: Double
    static let maximumValue = 1e100
    var span: Double { upper - lower }
    var minimumSpan: Double { max(0.01, max(abs(lower), abs(upper)) * 1e-12) }
    var domain: ClosedRange<Double> { lower...upper }
    init(domain: ClosedRange<Double>) { lower = domain.lowerBound; upper = domain.upperBound }
    func zoom(factor: Double, around anchor: Double?) -> Self {
        guard factor.isFinite, factor > 0, lower.isFinite, upper.isFinite, span > 0 else { return self }
        let width = min(Self.maximumValue, max(minimumSpan, span * factor))
        let price = anchor.flatMap { $0.isFinite && domain.contains($0) ? $0 : nil } ?? (lower + span / 2)
        let fraction = min(1, max(0, (price - lower) / span))
        let start = min(Self.maximumValue - width, max(0, price - width * fraction))
        return Self(domain: start...(start + width))
    }
}

/// The day summary cannot overflow Int64 even after repeated internal transfers.
/// Each source quantity is exact satoshis; only the aggregate uses Decimal BTC.
struct BTCDailyChartTotals {
    var purchaseCount = 0
    var transferCount = 0
    var investedUSD: Decimal? = 0
    var purchasedBTC: Decimal = 0
    var transferredBTC: Decimal = 0
    var receivedBTC: Decimal = 0
    var lossBTC: Decimal = 0
    init(entries: [LedgerEntry], through cutoff: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for entry in entries where entry.date <= cutoff && calendar.isDate(entry.date, inSameDayAs: cutoff) {
            if entry.kind == .buy {
                purchaseCount += 1
                if let total = investedUSD, let amount = entry.amountUSD { investedUSD = total + amount } else { investedUSD = nil }
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
            if canAppend, let previous = result.last?.candles.last, adjacent(previous, candle, period: period) {
                result[result.count - 1].candles.append(candle)
            } else { result.append(Self(id: result.count, candles: [candle])) }
            canAppend = true
        }
        return result
    }
    private static func adjacent(_ previous: MarketCandle, _ candle: MarketCandle, period: MarketPeriod) -> Bool {
        if period == .month || period == .quarter || period == .year {
            let calendar = MarketHistory.utcCalendar
            func index(_ date: Date) -> Int {
                let year = calendar.component(.year, from: date), month = calendar.component(.month, from: date)
                if period == .year { return year }
                if period == .quarter { return year * 4 + (month - 1) / 3 }
                return year * 12 + month - 1
            }
            return index(candle.startDate) - index(previous.startDate) == 1
        }
        return candle.closeDate.timeIntervalSince(previous.closeDate) <= period.nominalSeconds + 1
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
    let priceWindow: BTCPriceViewport?
}

struct BTCChartAxis {
    static func timeStep(duration: TimeInterval) -> TimeInterval {
        let steps: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 21600, 43200, 86400,
            172800, 432000, 604800, 1209600, 2592000, 7776000, 15552000, 31536000, 63072000, 157680000, 315360000]
        return steps.first { $0 >= duration / 5 } ?? steps.last!
    }
    static func timeTicks(window: BTCChartViewport) -> [Date] {
        let step = timeStep(duration: window.duration)
        let first = ceil(window.start.timeIntervalSince1970 / step) * step
        guard first <= window.end.timeIntervalSince1970 else { return [] }
        return stride(from: first, through: window.end.timeIntervalSince1970, by: step).map(Date.init(timeIntervalSince1970:))
    }
    static func priceStep(span: Double) -> Double {
        let raw = max(span / 4, 0.00000001)
        let power = pow(10, floor(log10(raw)))
        let unit = raw / power
        return (unit <= 1 ? 1 : unit <= 2 ? 2 : unit <= 5 ? 5 : 10) * power
    }
    static func priceDomain(minimum: Double, maximum: Double) -> ClosedRange<Double> {
        let pad = max((maximum - minimum) * 0.08, max(maximum * 0.01, 0.01))
        let lower = max(0, minimum - pad), upper = maximum + pad
        let step = priceStep(span: upper - lower)
        return (floor(lower / step) * step)...(ceil(upper / step) * step)
    }
    static func priceTicks(domain: ClosedRange<Double>) -> [Double] {
        let step = priceStep(span: domain.upperBound - domain.lowerBound)
        let first = ceil(domain.lowerBound / step) * step
        guard first <= domain.upperBound else { return [] }
        return stride(from: first, through: domain.upperBound, by: step).map { $0 }
    }
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
    let visibleOHLCCount: Int
    let visibleOHLCDomain: ClosedRange<Double>?
}

/// A small revision invalidates market data, and the complete account/entry
/// values invalidate editing, deletion, and migration without inspecting count.
@MainActor
private final class BTCPlotCache: ObservableObject {
    private var key: BTCPlotCacheKey?
    private var cached: BTCPlotData?
    func data(history: MarketHistory, key incoming: BTCPlotCacheKey) -> BTCPlotData {
        if key == incoming, let cached { return cached }
        let candles = history.aggregatedCandles(period: incoming.period, from: incoming.window.start, through: incoming.window.end).filter {
            $0.hasOHLC ? $0.closeDate > incoming.window.start && $0.startDate < incoming.window.end
                : $0.closeDate >= incoming.window.start && $0.closeDate <= incoming.window.end
        }
        let costs = (try? LedgerChartHistory.costPoints(accounts: incoming.accounts, entries: incoming.entries,
            from: incoming.window.start, through: incoming.window.end)) ?? []
        let events = ((try? LedgerChartHistory.events(accounts: incoming.accounts, entries: incoming.entries,
            history: history, from: incoming.window.start, through: incoming.window.end)) ?? []).map {
                ChartEvent(entry: $0.entry, y: NSDecimalNumber(decimal: $0.markerPriceUSD).doubleValue)
            }
        // Fit only the visible observations on an explicit time zoom/reset.
        // Panning supplies a frozen priceWindow and therefore keeps its scale.
        let costsAndEvents = costs.map { NSDecimalNumber(decimal: $0.costUSD).doubleValue } + events.map(\.y)
        let highs = candles.map { NSDecimalNumber(decimal: $0.hasOHLC ? $0.high : $0.close).doubleValue } + costsAndEvents
        let lows = candles.map { NSDecimalNumber(decimal: $0.hasOHLC ? $0.low : $0.close).doubleValue } + costsAndEvents
        let yDomain = BTCChartAxis.priceDomain(minimum: lows.min() ?? 0, maximum: highs.max() ?? 1)
        let ohlc = candles.filter(\.hasOHLC)
        let marketDomain: ClosedRange<Double>? = ohlc.isEmpty ? nil : ohlc.map { NSDecimalNumber(decimal: $0.low).doubleValue }.min()!...ohlc.map { NSDecimalNumber(decimal: $0.high).doubleValue }.max()!
        let data = BTCPlotData(window: incoming.window, period: incoming.period, candles: candles,
            referenceSegments: BTCReferenceSegment.make(candles: candles, period: incoming.period),
            costs: costs, events: events, yDomain: incoming.priceWindow?.domain ?? yDomain,
            visibleOHLCCount: ohlc.count, visibleOHLCDomain: marketDomain)
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
                LineMark(x: .value("日期", point.date), y: .value("综合成本", double(point.costUSD)), series: .value("成本分段", point.segment))
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
        .chartXAxis { AxisMarks(values: BTCChartAxis.timeTicks(window: data.window)) { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let date = value.as(Date.self) { Text(axisDate(date)) } } } }
        .chartYAxis { AxisMarks(position: .trailing, values: BTCChartAxis.priceTicks(domain: data.yDomain)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel() } }
    }
    private func drawMarket(context: GraphicsContext, size: CGSize) {
        var context = context
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
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
        formatter.dateFormat = data.window.duration < 86400 ? "HH:mm" : data.window.duration <= 2 * 86400 ? "M/d HH:mm" : data.window.duration > 370 * 86400 ? "yyyy/M" : "M/d"
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

private enum BTCVisibleRange: Hashable {
    case preset(MarketRange)
    case custom
}

struct BTCChartView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model = BTCChartModel()
    @StateObject private var plotCache = BTCPlotCache()
    @State private var range: MarketRange = .month
    @State private var period: MarketPeriod = .day
    @State private var useCustomRange = false
    @State private var customWindow: BTCChartViewport?
    @State private var customDatesVisible = false
    @State private var draftFrom = Date().addingTimeInterval(-30 * 86400)
    @State private var draftThrough = Date()
    @State private var customError: String?
    @State private var hoverDate: Date?
    @State private var selectedDate: Date?
    @State private var viewport: BTCChartViewport?
    @State private var priceViewport: BTCPriceViewport?
    @State private var manualPriceScale = false
    @State private var today = Date()
    @Binding var expandedChart: Bool
    private let costColor = Color.orange

    private var minimumDuration: TimeInterval { period.nominalSeconds }
    private var lowerBound: Date { BTCChartViewport.genesis }
    private var desiredWindow: BTCChartViewport {
        viewport ?? (useCustomRange ? customWindow : nil) ?? BTCChartViewport(start: range.startDate(today: today), end: today)
    }
    private var desiredLoad: BTCChartLoad { BTCChartLoad(period: period, window: desiredWindow) }
    private var loadTaskID: BTCChartLoad {
        period.isIntraday ? desiredLoad : BTCChartLoad(period: .day, window: BTCChartViewport(start: .distantPast, end: .distantFuture))
    }
    private var window: BTCChartViewport {
        model.rejected == desiredLoad ? model.displayedWindow ?? desiredWindow : desiredWindow
    }
    private var displayPeriod: MarketPeriod {
        if model.rejected == desiredLoad, let history = model.history { return history.period.isIntraday ? history.period : .day }
        return period
    }
    private var matchingHistory: MarketHistory? {
        guard let history = model.history else { return nil }
        if model.rejected == desiredLoad { return history }
        return period.isIntraday ? (history.period == period ? history : nil) : (!history.period.isIntraday ? history : nil)
    }
    private var rangeSelection: Binding<BTCVisibleRange> {
        Binding(get: { useCustomRange ? .custom : .preset(range) }, set: { selection in
            switch selection {
            case .preset(let selected):
                range = selected; useCustomRange = false
                today = Date(); viewport = nil; resetPriceScale(); hoverDate = nil; selectedDate = nil
            case .custom:
                draftFrom = (customWindow ?? window).start
                draftThrough = (customWindow ?? window).end
                customError = nil; customDatesVisible = true
            }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { title; Spacer(); actionControls }
            BTCControlsLayout {
                controls.frame(width: 180, alignment: .leading)
                if let history = matchingHistory, let selectedDate { historicalDetails(history, date: selectedDate) }
            }
            ViewThatFits(in: .horizontal) {
                HStack { legend; Spacer(); zoomControls }
                VStack(alignment: .leading, spacing: 8) { legend; zoomControls }
            }
            if let history = matchingHistory {
                marketChart(history)
                sourceCaption(history)
                if expandedChart {
                    Text("图内捏合缩放时间；右侧价格轴拖动或捏合缩放价格，双击复位。← / → 逐根移动。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 12) {
                    if model.loading { ProgressView() }
                    Text(model.loading ? "正在读取 BTC 美元历史 K 线…" : "暂无 K 线行情")
                    Text("联网成功后显示真实开、高、低、收价格。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .task(id: loadTaskID) {
            if period.isIntraday {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await model.load(period: period, window: desiredWindow)
        }
        .onChange(of: period) { old, new in
            if new.isIntraday, !old.isIntraday, !useCustomRange { range = new.nominalSeconds >= 3600 ? .week : .day }
            else if !new.isIntraday, old.isIntraday, !useCustomRange, range == .hour || range == .day { range = .month }
            today = Date(); viewport = nil; resetPriceScale(); hoverDate = nil; selectedDate = nil
        }
    }
    private var title: some View { Text("BTC 美元 K 线").font(.headline) }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) { rangeControl; periodControl }
    }
    private var rangeControl: some View {
        HStack(spacing: 8) {
            Text("时间范围").fixedSize().frame(width: 60, alignment: .leading)
            Picker("时间范围", selection: rangeSelection) {
                ForEach(MarketRange.allCases, id: \.self) { Text($0.title).tag(BTCVisibleRange.preset($0)) }
                Text("自选日期…").tag(BTCVisibleRange.custom)
            }.labelsHidden().pickerStyle(.menu).frame(width: 112)
                .popover(isPresented: $customDatesVisible) { customDates }
        }
    }
    private var customDates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自选日期范围").font(.headline)
            if period.isIntraday {
                Text("开始").font(.caption)
                LedgerDateTimePicker(date: $draftFrom).frame(width: 290, height: 24).accessibilityLabel("开始时间")
                Text("结束").font(.caption)
                LedgerDateTimePicker(date: $draftThrough).frame(width: 290, height: 24).accessibilityLabel("结束时间")
            } else {
                DatePicker("开始", selection: $draftFrom, displayedComponents: .date)
                DatePicker("结束", selection: $draftThrough, displayedComponents: .date)
            }
            if let customError { Text(customError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("取消") { customDatesVisible = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用") { applyCustomDates() }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 322)
    }
    private func applyCustomDates() {
        var from = draftFrom, through = draftThrough
        let now = Date()
        if !period.isIntraday {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            from = calendar.startOfDay(for: from)
            if calendar.isDate(from, inSameDayAs: BTCChartViewport.genesis) { from = max(from, BTCChartViewport.genesis) }
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: through))!
            through = min(now, nextDay.addingTimeInterval(-0.001))
        }
        guard from >= BTCChartViewport.genesis, from < through, through <= now else {
            customError = "请选择 2009-01-03 至现在之间、开始早于结束的日期。"; return
        }
        if period.isIntraday, through.timeIntervalSince(from) / period.nominalSeconds > 16000 {
            customError = MarketHistoryError.rangeTooLarge.localizedDescription; return
        }
        customWindow = BTCChartViewport(start: from, end: through); useCustomRange = true
        today = now; viewport = nil; resetPriceScale(); hoverDate = nil; selectedDate = nil
        customDatesVisible = false; customError = nil
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
            Button {
                resetPriceScale(); today = Date()
                Task { await model.load(period: period, window: desiredWindow, force: true) }
            } label: {
                if model.loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.disabled(model.loading).help("刷新历史行情").accessibilityLabel("刷新 K 线")
        }
    }
    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { moveWindow(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(window.start <= lowerBound).help("较早的时间")
                .accessibilityLabel("向前移动图表时间窗")
            Button { changeZoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("放大时间细节，价格自动适配可见行情")
                .accessibilityLabel("放大 K 线")
            Button { changeZoom(2) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("缩小时间范围，价格自动适配可见行情")
                .accessibilityLabel("缩小 K 线")
            Button("重置") { today = Date(); viewport = nil; resetPriceScale(); hoverDate = nil; selectedDate = nil }
                .help("回到所选时间范围")
            Button { moveWindow(1) } label: { Image(systemName: "chevron.right") }
                .disabled(window.end >= today).help("较近的时间")
                .accessibilityLabel("向后移动图表时间窗")
        }.controlSize(.small)
    }
    private func changeZoom(_ factor: Double) {
        viewport = window.zoom(factor: factor, around: selectedDate, today: today, minimumDuration: minimumDuration, lowerBound: lowerBound)
        if !manualPriceScale { priceViewport = nil }
        hoverDate = nil
        if let selectedDate, selectedDate < window.start || selectedDate > window.end { self.selectedDate = nil }
    }
    private func freezePriceScale() {
        if priceViewport == nil, let history = matchingHistory { priceViewport = BTCPriceViewport(domain: plotData(history).yDomain) }
    }
    private func resetPriceScale() { manualPriceScale = false; priceViewport = nil }
    private func moveWindow(_ direction: Double) {
        freezePriceScale()
        viewport = window.moving(direction, today: today, lowerBound: lowerBound)
        hoverDate = nil; selectedDate = nil
    }
    private func stepWindow(_ direction: Int) {
        let previous = window
        let moved = previous.stepping(direction, period: period, today: today, lowerBound: lowerBound)
        guard moved != previous else { return }
        freezePriceScale()
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
    private func plotData(_ history: MarketHistory) -> BTCPlotData {
        plotCache.data(history: history, key: BTCPlotCacheKey(historyRevision: model.historyRevision,
            accounts: store.document.accounts, entries: store.document.entries, range: range, period: displayPeriod,
            window: window, priceWindow: priceViewport))
    }
    private func marketChart(_ history: MarketHistory) -> some View {
        let data = plotData(history)
        let snapshot = BTCChartInputSnapshot(timeWindow: data.window.start...data.window.end,
            priceDomain: data.yDomain, visibleOHLCCount: data.visibleOHLCCount,
            visibleOHLCDomain: data.visibleOHLCDomain,
            manualPriceScale: manualPriceScale)
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
                            if priceViewport == nil { priceViewport = BTCPriceViewport(domain: data.yDomain) }
                            viewport = window.panning(points: delta, plotWidth: plot.width, today: today, lowerBound: lowerBound)
                            hoverDate = nil
                            if let selectedDate, selectedDate < window.start || selectedDate > window.end { self.selectedDate = nil }
                        },
                        onMagnify: { factor, point in
                            let anchor = proxy.value(atX: point.x, as: Date.self) ?? selectedDate
                            viewport = window.zoom(factor: factor, around: anchor, today: today, minimumDuration: minimumDuration, lowerBound: lowerBound)
                            if !manualPriceScale { priceViewport = nil }
                            hoverDate = nil
                            if let selectedDate, selectedDate < window.start || selectedDate > window.end { self.selectedDate = nil }
                        },
                        onStep: { direction in stepWindow(direction) },
                        onDismissDetails: { hoverDate = nil; selectedDate = nil },
                        snapshot: snapshot
                    )
                    .frame(width: plot.width, height: plot.height)
                    .position(x: plot.midX, y: plot.midY)
                    if geometry.size.width > plot.maxX {
                        BTCChartInput(
                            onHover: { _ in }, onPan: { _ in },
                            onMagnify: { factor, point in
                                let current = priceViewport ?? BTCPriceViewport(domain: data.yDomain)
                                let anchor = current.upper - min(1, max(0, point.y / plot.height)) * current.span
                                manualPriceScale = true
                                priceViewport = current.zoom(factor: factor, around: anchor)
                            },
                            onStep: { _ in }, onDismissDetails: {},
                            area: .priceAxis,
                            onPriceDrag: { delta, _ in
                                let factor = BTCChartInputMath.priceDragFactor(points: delta, plotHeight: plot.height)
                                manualPriceScale = true
                                priceViewport = (priceViewport ?? BTCPriceViewport(domain: data.yDomain)).zoom(factor: factor, around: nil)
                            },
                            onPriceReset: { resetPriceScale() },
                            snapshot: snapshot
                        )
                        .frame(width: geometry.size.width - plot.maxX, height: plot.height)
                        .position(x: (plot.maxX + geometry.size.width) / 2, y: plot.midY)
                        .help("拖动或捏合缩放价格轴，双击恢复可见行情价格范围。")
                    }
                }
            }
        }
        .frame(minHeight: expandedChart ? 620 : 60, maxHeight: expandedChart ? 620 : .infinity)
        .help("双指左右移动；图内捏合缩放时间；右侧价格轴拖动或捏合缩放价格、双击复位。点击图后 ← / → 逐根移动。")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("BTC 美元 K 线、综合成本与购买转移事件。当前 \(displayPeriod.title)，\(data.candles.count) 根可见行情。移动鼠标后在周期选择旁查看历史状态。")
    }
    private func sourceCaption(_ history: MarketHistory) -> some View {
        Text("\(displayPeriod.isIntraday ? dateText(window.start) : dayText(window.start)) — \(displayPeriod.isIntraday ? dateText(window.end) : dayText(window.end)) · \(displayPeriod.title) · 美元 · 获取 \(dateText(history.fetchedAt))")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .help(history.source + "；灰线/灰点为参考收盘，缺失留空。")
    }
    private func historicalDetails(_ history: MarketHistory, date: Date) -> some View {
        let state = try? LedgerEngine.calculate(accounts: store.document.accounts, entries: store.document.entries, asOf: date)
        let candle = history.latestClose(asOf: date)
        let price = candle?.close
        let totals = BTCDailyChartTotals(entries: store.document.entries, through: date)
        return VStack(alignment: .leading, spacing: 4) {
            Text("截止 \(dateText(date)) · \(candle.map { "\($0.hasOHLC ? (history.period.isIntraday ? "美元行情" : "美元日行情") : "参考收盘（非 OHLC）") \(dateText($0.closeDate))\($0.isComplete ? "" : "（行情未完整）")" } ?? "暂无此前行情")")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 4) {
                metricCell("BTC 市价", Display.money(price))
                metricCell("综合成本", Display.money(state?.averageCostUSD))
                metricCell("总持有 BTC", state.map { Display.btc($0.totalSats) } ?? "—")
                metricCell("累计投入美元", Display.money(state?.totalInvestedUSD))
                metricCell("累计损耗 BTC", state.map { Display.btc($0.totalLossSats) } ?? "—")
                metricCell("盈亏金额", Display.money(price.flatMap { state?.profit(price: $0) }))
                metricCell("盈亏率", Display.percent(price.flatMap { state?.profitRatio(price: $0) }))
            }
            if totals.purchaseCount > 0 {
                Text("当天购买：\(Display.money(totals.investedUSD)) → \(btcText(totals.purchasedBTC)) BTC")
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
