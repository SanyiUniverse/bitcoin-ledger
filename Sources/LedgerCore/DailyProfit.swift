import Foundation

public enum DailyNoonStatus: String, Codable, Equatable, Sendable {
    case available
    case missing
}

/// The immutable market input for one Shanghai calendar day. Accounting
/// amounts are derived from the ledger so historical corrections stay honest.
public struct DailyNoonObservation: Codable, Equatable, Identifiable, Sendable {
    public var targetAt: Date
    public var priceUSD: Decimal?
    public var source: String
    public var fetchedAt: Date
    public var status: DailyNoonStatus
    public var id: Date { targetAt }
    public var priceCloseAt: Date { DailyProfitEngine.completedMinuteClose(for: targetAt) }

    public init(targetAt: Date, priceUSD: Decimal?, source: String = DailyProfitEngine.priceSource,
                fetchedAt: Date = Date(), status: DailyNoonStatus = .available) {
        self.targetAt = targetAt
        self.priceUSD = priceUSD
        self.source = source
        self.fetchedAt = fetchedAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case targetAt, priceUSD, source, fetchedAt, status }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        targetAt = try values.decode(Date.self, forKey: .targetAt)
        if let text = try values.decodeIfPresent(String.self, forKey: .priceUSD) {
            priceUSD = try Amounts.decimal(text, maxPlaces: 38)
        } else { priceUSD = nil }
        source = try values.decode(String.self, forKey: .source)
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        status = try values.decode(DailyNoonStatus.self, forKey: .status)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(targetAt, forKey: .targetAt)
        try values.encodeIfPresent(priceUSD.map(Amounts.string), forKey: .priceUSD)
        try values.encode(source, forKey: .source)
        try values.encode(fetchedAt, forKey: .fetchedAt)
        try values.encode(status, forKey: .status)
    }
}

public enum DailyProfitStatus: String, Equatable, Sendable {
    case available
    case pendingPrice
    case missingPrice
    case pendingCost
    case beforeFirstPurchase
}

public struct DailyProfitRow: Equatable, Identifiable, Sendable {
    /// The day's fixed first-purchase-time cutoff, not its display time.
    public let date: Date
    public let totalSats: Int64
    public let costUSD: Decimal?
    public let marketValueUSD: Decimal?
    public let profitUSD: Decimal?
    public let profitRatio: Decimal?
    public let status: DailyProfitStatus
    public let observation: DailyNoonObservation?
    public let purchaseEntryIDs: [UUID]
    public let purchaseCostChangeUSD: Decimal?
    public var id: Date { date }
    public var isBeforeFirstPurchase: Bool { status == .beforeFirstPurchase }
    public var priceUSD: Decimal? { observation?.priceUSD }
    public var purchaseCount: Int { purchaseEntryIDs.count }

    public init(date: Date, totalSats: Int64, costUSD: Decimal?, marketValueUSD: Decimal?,
                profitUSD: Decimal?, profitRatio: Decimal?, status: DailyProfitStatus,
                observation: DailyNoonObservation? = nil, purchaseEntryIDs: [UUID] = [],
                purchaseCostChangeUSD: Decimal? = nil) {
        self.date = date
        self.totalSats = totalSats
        self.costUSD = costUSD
        self.marketValueUSD = marketValueUSD
        self.profitUSD = profitUSD
        self.profitRatio = profitRatio
        self.status = status
        self.observation = observation
        self.purchaseEntryIDs = purchaseEntryIDs
        self.purchaseCostChangeUSD = purchaseCostChangeUSD
    }
}

