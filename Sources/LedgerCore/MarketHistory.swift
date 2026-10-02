import Foundation

public enum MarketRange: String, Codable, CaseIterable, Sendable {
    case week, month, quarter, halfYear, year, threeYears, all
    public static let genesisDate = Date(timeIntervalSince1970: 1_230_940_800)
    public var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .halfYear: 180
        case .year: 365
        case .threeYears: 1095
        case .all: max(1, Int(Date().timeIntervalSince(Self.genesisDate) / 86_400) + 1)
        }
    }
    public var title: String {
        switch self {
        case .week: "7 天"
        case .month: "30 天"
        case .quarter: "90 天"
        case .halfYear: "180 天"
        case .year: "1 年"
        case .threeYears: "3 年"
        case .all: "全部"
        }
    }
    public func startDate(today: Date = Date()) -> Date {
        if self == .all { return Self.genesisDate }
        if self == .threeYears {
            return MarketHistory.utcCalendar.date(byAdding: .year, value: -3, to: today) ?? today.addingTimeInterval(-Double(days) * 86_400)
        }
        return today.addingTimeInterval(-Double(days) * 86_400)
    }
}

public enum MarketPeriod: String, Codable, CaseIterable, Sendable {
    case day, week, month
    public var title: String {
        switch self { case .day: "日 K"; case .week: "周 K"; case .month: "月 K" }
    }
}

/// A candle records only the span observed by its provider. OHLC market bars
/// and daily reference prices remain distinct throughout storage and rendering.
public struct MarketCandle: Codable, Equatable, Identifiable, Sendable {
    public let closeDate: Date
    public let interval: TimeInterval
    public let open: Decimal
    public let high: Decimal
    public let low: Decimal
    public let close: Decimal
    /// False for genuine daily reference prices which provide no OHLC data.
    public let hasOHLC: Bool
    /// An ongoing day ends at fetchedAt, never at a future midnight.
    public let isComplete: Bool
    public let missingDays: Int
    public var id: Date { closeDate }
    public var startDate: Date { closeDate.addingTimeInterval(-interval) }
    public var centerDate: Date { closeDate.addingTimeInterval(-interval / 2) }

    public init(closeDate: Date, interval: TimeInterval, open: Decimal, high: Decimal, low: Decimal, close: Decimal,
                hasOHLC: Bool = true, isComplete: Bool = true, missingDays: Int = 0) {
        self.closeDate = closeDate; self.interval = interval
        self.open = open; self.high = high; self.low = low; self.close = close
        self.hasOHLC = hasOHLC; self.isComplete = isComplete; self.missingDays = missingDays
    }
    private enum CodingKeys: String, CodingKey {
        case closeDate, interval, open, high, low, close, hasOHLC, isComplete, missingDays
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        closeDate = try values.decode(Date.self, forKey: .closeDate)
        interval = try values.decode(TimeInterval.self, forKey: .interval)
        open = try values.decode(Decimal.self, forKey: .open)
        high = try values.decode(Decimal.self, forKey: .high)
        low = try values.decode(Decimal.self, forKey: .low)
        close = try values.decode(Decimal.self, forKey: .close)
        hasOHLC = try values.decodeIfPresent(Bool.self, forKey: .hasOHLC) ?? true
        isComplete = try values.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
        missingDays = try values.decodeIfPresent(Int.self, forKey: .missingDays) ?? 0
    }
}

