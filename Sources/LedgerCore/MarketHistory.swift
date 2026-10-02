import Foundation

public enum MarketRange: String, Codable, CaseIterable, Sendable {
    case hour, day, week, month, quarter, halfYear, year, threeYears, all
    public static let genesisDate = Date(timeIntervalSince1970: 1_230_940_800)
    public var days: Int {
        switch self {
        case .hour, .day: 1
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
        case .hour: "1 小时"
        case .day: "1 天"
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
        if self == .hour { return today.addingTimeInterval(-3_600) }
        if self == .all { return Self.genesisDate }
        if self == .threeYears {
            return MarketHistory.utcCalendar.date(byAdding: .year, value: -3, to: today) ?? today.addingTimeInterval(-Double(days) * 86_400)
        }
        return today.addingTimeInterval(-Double(days) * 86_400)
    }
}

public enum MarketPeriod: String, Codable, CaseIterable, Sendable {
    case minute, minute3, minute5, minute15, minute30
    case hour, hour2, hour4, hour6, hour8, hour12
    case day, day3, week, month, quarter, year
    public var title: String {
        switch self {
        case .minute: "1 分钟"
        case .minute3: "3 分钟"
        case .minute5: "5 分钟"
        case .minute15: "15 分钟"
        case .minute30: "30 分钟"
        case .hour: "1 小时"
        case .hour2: "2 小时"
        case .hour4: "4 小时"
        case .hour6: "6 小时"
        case .hour8: "8 小时"
        case .hour12: "12 小时"
        case .day: "日 K"
        case .day3: "3 日"
        case .week: "周 K"
        case .month: "月 K"
        case .quarter: "3 月"
        case .year: "年 K"
        }
    }
    public var isIntraday: Bool { nominalSeconds < 86_400 }
    /// Calendar periods use nominal durations only for ordering and display.
    /// Actual month/quarter/year boundaries always use the UTC calendar.
    public var nominalSeconds: TimeInterval {
        switch self {
        case .minute: 60
        case .minute3: 180
        case .minute5: 300
        case .minute15: 900
        case .minute30: 1800
        case .hour: 3600
        case .hour2: 7200
        case .hour4: 14_400
        case .hour6: 21_600
        case .hour8: 28_800
        case .hour12: 43_200
        case .day: 86_400
        case .day3: 259_200
        case .week: 604_800
        case .month: 2_592_000
        case .quarter: 7_776_000
        case .year: 31_536_000
        }
    }
    func bucket(containing date: Date) -> DateInterval {
        let calendar = MarketHistory.utcCalendar
        switch self {
        case .week: return calendar.dateInterval(of: .weekOfYear, for: date)!
        case .month: return calendar.dateInterval(of: .month, for: date)!
        case .quarter:
            let parts = calendar.dateComponents([.year, .month], from: date)
            let firstMonth = (parts.month! - 1) / 3 * 3 + 1
            let start = calendar.date(from: DateComponents(year: parts.year, month: firstMonth, day: 1))!
            return DateInterval(start: start, end: calendar.date(byAdding: .month, value: 3, to: start)!)
        case .year: return calendar.dateInterval(of: .year, for: date)!
        default:
            let start = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / nominalSeconds) * nominalSeconds)
            return DateInterval(start: start, duration: nominalSeconds)
        }
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
    /// False for genuine source observations without usable OHLC data.
    public let hasOHLC: Bool
    /// An ongoing bar ends at fetchedAt, never at a future boundary.
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
    public let period: MarketPeriod
    public let fetchedAt: Date
    public let candles: [MarketCandle]
    public let source: String
    public let warning: String?
    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }
    public init(range: MarketRange, period: MarketPeriod = .day, fetchedAt: Date = Date(), candles: [MarketCandle],
                source: String = "BTC 美元日行情", warning: String? = nil) {
        self.range = range; self.period = period; self.fetchedAt = fetchedAt; self.candles = candles
        self.source = source
        self.warning = warning
    }
    private enum CodingKeys: String, CodingKey { case range, period, fetchedAt, candles, source, warning }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        range = try values.decode(MarketRange.self, forKey: .range)
        period = try values.decodeIfPresent(MarketPeriod.self, forKey: .period) ?? .day
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        candles = try values.decode([MarketCandle].self, forKey: .candles)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? "BTC 美元日行情"
        warning = try values.decodeIfPresent(String.self, forKey: .warning)
    }
    /// A hover must never borrow the close price from a candle that ends in its future.
    public func latestClose(asOf date: Date) -> MarketCandle? {
        candles.last { $0.closeDate <= date }
    }

    /// Aggregate real source bars on UTC boundaries. Missing bars and reference
    /// observations cannot become complete OHLC. Coarser data is never split.
    public func aggregatedCandles(period: MarketPeriod, from start: Date? = nil, through end: Date? = nil) -> [MarketCandle] {
        let cutoff = min(end ?? fetchedAt, fetchedAt)
        let observed = candles.filter { $0.closeDate <= cutoff }.sorted { $0.startDate < $1.startDate }
        guard !observed.isEmpty else { return [] }
        if period == self.period {
            return observed.filter { start == nil || $0.closeDate >= start! }.map { candle in
                guard !candle.hasOHLC else { return candle }
                return MarketCandle(closeDate: candle.closeDate, interval: candle.interval,
                    open: candle.open, high: candle.high, low: candle.low, close: candle.close,
                    hasOHLC: false, isComplete: false, missingDays: candle.missingDays)
            }
        }
        guard self.period.isIntraday || self.period == .day,
              period.nominalSeconds >= self.period.nominalSeconds else { return [] }
        if period.isIntraday {
            guard self.period.isIntraday,
                  period.nominalSeconds.truncatingRemainder(dividingBy: self.period.nominalSeconds) == 0 else { return [] }
        }
        let grouped = Dictionary(grouping: observed) { period.bucket(containing: $0.startDate).start }
        return grouped.keys.sorted().compactMap { boundary in
            guard let values = grouped[boundary], let first = values.first, let last = values.last,
                  start == nil || last.closeDate >= start! else { return nil }
            let nominalEnd = period.bucket(containing: boundary).end
            let expectedCount = max(1, Int(ceil(min(nominalEnd, cutoff).timeIntervalSince(boundary) / self.period.nominalSeconds)))
            let available = Set(values.map(\.startDate)).count
            let missing = max(0, expectedCount - available)
            let continuous = first.startDate == boundary && zip(values, values.dropFirst()).allSatisfy { $0.closeDate == $1.startDate }
            let hasOHLC = missing == 0 && continuous && available == values.count && values.allSatisfy { $0.hasOHLC && $0.closeDate <= nominalEnd }
            return MarketCandle(closeDate: last.closeDate, interval: last.closeDate.timeIntervalSince(first.startDate),
                open: hasOHLC ? first.open : last.close,
                high: hasOHLC ? values.map(\.high).max()! : last.close,
                low: hasOHLC ? values.map(\.low).min()! : last.close,
                close: last.close, hasOHLC: hasOHLC,
                isComplete: hasOHLC && last.closeDate == nominalEnd && values.allSatisfy(\.isComplete),
                missingDays: self.period == .day ? missing : 0)
        }
    }
}