public enum DailyProfitEngine {
    public static let pricePolicy = "first-purchase-shanghai-completed-minute-close-v1"
    public static let priceSource = "Coinbase · BTC-USD 结算前最近完整分钟收盘（美元）"
    public static let legacyNoonSource = "Coinbase · BTC-USD 11:59–12:00 完整分钟收盘（美元）"
    private static let intradaySource = "Coinbase · BTC-USD 真实行情（美元）"
    public static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    public static func noon(on date: Date) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)!
    }

    /// Shanghai has no DST in the supported Bitcoin era. Keeping the precise
    /// offset from local midnight retains the original fractional seconds.
    public static func settlement(on date: Date, entries: [LedgerEntry]) -> Date? {
        guard date.timeIntervalSince1970.isFinite,
              let first = entries.filter({ $0.kind == .buy }).map(\.date).min(),
              first.timeIntervalSince1970.isFinite, first >= MarketRange.genesisDate else { return nil }
        let firstDay = calendar.startOfDay(for: first)
        let day = calendar.startOfDay(for: date)
        if day == firstDay { return first }
        return day.addingTimeInterval(first.timeIntervalSince(firstDay))
    }

    public static func settlementTargets(entries: [LedgerEntry], now: Date = Date()) -> [Date] {
        guard now.timeIntervalSince1970.isFinite,
              let first = entries.filter({ $0.kind == .buy }).map(\.date).min(),
              first.timeIntervalSince1970.isFinite, first >= MarketRange.genesisDate,
              first <= now else { return [] }
        var day = calendar.startOfDay(for: first)
        let offset = first.timeIntervalSince(day)
        var target = first
        var result: [Date] = []
        while target <= now {
            result.append(target)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { break }
            day = nextDay
            target = day.addingTimeInterval(offset)
        }
        return result
    }

    public static func completedMinuteClose(for targetAt: Date) -> Date {
        Date(timeIntervalSince1970: floor(targetAt.timeIntervalSince1970 / 60) * 60)
    }

    private static func isNoonTarget(_ date: Date) -> Bool {
        guard date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 else { return false }
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return components.hour == 12 && components.minute == 0 && components.second == 0
    }

    /// Includes the first purchase's local date even when that purchase occurs
    /// after noon. Future cutoffs never become settled records.
    public static func noonTargets(entries: [LedgerEntry], now: Date = Date()) -> [Date] {
        guard now.timeIntervalSince1970.isFinite,
              let first = entries.filter({ $0.kind == .buy && $0.date <= now }).map(\.date).min(),
              first.timeIntervalSince1970.isFinite, first >= MarketRange.genesisDate else { return [] }
        var target = noon(on: first)
        var result: [Date] = []
        while target <= now {
            result.append(target)
            guard let next = calendar.date(byAdding: .day, value: 1, to: target), next > target else { break }
            target = next
        }
        return result
    }

    public static func validate(_ observations: [DailyNoonObservation]) throws {
        var seen = Set<Date>()
        for observation in observations {
            guard observation.targetAt.timeIntervalSince1970.isFinite,
                  observation.targetAt >= MarketRange.genesisDate,
                  observation.fetchedAt.timeIntervalSince1970.isFinite,
                  observation.fetchedAt >= observation.priceCloseAt,
                  seen.insert(observation.targetAt).inserted,
                  observation.source == priceSource
                    || (observation.source == legacyNoonSource && isNoonTarget(observation.targetAt)) else {
                throw BackupError.invalidDocument("每日结算行情的日期、来源或唯一性无效。")
            }
            switch observation.status {
            case .available:
                guard let price = observation.priceUSD, !price.isNaN,
                      price > 0, price <= Amounts.maximumPrice else {
                    throw BackupError.invalidDocument("每日结算行情价格无效。")
                }
            case .missing:
                guard observation.priceUSD == nil, observation.fetchedAt >= observation.targetAt else {
                    throw BackupError.invalidDocument("缺失的每日结算行情不能包含价格或早于结算时刻获取。")
                }
            }
        }
    }

    public static func rows(document: BackupDocument, now: Date = Date()) throws -> [DailyProfitRow] {
        try validate(document.dailyNoonObservations)
        let points = try LedgerEngine.history(accounts: document.accounts, entries: document.entries)
        let purchasesByID = Dictionary(uniqueKeysWithValues: document.entries.filter { $0.kind == .buy }.map { ($0.id, $0) })
        let observations = Dictionary(uniqueKeysWithValues: document.dailyNoonObservations.map { ($0.targetAt, $0) })
        var snapshot = LedgerSnapshot(balances: Dictionary(uniqueKeysWithValues: document.accounts.map { ($0.id, 0) }))
        var index = 0
        return settlementTargets(entries: document.entries, now: now).map { target in
            var purchases: [UUID] = []
            var purchaseCostChange: Decimal? = 0
            while index < points.count, points[index].date <= target {
                snapshot = points[index].snapshot
                if let purchase = purchasesByID[points[index].entryID] {
                    purchases.append(purchase.id)
                    if let change = purchaseCostChange, let amount = purchase.amountUSD {
                        purchaseCostChange = Amounts.rounded(change + amount)
                    } else { purchaseCostChange = nil }
                }
                index += 1
            }
            let observation = observations[target]
            let price = observation?.status == .available ? observation?.priceUSD : nil
            // No market price is needed to value zero BTC.
            let value = snapshot.totalSats == 0 ? Decimal(0) : price.map(snapshot.value)
            let profit = snapshot.totalInvestedUSD.flatMap { cost in value.map { $0 - cost } }
            let ratio: Decimal? = snapshot.totalInvestedUSD.flatMap { cost in
                guard cost > 0, let profit else { return nil }
                return Amounts.rounded(profit / cost)
            }
            let status: DailyProfitStatus
            if value == nil { status = observation?.status == .missing ? .missingPrice : .pendingPrice }
            else if snapshot.totalInvestedUSD == nil { status = .pendingCost }
            else { status = .available }
            return DailyProfitRow(date: target, totalSats: snapshot.totalSats,
                costUSD: snapshot.totalInvestedUSD, marketValueUSD: value,
                profitUSD: profit, profitRatio: ratio, status: status, observation: observation,
                purchaseEntryIDs: purchases, purchaseCostChangeUSD: purchaseCostChange)
        }
    }

    /// Reuse only the exact complete Coinbase minute. Mixed-source caches,
    /// live minutes and arbitrary earlier closes never supply a settlement price.
    public static func observation(targetAt: Date, history: MarketHistory) -> DailyNoonObservation? {
        let closeAt = completedMinuteClose(for: targetAt)
        guard targetAt.timeIntervalSince1970.isFinite, targetAt >= MarketRange.genesisDate,
              history.period == .minute, history.fetchedAt.timeIntervalSince1970.isFinite,
              history.fetchedAt >= closeAt,
              history.source == intradaySource || history.source == priceSource
                || (history.source == legacyNoonSource && isNoonTarget(closeAt)),
              let candle = history.candles.first(where: {
                  $0.closeDate == closeAt && $0.startDate == closeAt.addingTimeInterval(-60)
                    && $0.interval == 60 && $0.isComplete && $0.hasOHLC && MarketHistoryClient.valid($0)
              }) else { return nil }
        return DailyNoonObservation(targetAt: targetAt, priceUSD: candle.close, fetchedAt: history.fetchedAt)
    }

    public static func reusableNoonObservation(targetAt: Date, history: MarketHistory) -> DailyNoonObservation? {
        observation(targetAt: targetAt, history: history)
    }

    /// An older saved cutoff can be a cache only when its genuine market
    /// minute is identical. Keep both original records; never relabel a price
    /// from another minute after a corrected first purchase changes the clock.
    public static func reusableNoonObservation(targetAt: Date,
                                               observations: [DailyNoonObservation]) -> DailyNoonObservation? {
        guard targetAt.timeIntervalSince1970.isFinite, targetAt >= MarketRange.genesisDate else { return nil }
        do { try validate(observations) } catch { return nil }
        if let exact = observations.first(where: { $0.targetAt == targetAt && $0.status == .available }) { return exact }
        let closeAt = completedMinuteClose(for: targetAt)
        guard let existing = observations.filter({ $0.status == .available && $0.priceCloseAt == closeAt })
            .min(by: { $0.fetchedAt < $1.fetchedAt }) else { return nil }
        return DailyNoonObservation(targetAt: targetAt, priceUSD: existing.priceUSD,
            fetchedAt: existing.fetchedAt)
    }

    public static func fetchNoonObservation(targetAt: Date,
                                            client: MarketHistoryClient = MarketHistoryClient()) async throws -> DailyNoonObservation {
        guard targetAt.timeIntervalSince1970.isFinite, targetAt >= MarketRange.genesisDate,
              targetAt <= Date() else { throw MarketHistoryError.invalidRange }
        let closeAt = completedMinuteClose(for: targetAt)
        do {
            let history = try await client.fetchIntraday(period: .minute,
                from: closeAt.addingTimeInterval(-60), through: closeAt)
            if let observation = observation(targetAt: targetAt, history: history) { return observation }
            return DailyNoonObservation(targetAt: targetAt, priceUSD: nil,
                fetchedAt: history.fetchedAt, status: .missing)
        } catch MarketHistoryError.emptyHistory {
            return DailyNoonObservation(targetAt: targetAt, priceUSD: nil, status: .missing)
        }
    }
}