public struct MarketHistory: Codable, Equatable, Sendable {
    public let range: MarketRange
    public let fetchedAt: Date
    public let candles: [MarketCandle]
    public let source: String
    public let isReferenceCNY: Bool
    public let warning: String?
    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }
    public init(range: MarketRange, fetchedAt: Date = Date(), candles: [MarketCandle],
                source: String = "BTC 人民币日行情", isReferenceCNY: Bool = false, warning: String? = nil) {
        self.range = range; self.fetchedAt = fetchedAt; self.candles = candles
        self.source = source; self.isReferenceCNY = isReferenceCNY
        self.warning = warning
    }
    private enum CodingKeys: String, CodingKey { case range, fetchedAt, candles, source, isReferenceCNY, warning }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        range = try values.decode(MarketRange.self, forKey: .range)
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        candles = try values.decode([MarketCandle].self, forKey: .candles)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? "BTC 人民币日行情"
        isReferenceCNY = try values.decodeIfPresent(Bool.self, forKey: .isReferenceCNY) ?? false
        warning = try values.decodeIfPresent(String.self, forKey: .warning)
    }
    /// A hover must never borrow the close price from a candle that ends in its future.
    public func latestClose(asOf date: Date) -> MarketCandle? {
        candles.last { $0.closeDate <= date }
    }

    /// Aggregate observations using UTC market days and Monday-based weeks.
    /// Missing days remain absent. A close-only or incomplete bucket must never
    /// be presented as a complete OHLC candle.
    public func aggregatedCandles(period: MarketPeriod, from start: Date? = nil, through end: Date? = nil) -> [MarketCandle] {
        let calendar = Self.utcCalendar
        let cutoff = min(end ?? fetchedAt, fetchedAt)
        let observed = candles.filter { $0.closeDate <= cutoff }.sorted { $0.startDate < $1.startDate }
        guard !observed.isEmpty else { return [] }
        if period == .day {
            return observed.filter { candle in start == nil || candle.closeDate >= start! }
        }
        let component: Calendar.Component = period == .week ? .weekOfYear : .month
        let grouped = Dictionary(grouping: observed) { candle in
            calendar.dateInterval(of: component, for: candle.startDate)!.start
        }
        return grouped.keys.sorted().compactMap { boundary in
            guard let values = grouped[boundary], let first = values.first, let last = values.last,
                  start == nil || last.closeDate >= start! else { return nil }
            let nominalEnd = calendar.dateInterval(of: component, for: boundary)!.end
            let expectedStart = max(boundary, observed[0].startDate)
            let cutoffDay = calendar.startOfDay(for: cutoff)
            let observedDayEnd = cutoff == cutoffDay ? cutoffDay : cutoffDay.addingTimeInterval(86_400)
            let expectedEnd = min(nominalEnd, observedDayEnd)
            let expectedDays = max(1, Int(ceil(expectedEnd.timeIntervalSince(expectedStart) / 86_400)))
            let availableDays = Set(values.map { calendar.startOfDay(for: $0.startDate) }).count
            let missing = max(0, expectedDays - availableDays)
            let hasOHLC = values.allSatisfy(\.hasOHLC)
            return MarketCandle(closeDate: last.closeDate, interval: last.closeDate.timeIntervalSince(first.startDate),
                open: hasOHLC ? first.open : last.close,
                high: hasOHLC ? values.map(\.high).max()! : last.close,
                low: hasOHLC ? values.map(\.low).min()! : last.close,
                close: last.close, hasOHLC: hasOHLC,
                isComplete: last.closeDate >= nominalEnd && values.allSatisfy(\.isComplete) && missing == 0,
                missingDays: missing)
        }
    }
}

public enum MarketHistoryError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case emptyHistory
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "K 线数据无效，已保留上次成功行情。"
        case .httpStatus(let status): status == 429
            ? "行情请求受限，请稍后手动刷新；已保留上次成功行情。"
            : "K 线服务暂不可用（HTTP \(status)），已保留上次成功行情。"
        case .emptyHistory: "行情服务没有返回 K 线，已保留上次成功行情。"
        }
    }
}