public enum MarketHistoryError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case emptyHistory
    case invalidRange
    case rangeTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "K 线数据无效，已保留上次成功行情。"
        case .httpStatus(let status): status == 429
            ? "行情请求受限，请稍后手动刷新；已保留上次成功行情。"
            : "K 线服务暂不可用（HTTP \(status)），已保留上次成功行情。"
        case .emptyHistory: "行情服务没有返回 K 线，已保留上次成功行情。"
        case .invalidRange: "请选择有效的历史日期范围；结束日期不能晚于现在。"
        case .rangeTooLarge: "所选日期范围与 K 线周期的数据量过大，请缩短日期范围或选择更长的周期。"
        }
    }
}

/// Public read-only market requests contain only a fixed asset and public
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
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/BTC-USD")!
        components.queryItems = [URLQueryItem(name: "interval", value: "1d"),
            URLQueryItem(name: "period1", value: "0"),
            URLQueryItem(name: "period2", value: String(Int64(date.timeIntervalSince1970) + 1))]
        return components.url!
    }
    public static func yahooMinutesEndpoint(through date: Date = Date()) -> URL {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/BTC-USD")!
        let end = Int64(date.timeIntervalSince1970)
        components.queryItems = [URLQueryItem(name: "interval", value: "1m"),
            URLQueryItem(name: "period1", value: String(end / 60 * 60 - 7 * 86_400)),
            URLQueryItem(name: "period2", value: String(end + 1))]
        return components.url!
    }

    /// Use genuine USD minute bars.
    /// Coinbase fills only absent/incomplete OHLC; no interpolation or daily
    /// candle splitting is involved. A provider failure stops its requests.
    public func fetchMinutes() async throws -> MarketHistory {
        let requestedAt = Date()
        var usd: [Date: MarketCandle] = [:]
        var usedYahoo = false
        var usedCoinbase = false
        var sourceError: Error?
        do {
            let data = try await marketData(url: Self.yahooMinutesEndpoint(through: requestedAt), maximumBytes: 4_000_000)
            let yahoo = try Self.decodeYahooMinutes(data: data, fetchedAt: Date())
            usd = Dictionary(uniqueKeysWithValues: yahoo.candles.map { ($0.startDate, $0) })
            usedYahoo = true
        } catch {
            try Self.propagateCancellation(error)
            sourceError = error
        }
        // This cutoff fixes the expected seven-day window for the bounded
        // repair pass. Each USD observation still retains its own close time.
        let fetchedAt = Date()
        let end = Self.minuteBoundary(fetchedAt)
        let start = end.addingTimeInterval(-7 * 86_400)
        usd = usd.filter { $0.key >= start && $0.key < fetchedAt }
        let missing = try Self.missingMinutes(candles: Array(usd.values), from: start, through: end)
        let pages = Self.coinbaseRepairPages(missing: missing, from: start, through: end)
        for (index, page) in pages.enumerated() {
            // Serial requests stay below the public Exchange API's 10 rps
            // allowance, including a full 34-page Yahoo outage fallback.
            if index > 0 { try await Task.sleep(for: .milliseconds(500)) }
            do {
                let data = try await marketData(url: Self.coinbaseEndpoint(from: page.start, through: page.end),
                                                maximumBytes: 4_000_000)
                let candles = try Self.decodeCoinbase(data: data, from: page.start, through: page.end,
                                                             fetchedAt: fetchedAt)
                for candle in candles {
                    if let existing = usd[candle.startDate], existing.hasOHLC && existing.isComplete { continue }
                    usd[candle.startDate] = candle
                    usedCoinbase = true
                }
            } catch {
                try Self.propagateCancellation(error)
                sourceError = error
                break
            }
        }
        try Task.checkCancellation()
        guard !usd.isEmpty else { throw sourceError ?? MarketHistoryError.emptyHistory }
        let providers = usedYahoo ? (usedCoinbase ? "Yahoo Finance / Coinbase" : "Yahoo Finance") : "Coinbase"
        return try Self.minuteHistory(usd: Array(usd.values), from: start, fetchedAt: fetchedAt,
            source: "\(providers) · BTC-USD 真实 1 分钟行情（美元）")
    }

    /// Fetch the selected historical window using Coinbase's largest native
    /// interval that divides the requested period. All limits are checked
    /// before requests; the user's period and dates are never silently changed.
    public func fetchIntraday(period: MarketPeriod, from start: Date, through end: Date) async throws -> MarketHistory {
        let fetchedAt = Date()
        let plan = try Self.intradayPlan(period: period, from: start, through: end, now: fetchedAt)
        let pages = Self.coinbasePages(from: plan.start, through: plan.end, granularity: plan.granularity)
        var usd: [MarketCandle] = []
        var sourceError: Error?
        for (index, page) in pages.enumerated() {
            if index > 0 { try await Task.sleep(for: .milliseconds(500)) }
            do {
                let data = try await marketData(url: Self.coinbaseEndpoint(from: page.start, through: page.end,
                                                                           granularity: plan.granularity), maximumBytes: 4_000_000)
                usd += try Self.decodeCoinbase(data: data, from: page.start, through: page.end,
                                              fetchedAt: fetchedAt, granularity: plan.granularity)
            } catch {
                try Self.propagateCancellation(error)
                sourceError = error
                break
            }
        }
        try Task.checkCancellation()
        guard !usd.isEmpty else { throw sourceError ?? MarketHistoryError.emptyHistory }
        let source = "Coinbase · BTC-USD 真实行情（美元）"
        let native = MarketHistory(range: .all, period: Self.nativePeriod(granularity: plan.granularity),
                                   fetchedAt: fetchedAt, candles: usd, source: source)
        let candles = native.aggregatedCandles(period: period, through: plan.end)
        guard !candles.isEmpty else { throw MarketHistoryError.emptyHistory }
        guard candles.count <= 16_000 else { throw MarketHistoryError.rangeTooLarge }
        let available = usd.filter { $0.isComplete && $0.hasOHLC }.count
        let missing = max(0, plan.nativeCount - available)
        return MarketHistory(range: .all, period: period, fetchedAt: fetchedAt, candles: candles,
            source: source,
            warning: missing > 0 ? "所选范围有 \(missing) 个 \(Self.nativePeriod(granularity: plan.granularity).title)来源时段缺少完整行情；缺口保留，不进行补造。" : nil)
    }
    public func fetch(range: MarketRange) async throws -> MarketHistory {
        let fetchedAt = Date()
        let daily = try await fetchDaily(through: fetchedAt)
        do {
            let early = try await EarlyMarketHistoryClient(session: session).fetch(cutoff: fetchedAt)
            return try Self.combine(early: early, daily: daily)
        } catch {
            try Self.propagateCancellation(error)
            return MarketHistory(range: daily.range, fetchedAt: daily.fetchedAt, candles: daily.candles,
                source: daily.source,
                warning: "早期参考历史暂不可用：\(error.localizedDescription)")
        }
    }
    public func fetchDaily(through date: Date = Date()) async throws -> MarketHistory {
        let data = try await marketData(url: Self.yahooEndpoint(through: date))
        return try Self.decodeYahoo(data: data, fetchedAt: date)
    }
    private func marketData(url: URL, maximumBytes: Int = 8_000_000) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MarketHistoryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw MarketHistoryError.httpStatus(http.statusCode) }
        guard data.count <= maximumBytes else { throw MarketHistoryError.invalidResponse }
        return data
    }

    private static func propagateCancellation(_ error: Error) throws {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
    }

    /// Minute timestamps label actual UTC minute starts. A trailing off-grid
    /// live quote is not a candle; missing bars remain absent. The current
    /// minute's changing close becomes available only at fetchedAt.
    public static func decodeYahooMinutes(data: Data, fetchedAt: Date = Date()) throws -> MarketHistory {
        let result = try yahooResult(data: data, fetchedAt: fetchedAt, maximumBytes: 4_000_000,
                                     maximumRows: 16_000)
        guard result.meta.dataGranularity == "1m" else { throw MarketHistoryError.invalidResponse }
        var seen = Set<Int64>()
        var candles: [MarketCandle] = []
        let quote = result.indicators.quote[0]
        for (index, timestamp) in result.timestamp.enumerated() {
            guard timestamp > 0 else { throw MarketHistoryError.invalidResponse }
            if timestamp % 60 != 0 {
                guard index == result.timestamp.count - 1 else { throw MarketHistoryError.invalidResponse }
                continue
            }
            guard seen.insert(timestamp).inserted else { throw MarketHistoryError.invalidResponse }
            let start = Date(timeIntervalSince1970: Double(timestamp))
            guard start <= fetchedAt else { throw MarketHistoryError.invalidResponse }
            if let candle = try yahooCandle(quote: quote, index: index, start: start, duration: 60, fetchedAt: fetchedAt) {
                candles.append(candle)
            }
        }
        guard !candles.isEmpty else { throw MarketHistoryError.emptyHistory }
        let hasReference = candles.contains { !$0.hasOHLC }
        return MarketHistory(range: .week, period: .minute, fetchedAt: fetchedAt,
            candles: candles.sorted { $0.startDate < $1.startDate },
            source: hasReference
                ? "Yahoo Finance · BTC-USD 1 分钟行情（最近 7 天）；OHLC 缺失或不一致仅显示真实收盘参考"
                : "Yahoo Finance · BTC-USD 1 分钟行情（最近 7 天，缺失分钟留空）")
    }

    /// The Yahoo daily timestamp labels the day's start. Completed closes are
    /// available at the next UTC midnight; today's changing bar is observable
    /// only at fetchedAt. A null OHLC row is a gap, never a zero-price candle.
    public static func decodeYahoo(data: Data, fetchedAt: Date = Date()) throws -> MarketHistory {
        let result = try yahooResult(data: data, fetchedAt: fetchedAt, maximumBytes: 8_000_000, maximumRows: 12_000)
        let quote = result.indicators.quote[0]
        var seen = Set<Int64>()
        var candles: [MarketCandle] = []
        for (index, timestamp) in result.timestamp.enumerated() {
            guard timestamp > 0, timestamp % 86_400 == 0, seen.insert(timestamp).inserted else {
                throw MarketHistoryError.invalidResponse
            }
            let start = Date(timeIntervalSince1970: Double(timestamp))
            guard start <= fetchedAt else { throw MarketHistoryError.invalidResponse }
            if let candle = try yahooCandle(quote: quote, index: index, start: start, duration: 86_400, fetchedAt: fetchedAt) {
                candles.append(candle)
            }
        }
        guard !candles.isEmpty else { throw MarketHistoryError.emptyHistory }
        let hasReference = candles.contains { !$0.hasOHLC }
        return MarketHistory(range: .all, fetchedAt: fetchedAt,
            candles: candles.sorted { $0.startDate < $1.startDate },
            source: hasReference
                ? "Yahoo Finance · BTC-USD 日行情；OHLC 缺失或不一致的日期仅显示真实收盘参考线"
                : "Yahoo Finance · BTC-USD 日行情")
    }

    private static func yahooResult(data: Data, fetchedAt: Date, maximumBytes: Int, maximumRows: Int) throws -> YahooResult {
        guard data.count <= maximumBytes, fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MarketHistoryError.invalidResponse
        }
        let envelope: YahooEnvelope
        do { envelope = try JSONDecoder().decode(YahooEnvelope.self, from: data) }
        catch { throw MarketHistoryError.invalidResponse }
        guard envelope.chart.error == nil, let result = envelope.chart.result?.first,
              envelope.chart.result?.count == 1, result.meta.currency == "USD",
              result.timestamp.count <= maximumRows, let quote = result.indicators.quote.first,
              [quote.open.count, quote.high.count, quote.low.count, quote.close.count].allSatisfy({ $0 == result.timestamp.count }) else {
            throw MarketHistoryError.invalidResponse
        }
        return result
    }

    private static func yahooCandle(quote: YahooQuote, index: Int, start: Date,
                                    duration: TimeInterval, fetchedAt: Date) throws -> MarketCandle? {
        guard let close = quote.close[index] else { return nil }
        guard close > 0, close <= Amounts.maximumPrice else { throw MarketHistoryError.invalidResponse }
        let nominalEnd = start.addingTimeInterval(duration)
        let observationEnd = min(nominalEnd, fetchedAt)
        guard observationEnd > start else { return nil }
        let complete = nominalEnd <= fetchedAt
        if let open = quote.open[index], let high = quote.high[index], let low = quote.low[index] {
            guard [open, high, low].allSatisfy({ $0 > 0 && $0 <= Amounts.maximumPrice }) else {
                throw MarketHistoryError.invalidResponse
            }
            let raw = MarketCandle(closeDate: observationEnd, interval: observationEnd.timeIntervalSince(start),
                open: open, high: high, low: low, close: close, isComplete: complete)
            // Retain the genuine close without repairing a provider's extrema.
            if valid(raw) { return raw }
        }
        return MarketCandle(closeDate: observationEnd, interval: observationEnd.timeIntervalSince(start),
            open: close, high: close, low: close, close: close, hasOHLC: false, isComplete: complete)
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
                ? "Yahoo Finance BTC-USD 日 K / 真实收盘参考；早期 / 缺日为 CoinMetrics PriceUSD 的每日美元收盘参考线"
                : daily.source,
            warning: daily.warning)
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

