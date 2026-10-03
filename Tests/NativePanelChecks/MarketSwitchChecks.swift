import AppKit
import Foundation
import LedgerCore
import SwiftUI

/// These source fixtures run only in an explicitly injected ephemeral session.
/// A delayed first request makes cancellation and A → B → A deterministic.
private final class QAMarketSwitchLog: @unchecked Sendable {
    enum Scenario: Equatable, Sendable { case repeated, changed, failure, daily, basis }
    let scenario: Scenario
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var cancelled = 0
    init(_ scenario: Scenario) { self.scenario = scenario }
    func began(_ url: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        recorded.append(url)
        return recorded.count
    }
    func stopped() { lock.lock(); cancelled += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return recorded.count }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private class QAMarketSwitchProtocol: URLProtocol, @unchecked Sendable {
    class var log: QAMarketSwitchLog { QAMarketRepeatedProtocol.recorded }
    private let finishLock = NSLock()
    private var finished = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let index = type(of: self).log.began(url)
        let scenario = type(of: self).log.scenario
        let delay: TimeInterval = (scenario == .repeated || scenario == .changed) && index == 1 ? 0.3
            : scenario == .daily && index == 1 ? 0.1 : 0
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in respond(url: url) }
    }
    override func stopLoading() {
        finishLock.lock()
        let wasPending = !finished
        finished = true
        finishLock.unlock()
        if wasPending { type(of: self).log.stopped() }
    }
    private func respond(url: URL) {
        finishLock.lock()
        guard !finished else { finishLock.unlock(); return }
        finished = true
        finishLock.unlock()
        guard request.httpBody == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        var status = 200
        let bytes: Data
        if url.host == "api.exchange.coinbase.com", url.path == "/products/BTC-USD/candles",
           let granularity = Int(query["granularity"] ?? ""),
           let start = ISO8601DateFormatter().date(from: query["start"] ?? ""),
           let end = ISO8601DateFormatter().date(from: query["end"] ?? ""),
           end.timeIntervalSince(start) <= Double(granularity * 300) {
            if type(of: self).log.scenario == .failure, query["start"]?.hasPrefix("2024-01-04") == true { status = 500 }
            let rows = stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970,
                              by: Double(granularity)).map { "[\(Int64($0)),90,110,100,105,1]" }.reversed()
            bytes = Data("[\(rows.joined(separator: ","))]".utf8)
        } else if type(of: self).log.scenario == .daily,
                  url.host == "query1.finance.yahoo.com", url.path == "/v8/finance/chart/BTC-USD" {
            let midnight = Int64(MarketHistory.utcCalendar.startOfDay(for: Date()).timeIntervalSince1970)
            bytes = Data("""
            {"chart":{"error":null,"result":[{"meta":{"currency":"USD","dataGranularity":"1d"},"timestamp":[\(midnight - 86400),\(midnight)],"indicators":{"quote":[{"open":[100,110],"high":[120,130],"low":[90,100],"close":[115,125]}]}}]}}
            """.utf8)
        } else if type(of: self).log.scenario == .daily, url.host == "community-api.coinmetrics.io" {
            bytes = Data("{\"data\":[{\"asset\":\"btc\",\"time\":\"2010-01-01T00:00:00Z\",\"PriceUSD\":\"1\"}],\"next_page_url\":null}".utf8)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class QAMarketRepeatedProtocol: QAMarketSwitchProtocol, @unchecked Sendable {
    static let recorded = QAMarketSwitchLog(.repeated)
}
private final class QAMarketChangedProtocol: QAMarketSwitchProtocol, @unchecked Sendable {
    static let recorded = QAMarketSwitchLog(.changed)
    override class var log: QAMarketSwitchLog { recorded }
}
private final class QAMarketFailureProtocol: QAMarketSwitchProtocol, @unchecked Sendable {
    static let recorded = QAMarketSwitchLog(.failure)
    override class var log: QAMarketSwitchLog { recorded }
}
private final class QAMarketDailyProtocol: QAMarketSwitchProtocol, @unchecked Sendable {
    static let recorded = QAMarketSwitchLog(.daily)
    override class var log: QAMarketSwitchLog { recorded }
}
private final class QAMarketBasisProtocol: QAMarketSwitchProtocol, @unchecked Sendable {
    static let recorded = QAMarketSwitchLog(.basis)
    override class var log: QAMarketSwitchLog { recorded }
}
private final class QAMarketCutoffProtocol: QAMarketSwitchProtocol, @unchecked Sendable {
    static let recorded = QAMarketSwitchLog(.basis)
    override class var log: QAMarketSwitchLog { recorded }
}

extension PanelChecks {
    @MainActor private static func switchingModel(_ name: String, fixture: AnyClass) throws -> (BTCChartModel, URLSession) {
        let folder = output.appendingPathComponent("market-switch-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [fixture]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        return (BTCChartModel(cacheDirectory: folder, client: MarketHistoryClient(session: session)), session)
    }
    @MainActor private static func waitForSwitch(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw UIError.text("synthetic market switch timed out")
    }
    @MainActor static func checkChartRequestSwitching() throws {
        let date = ISO8601DateFormatter()
        let first = date.date(from: "2024-01-03T00:00:00Z")!
        let windowA = BTCChartViewport(start: first, end: first.addingTimeInterval(4 * 3600))
        let windowB = BTCChartViewport(start: first, end: first.addingTimeInterval(6 * 3600))
        let recent = Date()
        let olderObservation = recent.addingTimeInterval(-7200)
        let olderDayStart = MarketHistory.utcCalendar.startOfDay(for: olderObservation)
        let olderDaily = MarketHistory(range: .all, fetchedAt: olderObservation,
            candles: [MarketCandle(closeDate: olderObservation, interval: olderObservation.timeIntervalSince(olderDayStart),
                open: 100, high: 110, low: 90, close: 105, isComplete: false)], source: "合成较旧日行情")
        let olderRecord = BTCMarketCacheRecord(period: .day, from: MarketRange.genesisDate,
                                               through: olderObservation, history: olderDaily)
        let recentHour = BTCChartLoad(period: .day,
            window: BTCChartViewport(start: recent.addingTimeInterval(-3600), end: recent))
        let recentMonth = BTCChartLoad(period: .day,
            window: BTCChartViewport(start: recent.addingTimeInterval(-30 * 86400), end: recent))
        record(recent.timeIntervalSince(olderDaily.fetchedAt) < 14400
               && !olderRecord.covers(recentHour, now: recent) && olderRecord.covers(recentMonth, now: recent),
               "a still-fresh two-hour-old daily cache serves a broad window but requires a new source observation for the latest hour")
        let (repeated, repeatedSession) = try switchingModel("repeated", fixture: QAMarketRepeatedProtocol.self)
        defer { repeatedSession.invalidateAndCancel() }
        let repeatedError = runAsync {
            let oldA = Task { await repeated.load(period: .hour, window: windowA) }
            try await waitForSwitch { QAMarketRepeatedProtocol.recorded.count == 1 }
            await repeated.load(period: .hour2, window: windowB)
            await repeated.load(period: .hour, window: windowA)
            await oldA.value
            try await waitForSwitch { !repeated.loading && repeated.matchingHistory(period: .hour, window: windowA) != nil }
        }
        record(repeatedError == nil && QAMarketRepeatedProtocol.recorded.count == 2,
               "A → B → A restarts the cancelled first A instead of losing the final identical selection")
        record(QAMarketRepeatedProtocol.recorded.stops == 1,
               "A → B → A cancels the obsolete source request before accepting a new matching response")
        record(repeated.history?.period == .hour && repeated.displayedWindow == windowA
               && repeated.coverageWindow == windowA && repeated.rejected == nil && repeated.error == nil
               && repeated.history?.candles.count == 4,
               "A → B → A publishes only the final period, exact window and source coverage")

        let (changed, changedSession) = try switchingModel("changed", fixture: QAMarketChangedProtocol.self)
        defer { changedSession.invalidateAndCancel() }
        let changedError = runAsync {
            let old = Task { await changed.load(period: .minute30, window: windowA) }
            try await waitForSwitch { QAMarketChangedProtocol.recorded.count == 1 }
            await changed.load(period: .hour2, window: windowB)
            await old.value
            try await waitForSwitch { !changed.loading && changed.matchingHistory(period: .hour2, window: windowB) != nil }
        }
        record(changedError == nil && QAMarketChangedProtocol.recorded.count == 2
               && QAMarketChangedProtocol.recorded.stops == 1,
               "changing periods during a cold source fetch cancels the old request and starts the queued latest request")
        record(changed.history?.period == .hour2 && changed.displayedWindow == windowB
               && changed.coverageWindow == windowB && changed.history?.candles.count == 3
               && changed.matchingHistory(period: .minute30, window: windowA) == nil,
               "a cancelled earlier period never supplies the visible data for the final period")

        let failedWindow = BTCChartViewport(start: first.addingTimeInterval(86400),
                                           end: first.addingTimeInterval(86400 + 6 * 3600))
        let (failure, failureSession) = try switchingModel("failure", fixture: QAMarketFailureProtocol.self)
        defer { failureSession.invalidateAndCancel() }
        let failureError = runAsync {
            await failure.load(period: .hour, window: windowA)
            await failure.load(period: .hour2, window: failedWindow)
        }
        record(failureError == nil && failure.rejected == BTCChartLoad(period: .hour2, window: failedWindow)
               && failure.matchingHistory(period: .hour2, window: failedWindow) == nil
               && failure.error?.contains("500") == true,
               "failed new period and dates retain their failure reason without displaying unrelated successful history")
        let recoveryError = runAsync { await failure.load(period: .hour, window: windowA) }
        record(recoveryError == nil && failure.matchingHistory(period: .hour, window: windowA) != nil
               && failure.displayedWindow == windowA && failure.coverageWindow == windowA
               && failure.rejected == nil && failure.error == nil && QAMarketFailureProtocol.recorded.count == 2,
               "switching back after a source failure restores the matching fresh cache immediately without another request")

        // Fix the historical cutoff away from a six-hour boundary. Its broad
        // source can only close at 06:00, outside the short 10:52–11:52 window.
        let cutoff = date.date(from: "2024-01-03T11:52:00Z")!
        let broad = BTCChartViewport(start: cutoff.addingTimeInterval(-30 * 86400), end: cutoff)
        let narrow = BTCChartViewport(start: cutoff.addingTimeInterval(-3600), end: cutoff)
        let (basis, basisSession) = try switchingModel("basis", fixture: QAMarketBasisProtocol.self)
        defer { basisSession.invalidateAndCancel() }
        let broadError = runAsync { await basis.load(period: .hour12, window: broad) }
        let coarse = basis.matchingHistory(period: .hour12, window: broad)
        record(broadError == nil && coarse?.candles.last?.closeDate == date.date(from: "2024-01-03T06:00:00Z")
               && coarse?.aggregatedCandles(period: .hour12, from: broad.start, through: broad.end).isEmpty == false
               && basis.coverageWindow.map { $0.start <= narrow.start && $0.end >= narrow.end } == true,
               "a broad 12-hour request uses real six-hour source bars and its cache dates cover the later short selection")
        record(coarse?.aggregatedCandles(period: .hour12, from: narrow.start, through: narrow.end).isEmpty == true
               && basis.matchingHistory(period: .hour12, window: narrow) == nil,
               "a fresh same-period cache with insufficient source precision cannot claim coverage of a short window")
        let narrowError = runAsync { await basis.load(period: .hour12, window: narrow) }
        let selected = basis.matchingHistory(period: .hour12, window: narrow)
        let selectedBars = selected?.aggregatedCandles(period: .hour12, from: narrow.start, through: narrow.end) ?? []
        let granularities = QAMarketBasisProtocol.recorded.urls.map { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "granularity" }?.value
        }
        record(narrowError == nil && granularities == ["21600", "3600"] && basis.displayedWindow == narrow
               && selected?.period == .hour12 && !selectedBars.isEmpty,
               "broad-to-short 12-hour selection fetches a finer one-hour basis and renders data for the exact selected window")
        record(selectedBars.last?.closeDate == date.date(from: "2024-01-03T11:00:00Z")
               && selectedBars.allSatisfy { $0.closeDate <= narrow.end && $0.hasOHLC && !$0.isComplete && $0.close == 105 }
               && basis.rejected == nil && basis.error == nil,
               "the finer short-window aggregate uses only genuinely closed source bars and never borrows future prices")

        let dayStart = date.date(from: "2024-01-03T00:00:00Z")!
        let fullDay = BTCChartViewport(start: dayStart, end: dayStart.addingTimeInterval(86400))
        let truncated = BTCChartViewport(start: dayStart, end: dayStart.addingTimeInterval(8 * 3600))
        let (cutoffModel, cutoffSession) = try switchingModel("cutoff", fixture: QAMarketCutoffProtocol.self)
        defer { cutoffSession.invalidateAndCancel() }
        let cutoffBroadError = runAsync { await cutoffModel.load(period: .hour12, window: fullDay) }
        record(cutoffBroadError == nil && cutoffModel.history?.candles.count == 2
               && cutoffModel.history?.candles.allSatisfy(\.isComplete) == true
               && cutoffModel.matchingHistory(period: .hour12, window: truncated) == nil,
               "a cached whole 12-hour candle cannot cover an earlier cutoff inside that candle")
        let cutoffError = runAsync { await cutoffModel.load(period: .hour12, window: truncated) }
        let cutoffBars = cutoffModel.matchingHistory(period: .hour12, window: truncated)?
            .aggregatedCandles(period: .hour12, from: truncated.start, through: truncated.end) ?? []
        let cutoffGranularities = QAMarketCutoffProtocol.recorded.urls.map { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "granularity" }?.value
        }
        record(cutoffError == nil && cutoffGranularities == ["21600", "21600"]
               && cutoffBars.count == 1 && cutoffBars.first?.startDate == dayStart
               && cutoffBars.first?.closeDate == dayStart.addingTimeInterval(6 * 3600)
               && cutoffBars.first?.hasOHLC == true && cutoffBars.first?.isComplete == false
               && cutoffModel.displayedWindow == truncated && cutoffModel.error == nil,
               "an 08:00 historical cutoff refetches real six-hour source bars and displays the 00:00–06:00 partial candle")
        let cutoffReuseError = runAsync { await cutoffModel.load(period: .hour12, window: truncated) }
        record(cutoffReuseError == nil && QAMarketCutoffProtocol.recorded.count == 2
               && cutoffModel.matchingHistory(period: .hour12, window: truncated)?.candles == cutoffBars,
               "the matching partial-candle cache serves the same historical cutoff without another request")

        let (daily, dailySession) = try switchingModel("daily", fixture: QAMarketDailyProtocol.self)
        defer { dailySession.invalidateAndCancel() }
        guard let ledgerPath = ProcessInfo.processInfo.environment["BITCOIN_LEDGER_DATA_PATH"],
              ledgerPath.hasPrefix(output.path + "/") else {
            record(false, "daily refresh UI check requires the owned synthetic ledger path"); return
        }
        let store = AppStore()
        let beforeFetch = Date().addingTimeInterval(-2)
        let window = host(BTCChartView(expandedChart: .constant(false), range: .hour, period: .day,
                                      today: beforeFetch, model: daily),
                          store: store, size: NSSize(width: 900, height: 450))
        defer { window.close() }
        let dailyError = runAsync { try await waitForSwitch { daily.history != nil && !daily.loading } }
        settle()
        let current = nativePlotInputs(window.contentView!).first?.snapshot
        record(dailyError == nil && (daily.history?.fetchedAt ?? .distantPast) > beforeFetch
               && current?.period == .day && (current?.visibleCandleCount ?? 0) > 0
               && current.map { $0.timeWindow.upperBound >= daily.history!.fetchedAt } == true
               && fittedOHLC(current),
               "daily data observed after opening a current short window advances its latest cutoff and renders the new real bar")
        record(QAMarketDailyProtocol.recorded.count == 2,
               "current daily refresh uses only the two injected synthetic public sources and never repeats a network request")
    }
}