/// Public read-only daily market requests contain only a fixed asset and public
/// time bounds. Account names, amounts and ledger events never leave the Mac.
public struct MarketHistoryClient: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 20
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }
    public static func yahooEndpoint(through date: Date = Date()) -> URL {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/BTC-CNY")!
        components.queryItems = [URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "period1", value: "0"),
            URLQueryItem(name: "period2", value: String(Int64(date.timeIntervalSince1970) + 1))]
        return components.url!
    }
    public func fetch(range: MarketRange) async throws -> MarketHistory {
        let fetchedAt = Date()
        let daily = try await fetchDaily(through: fetchedAt)
        do {
            let early = try await EarlyMarketHistoryClient(session: session).fetch(cutoff: fetchedAt)
            return try Self.combine(early: early, daily: daily)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return MarketHistory(range: daily.range, fetchedAt: daily.fetchedAt, candles: daily.candles,
                source: daily.source, isReferenceCNY: daily.isReferenceCNY,
                warning: "早期参考历史暂不可用：\(error.localizedDescription)")
        }
    }
    public func fetchDaily(through date: Date = Date()) async throws -> MarketHistory {
        var request = URLRequest(url: Self.yahooEndpoint(through: date))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MarketHistoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw MarketHistoryError.httpStatus(http.statusCode) }
        return try Self.decodeYahoo(data: data, fetchedAt: date)
    }

    /// The Yahoo daily timestamp labels the day's start. Completed closes are
    /// available at the next UTC midnight; today's changing bar is observable
    /// only at fetchedAt. A null OHLC row is a gap, never a zero-price candle.
    public static func decodeYahoo(data: Data, fetchedAt: Date = Date()) throws -> MarketHistory {
        guard data.count <= 8_000_000, fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MarketHistoryError.invalidResponse
        }
        let envelope: YahooEnvelope
        do { envelope = try JSONDecoder().decode(YahooEnvelope.self, from: data) }
        catch { throw MarketHistoryError.invalidResponse }
        guard envelope.chart.error == nil, let result = envelope.chart.result?.first,
              envelope.chart.result?.count == 1, result.meta.currency == "CNY",
              result.timestamp.count <= 12_000,
              let quote = result.indicators.quote.first,
              [quote.open.count, quote.high.count, quote.low.count, quote.close.count].allSatisfy({ $0 == result.timestamp.count }) else {
            throw MarketHistoryError.invalidResponse
        }
        var seen = Set<Int64>()
        var candles: [MarketCandle] = []
        for (index, timestamp) in result.timestamp.enumerated() {
            guard timestamp > 0, timestamp % 86_400 == 0, seen.insert(timestamp).inserted else {
                throw MarketHistoryError.invalidResponse
            }
            let start = Date(timeIntervalSince1970: Double(timestamp))
            guard start <= fetchedAt else { throw MarketHistoryError.invalidResponse }
            guard let close = quote.close[index] else { continue }
            guard close > 0, close <= Amounts.maximumPrice else { throw MarketHistoryError.invalidResponse }
            let dailyEnd = start.addingTimeInterval(86_400)
            let complete = dailyEnd <= fetchedAt
            let observationEnd = min(dailyEnd, fetchedAt)
            // A request exactly at midnight can return an unstarted live bar.
            guard observationEnd > start else { continue }
            let candle: MarketCandle
            if let open = quote.open[index], let high = quote.high[index], let low = quote.low[index] {
                guard [open, high, low].allSatisfy({ $0 > 0 && $0 <= Amounts.maximumPrice }) else {
                    throw MarketHistoryError.invalidResponse
                }
                let raw = MarketCandle(closeDate: observationEnd, interval: observationEnd.timeIntervalSince(start),
                    open: open, high: high, low: low, close: close, isComplete: complete)
                // Some published CNY rows have converted highs/lows outside
                // their open/close bounds. Preserve the genuine close, but do
                // not repair the provider's extrema or fabricate a K candle.
                candle = valid(raw) ? raw : MarketCandle(closeDate: observationEnd,
                    interval: observationEnd.timeIntervalSince(start), open: close, high: close, low: close,
                    close: close, hasOHLC: false, isComplete: complete)
            } else {
                candle = MarketCandle(closeDate: observationEnd, interval: observationEnd.timeIntervalSince(start),
                    open: close, high: close, low: close, close: close, hasOHLC: false, isComplete: complete)
            }
            candles.append(candle)
        }
        guard !candles.isEmpty else { throw MarketHistoryError.emptyHistory }
        let hasReference = candles.contains { !$0.hasOHLC }
        return MarketHistory(range: .all, fetchedAt: fetchedAt,
            candles: candles.sorted { $0.startDate < $1.startDate },
            source: hasReference
                ? "Yahoo Finance · BTC-CNY 日行情；OHLC 缺失或不一致的日期仅显示真实收盘参考线"
                : "Yahoo Finance · BTC-CNY 日行情", isReferenceCNY: hasReference)
    }

    /// Exact daily OHLC takes precedence over an early or missing-day reference.
    /// Every retained point has a real source; missing days stay absent.
    public static func combine(early: [MarketCandle], daily: MarketHistory) throws -> MarketHistory {
        var byDay: [Date: MarketCandle] = [:]
        for candle in early + daily.candles {
            guard valid(candle), candle.closeDate <= daily.fetchedAt else { throw MarketHistoryError.invalidResponse }
            let day = MarketHistory.utcCalendar.startOfDay(for: candle.startDate)
            if let existing = byDay[day], existing.hasOHLC && !candle.hasOHLC { continue }
            byDay[day] = candle
        }
        let hasReference = byDay.values.contains { !$0.hasOHLC }
        return MarketHistory(range: .all, fetchedAt: daily.fetchedAt,
            candles: byDay.values.sorted { $0.startDate < $1.startDate },
            source: hasReference
                ? "Yahoo Finance BTC-CNY 日 K / 真实收盘参考；早期 / 缺日为 CoinMetrics × ECB 历史汇率的每日人民币参考线"
                : daily.source,
            isReferenceCNY: hasReference, warning: daily.warning)
    }
    public static func valid(_ candle: MarketCandle) -> Bool {
        let prices = [candle.open, candle.high, candle.low, candle.close]
        return candle.closeDate.timeIntervalSinceReferenceDate.isFinite
            && candle.interval > 0 && candle.interval.isFinite
            && candle.missingDays >= 0
            && prices.allSatisfy { $0 > 0 && $0 <= Decimal(1_000_000_000_000 as Int64) }
            && candle.low <= min(candle.open, candle.close)
            && candle.high >= max(candle.open, candle.close)
            && candle.high >= candle.low
            && (candle.hasOHLC || (candle.open == candle.close && candle.high == candle.close && candle.low == candle.close))
    }
}