extension MarketHistoryClient {
    struct CandlePage: Equatable, Sendable {
        let start: Date
        let end: Date
    }
    struct IntradayPlan: Equatable, Sendable {
        let start: Date
        let end: Date
        let granularity: Int
        var nativeCount: Int { Int(end.timeIntervalSince(start)) / granularity }
    }
    static func nativeGranularity(period: MarketPeriod) -> Int {
        [60, 300, 900, 3600, 21_600].last { Int(period.nominalSeconds) % $0 == 0 }!
    }
    static func nativePeriod(granularity: Int) -> MarketPeriod {
        switch granularity {
        case 60: .minute
        case 300: .minute5
        case 900: .minute15
        case 3600: .hour
        default: .hour6
        }
    }
    static func intradayPlan(period: MarketPeriod, from start: Date, through end: Date, now: Date) throws -> IntradayPlan {
        guard period.isIntraday, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, start >= MarketRange.genesisDate,
              start < end, end <= now else { throw MarketHistoryError.invalidRange }
        let granularity = nativeGranularity(period: period)
        let first = period.bucket(containing: start).start
        let endBucket = period.bucket(containing: end)
        let alignedEnd = end == endBucket.start ? end : endBucket.end
        let completedEnd = min(alignedEnd, Date(timeIntervalSince1970:
            floor(now.timeIntervalSince1970 / Double(granularity)) * Double(granularity)))
        guard completedEnd > first else { throw MarketHistoryError.emptyHistory }
        let outputCount = ceil(completedEnd.timeIntervalSince(first) / period.nominalSeconds)
        let nativeCount = completedEnd.timeIntervalSince(first) / Double(granularity)
        guard outputCount <= 16_000, nativeCount <= 100_000 else { throw MarketHistoryError.rangeTooLarge }
        return IntradayPlan(start: first, end: completedEnd, granularity: granularity)
    }
    static func coinbasePages(from start: Date, through end: Date, granularity: Int) -> [CandlePage] {
        let pageSpan = Double(granularity * 300)
        return stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970, by: pageSpan).map { timestamp in
            let boundary = Date(timeIntervalSince1970: timestamp)
            return CandlePage(start: boundary, end: min(boundary.addingTimeInterval(pageSpan), end))
        }
    }

    static func minuteBoundary(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    static func missingMinutes(candles: [MarketCandle], from start: Date, through end: Date) throws -> [Date] {
        let count = end.timeIntervalSince(start) / 60
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              minuteBoundary(start) == start, minuteBoundary(end) == end,
              count >= 0, count <= 16_000 else { throw MarketHistoryError.invalidResponse }
        let complete = Set(candles.filter { $0.hasOHLC && $0.isComplete && $0.interval == 60 }.map(\.startDate))
        return (0..<Int(count)).map { start.addingTimeInterval(Double($0) * 60) }.filter { !complete.contains($0) }
    }

    /// Fixed 300-minute pages bound even scattered missing bars to at most
    /// 34 requests for seven days. A single missing bar needs just one page.
    static func coinbaseRepairPages(missing: [Date], from start: Date, through end: Date) -> [CandlePage] {
        let pages = Set(missing.filter { $0 >= start && $0 < end }.map { Int($0.timeIntervalSince(start) / 18_000) })
        return pages.sorted().map { index in
            let boundary = start.addingTimeInterval(Double(index) * 18_000)
            return CandlePage(start: boundary, end: min(boundary.addingTimeInterval(18_000), end))
        }
    }

    static func coinbaseEndpoint(from start: Date, through end: Date, granularity: Int = 60) -> URL {
        let formatter = ISO8601DateFormatter()
        var components = URLComponents(string: "https://api.exchange.coinbase.com/products/BTC-USD/candles")!
        components.queryItems = [URLQueryItem(name: "granularity", value: String(granularity)),
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end))]
        return components.url!
    }

    /// Exchange candles are [start, low, high, open, close, volume] in reverse
    /// order. The live API may include the end boundary (301 rows), so the
    /// requested interval is always filtered as [start, end), then sorted.
    static func decodeCoinbase(data: Data, from start: Date, through end: Date,
                               fetchedAt: Date, granularity: Int = 60) throws -> [MarketCandle] {
        let duration = Double(granularity)
        guard [60, 300, 900, 3600, 21_600].contains(granularity), data.count <= 4_000_000,
              start < end, end.timeIntervalSince(start) <= duration * 300,
              fetchedAt.timeIntervalSince1970.isFinite, end <= fetchedAt,
              start.timeIntervalSince1970.truncatingRemainder(dividingBy: duration) == 0,
              end.timeIntervalSince1970.truncatingRemainder(dividingBy: duration) == 0 else {
            throw MarketHistoryError.invalidResponse
        }
        let rows: [[Decimal]]
        do { rows = try JSONDecoder().decode([[Decimal]].self, from: data) }
        catch { throw MarketHistoryError.invalidResponse }
        guard rows.count <= 301 else { throw MarketHistoryError.invalidResponse }
        var seen = Set<Int64>()
        var result: [MarketCandle] = []
        for row in rows {
            guard row.count == 6 else { throw MarketHistoryError.invalidResponse }
            let timestamp = NSDecimalNumber(decimal: row[0]).int64Value
            guard Decimal(timestamp) == row[0], timestamp > 0, timestamp % Int64(granularity) == 0,
                  seen.insert(timestamp).inserted else { throw MarketHistoryError.invalidResponse }
            let date = Date(timeIntervalSince1970: Double(timestamp))
            guard date >= start, date < end else { continue }
            guard row[5] >= 0, row[1...4].allSatisfy({ $0 > 0 && $0 <= Amounts.maximumPrice }) else {
                throw MarketHistoryError.invalidResponse
            }
            let raw = MarketCandle(closeDate: date.addingTimeInterval(duration), interval: duration,
                open: row[3], high: row[2], low: row[1], close: row[4])
            if valid(raw) { result.append(raw) }
            else {
                // Preserve only the genuine close when the source extrema
                // disagree; never manufacture open, high or low values.
                result.append(MarketCandle(closeDate: raw.closeDate, interval: duration,
                    open: raw.close, high: raw.close, low: raw.close, close: raw.close, hasOHLC: false))
            }
        }
        return result.sorted { $0.startDate < $1.startDate }
    }

    static func minuteHistory(usd: [MarketCandle], from start: Date, fetchedAt: Date, source: String) throws -> MarketHistory {
        guard usd.count <= 16_000, fetchedAt.timeIntervalSince1970.isFinite else {
            throw MarketHistoryError.invalidResponse
        }
        var retained: [MarketCandle] = []
        var seen = Set<Date>()
        for candle in usd.sorted(by: { $0.startDate < $1.startDate }) {
            guard valid(candle), candle.interval <= 60, minuteBoundary(candle.startDate) == candle.startDate,
                  candle.closeDate <= fetchedAt, seen.insert(candle.startDate).inserted else {
                throw MarketHistoryError.invalidResponse
            }
            guard candle.startDate >= start else { continue }
            retained.append(candle)
        }
        guard !retained.isEmpty else { throw MarketHistoryError.emptyHistory }
        let missing = try missingMinutes(candles: retained, from: start, through: minuteBoundary(fetchedAt)).count
        return MarketHistory(range: .week, period: .minute, fetchedAt: fetchedAt, candles: retained, source: source,
            warning: missing > 0 ? "最近 7 天仍有 \(missing) 个已结束分钟缺少完整行情；缺口保留为空，不进行补造。" : nil)
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
    struct Meta: Decodable { let currency: String; let dataGranularity: String? }
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
    public let costUSD: Decimal
    public let segment: Int
}

public struct LedgerChartEvent: Equatable, Identifiable, Sendable {
    public let entry: LedgerEntry
    /// Position only; this is never presented as an event's market price.
    public let markerPriceUSD: Decimal
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
            defer { priorCost = point.snapshot.averageCostUSD }
            guard point.date >= start, point.date <= end, let entry = byID[point.entryID] else { continue }
            let position = point.snapshot.averageCostUSD ?? priorCost
                ?? history.latestClose(asOf: point.date)?.close ?? fallback
            result.append(LedgerChartEvent(entry: entry, markerPriceUSD: position))
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
            if let cost { result.append(CostChartPoint(id: result.count, date: date, costUSD: cost, segment: segment)) }
        }
        add(start, prior.averageCostUSD)
        for event in events {
            add(event.date, prior.averageCostUSD)
            if prior.averageCostUSD == nil { segment += 1 }
            add(event.date, event.snapshot.averageCostUSD)
            prior = event.snapshot
        }
        add(end, prior.averageCostUSD)
        return result
    }
}