private struct YahooEnvelope: Decodable {
    let chart: YahooChart
}
private struct YahooChart: Decodable {
    let result: [YahooResult]?
    let error: YahooError?
}
private struct YahooError: Decodable {
    let code: String?
    let description: String?
}
private struct YahooResult: Decodable {
    struct Meta: Decodable { let currency: String }
    struct Indicators: Decodable { let quote: [YahooQuote] }
    let meta: Meta
    let timestamp: [Int64]
    let indicators: Indicators
}
private struct YahooQuote: Decodable {
    let open: [Decimal?]
    let high: [Decimal?]
    let low: [Decimal?]
    let close: [Decimal?]
}

public struct CostChartPoint: Equatable, Identifiable, Sendable {
    public let id: Int
    public let date: Date
    public let costCNY: Decimal
    public let segment: Int
}

public struct LedgerChartEvent: Equatable, Identifiable, Sendable {
    public let entry: LedgerEntry
    /// Position only; this is never presented as an event's market price.
    public let markerPriceCNY: Decimal
    public var id: UUID { entry.id }
}

public enum LedgerChartHistory {
    public static func events(accounts: [Account], entries: [LedgerEntry], history: MarketHistory,
                              from start: Date, through end: Date) throws -> [LedgerChartEvent] {
        guard let fallback = history.candles.first?.low else { return [] }
        let snapshots = try LedgerEngine.history(accounts: accounts, entries: entries)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var priorCost: Decimal?
        var result: [LedgerChartEvent] = []
        for point in snapshots {
            defer { priorCost = point.snapshot.averageCostCNY }
            guard point.date >= start, point.date <= end, let entry = byID[point.entryID] else { continue }
            let position = point.snapshot.averageCostCNY ?? priorCost
                ?? history.latestClose(asOf: point.date)?.close ?? fallback
            result.append(LedgerChartEvent(entry: entry, markerPriceCNY: position))
        }
        return result
    }
    /// Every event contributes a before/after pair at the same instant. This
    /// draws a true staircase, including multiple purchases/transfers in a day.
    /// A zero holding splits the line instead of drawing across an undefined cost.
    public static func costPoints(accounts: [Account], entries: [LedgerEntry], from start: Date, through end: Date) throws -> [CostChartPoint] {
        guard start <= end else { return [] }
        var prior = try LedgerEngine.calculate(accounts: accounts, entries: entries, asOf: start)
        let events = try LedgerEngine.history(accounts: accounts, entries: entries)
            .filter { $0.date > start && $0.date <= end }
        var result: [CostChartPoint] = []
        var segment = 0
        func add(_ date: Date, _ cost: Decimal?) {
            if let cost { result.append(CostChartPoint(id: result.count, date: date, costCNY: cost, segment: segment)) }
        }
        add(start, prior.averageCostCNY)
        for event in events {
            add(event.date, prior.averageCostCNY)
            if prior.averageCostCNY == nil { segment += 1 }
            add(event.date, event.snapshot.averageCostCNY)
            prior = event.snapshot
        }
        add(end, prior.averageCostCNY)
        return result
    }
}
