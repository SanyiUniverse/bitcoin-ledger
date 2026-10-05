import Foundation
import LedgerCore

/// Advances model time without waiting for real 60–900 second deadlines.
private final class QARetryClock: @unchecked Sendable {
    private struct Waiter {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var date: Date
    private var waiters: [UUID: Waiter] = [:]
    private var cancelled: Set<UUID> = []
    init(now: Date = Date()) { date = now }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    var waitingCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(seconds)
        let due = waiters.filter { $0.value.deadline <= date }
        for id in due.keys { waiters.removeValue(forKey: id) }
        lock.unlock()
        for waiter in due.values { waiter.continuation.resume() }
    }
    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled || cancelled.remove(id) != nil {
                    lock.unlock(); continuation.resume(throwing: CancellationError())
                } else if deadline <= date {
                    lock.unlock(); continuation.resume()
                } else {
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    lock.unlock()
                }
            }
        }, onCancel: { self.cancel(id) })
    }
    private func cancel(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        if waiter == nil { cancelled.insert(id) }
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
    }
}

private final class QARetrySource: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int] = []
    private var after: String?
    private var firstResponseDelay: TimeInterval = 0
    private var requested: [URL] = []
    func reset(statuses: [Int], retryAfter: String?, firstResponseDelay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        self.statuses = statuses; after = retryAfter; requested = []; self.firstResponseDelay = firstResponseDelay
    }
    func response(for url: URL) -> (Int, String?, TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if url.host == "community-api.coinmetrics.io" { return (200, nil, 0) }
        requested.append(url)
        return (statuses.isEmpty ? 200 : statuses.removeFirst(), after, requested.count == 1 ? firstResponseDelay : 0)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requested.count }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requested }
}

private final class QARetryProtocol: URLProtocol, @unchecked Sendable {
    static let source = QARetrySource()
    private let finishLock = NSLock()
    private var finished = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.httpBody == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let (status, after, delay) = Self.source.response(for: url)
        if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        let data: Data
        if url.host == "api.exchange.coinbase.com",
           let start = query["start"].flatMap({ ISO8601DateFormatter().date(from: $0) }),
           let end = query["end"].flatMap({ ISO8601DateFormatter().date(from: $0) }),
           let granularity = query["granularity"].flatMap(Int.init) {
            let rows = stride(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970,
                              by: Double(granularity)).map { "[\(Int64($0)),90,110,100,105,1]" }
            data = Data("[\(rows.joined(separator: ","))]".utf8)
        } else if url.host == "query1.finance.yahoo.com" {
            let midnight = Int64(MarketHistory.utcCalendar.startOfDay(for: Date()).timeIntervalSince1970)
            data = Data("""
            {"chart":{"error":null,"result":[{"meta":{"currency":"USD","dataGranularity":"1d"},"timestamp":[\(midnight - 86400),\(midnight)],"indicators":{"quote":[{"open":[100,110],"high":[120,130],"low":[90,100],"close":[115,125]}]}}]}}
            """.utf8)
        } else if url.host == "community-api.coinmetrics.io" {
            data = Data("{\"data\":[{\"asset\":\"btc\",\"time\":\"2010-01-01T00:00:00Z\",\"PriceUSD\":\"1\"}],\"next_page_url\":null}".utf8)
        } else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: after.map { ["Retry-After": $0] })!
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in finish(response: response, data: data) }
        } else { finish(response: response, data: data) }
    }
    private func finish(response: HTTPURLResponse, data: Data) {
        finishLock.lock()
        guard !finished else { finishLock.unlock(); return }
        finished = true; finishLock.unlock()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { finishLock.lock(); finished = true; finishLock.unlock() }
}

extension PanelChecks {
    @MainActor private static func retryWait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw UIError.text("synthetic automatic retry timed out")
    }
    @MainActor private static func retryFixture(statuses: [Int], retryAfter: String? = nil,
        date: Date = Date(), firstResponseDelay: TimeInterval = 0,
        operation: (BTCChartModel, QARetryClock) async throws -> Void) async throws {
        QARetryProtocol.source.reset(statuses: statuses, retryAfter: retryAfter, firstResponseDelay: firstResponseDelay)
        let clock = QARetryClock(now: date)
        let folder = output.appendingPathComponent("market-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QARetryProtocol.self]
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let model = BTCChartModel(cacheDirectory: folder, client: MarketHistoryClient(session: session),
                                 now: { clock.now() }, sleepUntil: { try await clock.sleep(until: $0) })
        defer { model.stop(); session.invalidateAndCancel() }
        try await operation(model, clock)
    }
    @MainActor static func checkChartAutomaticRetry() throws {
        let first = ISO8601DateFormatter().date(from: "2024-01-03T00:00:00Z")!
        let window = BTCChartViewport(start: first, end: first.addingTimeInterval(4 * 3600))
        let changed = BTCChartViewport(start: first.addingTimeInterval(86400), end: first.addingTimeInterval(86400 + 4 * 3600))
        let result = runAsync {
            try await retryFixture(statuses: [200, 200]) { model, clock in
                await model.load(period: .day, window: window)
                await model.load(period: .day, window: window, force: true)
                await model.load(period: .day, window: window, force: true)
                try await retryWait { clock.waitingCount == 1 }
                let before = model.retry?.message(now: clock.now())
                clock.advance(1)
                let after = model.retry?.message(now: clock.now())
                record(before?.contains("60 秒") == true && after?.contains("59 秒") == true,
                       "countdown derives changing seconds from its absolute deadline")
                clock.advance(58)
                await Task.yield()
                record(QARetryProtocol.source.count == 1 && model.retry != nil,
                       "duplicate refresh intents share one wait and cannot request before the cooldown")
                clock.advance(1)
                try await retryWait { QARetryProtocol.source.count == 2 && !model.loading && model.retry == nil }
                record(model.history != nil && QARetryProtocol.source.count == 2,
                       "cooldown expiry performs one real fetch even while the daily cache remains fresh")
            }
            try await retryFixture(statuses: [500, 500, 200, 500]) { model, clock in
                await model.load(period: .hour, window: window)
                record(model.retry?.deadline == clock.now().addingTimeInterval(60), "HTTP 500 starts a 60-second automatic retry")
                try await retryWait { clock.waitingCount == 1 }
                clock.advance(60)
                try await retryWait { QARetryProtocol.source.count == 2 && clock.waitingCount == 1 }
                record(model.retry?.deadline == clock.now().addingTimeInterval(120), "repeated transient failures double the retry delay")
                clock.advance(120)
                try await retryWait { QARetryProtocol.source.count == 3 && !model.loading && model.retry == nil }
                record(model.displayedWindow == window && model.error == nil,
                       "successful automatic retry clears its failure and keeps fixed historical dates")
                clock.advance(60)
                await model.load(period: .hour, window: window, force: true)
                record(model.retry?.deadline == clock.now().addingTimeInterval(60),
                       "a failure after a successful recovery restarts at the first backoff interval")
            }
            try await retryFixture(statuses: [0, 200]) { model, clock in
                await model.load(period: .hour, window: window)
                record(model.retry != nil && model.history == nil, "offline transport failures use the same automatic retry state")
                try await retryWait { clock.waitingCount == 1 }
                clock.advance(60)
                try await retryWait { QARetryProtocol.source.count == 2 && !model.loading && model.retry == nil }
            }
            try await retryFixture(statuses: [429, 200], retryAfter: "180") { model, clock in
                await model.load(period: .hour, window: window)
                record((model.retry?.deadline.timeIntervalSince(clock.now()) ?? 0) >= 179,
                       "HTTP 429 honors Retry-After when it exceeds the local backoff")
                record(model.retry?.message(now: clock.now()).contains("手动") == false,
                       "rate-limited countdown describes automatic retry without requiring a manual action")
                try await retryWait { clock.waitingCount == 1 }
                clock.advance(200)
                try await retryWait { QARetryProtocol.source.count == 2 && !model.loading && model.retry == nil }
            }
            try await retryFixture(statuses: [404]) { model, clock in
                await model.load(period: .hour, window: window)
                clock.advance(900)
                await Task.yield()
                record(model.retry == nil && QARetryProtocol.source.count == 1 && model.error?.contains("404") == true,
                       "permanent HTTP failures remain explicit and schedule no automatic requests")
            }
            try await retryFixture(statuses: [500, 200]) { model, clock in
                await model.load(period: .hour, window: window)
                try await retryWait { clock.waitingCount == 1 }
                await model.load(period: .hour2, window: changed)
                clock.advance(60)
                await Task.yield()
                record(QARetryProtocol.source.count == 2 && model.displayedWindow == changed && model.retry == nil,
                       "changing period and dates cancels the old pending retry without publishing old data")
            }
            try await retryFixture(statuses: [500, 200]) { model, clock in
                await model.load(period: .hour, window: window)
                try await retryWait { clock.waitingCount == 1 }
                model.pauseForSleep()
                clock.advance(120)
                await Task.yield()
                record(QARetryProtocol.source.count == 1 && model.retry != nil, "sleep pauses retry while preserving its deadline")
                model.resume(); model.resume()
                try await retryWait { QARetryProtocol.source.count == 2 && !model.loading && model.retry == nil }
                record(QARetryProtocol.source.count == 2, "overdue wake and activation callbacks combine into one immediate request")
            }
            try await retryFixture(statuses: [500, 200]) { model, clock in
                await model.load(period: .hour, window: window)
                try await retryWait { clock.waitingCount == 1 }
                model.pauseForSleep(); clock.advance(20); model.resume()
                try await retryWait { clock.waitingCount == 1 }
                record(QARetryProtocol.source.count == 1 && model.retry?.deadline == clock.now().addingTimeInterval(40),
                       "waking before the deadline keeps the remaining cooldown")
                clock.advance(40)
                try await retryWait { QARetryProtocol.source.count == 2 && !model.loading && model.retry == nil }
            }
            try await retryFixture(statuses: [200, 200], firstResponseDelay: 0.3) { model, _ in
                let flight = Task { await model.load(period: .hour, window: window) }
                try await retryWait { QARetryProtocol.source.count == 1 && model.loading }
                model.pauseForSleep(); model.resume(); model.resume()
                await flight.value
                try await retryWait { QARetryProtocol.source.count == 2 && !model.loading && model.history != nil }
                record(model.retry == nil && model.displayedWindow == window,
                       "sleep cancels an in-flight request and resume starts one replacement without publishing the cancelled response")
            }
            try await retryFixture(statuses: [500, 200], date: Date().addingTimeInterval(-900)) { model, clock in
                let end = clock.now()
                let liveWindow = BTCChartViewport(start: end.addingTimeInterval(-3600), end: end)
                await model.load(period: .hour, window: liveWindow, latestRange: .hour)
                try await retryWait { clock.waitingCount == 1 }
                clock.advance(60)
                try await retryWait { QARetryProtocol.source.count == 2 && !model.loading && model.retry == nil }
                record(model.displayedWindow?.end == clock.now() && model.displayedWindow?.end != end,
                       "latest preset retries follow current time while preserving the selected period and range")
                await model.load(period: .hour, window: model.displayedWindow!, latestRange: .hour)
                record(QARetryProtocol.source.count == 2 && model.retry == nil,
                       "a latest-summary update reuses the newly successful cache without another cooldown loop")
            }
            try await retryFixture(statuses: [500, 200]) { model, clock in
                await model.load(period: .hour, window: window)
                try await retryWait { clock.waitingCount == 1 }
                model.stop(); clock.advance(900); model.resume()
                await Task.yield()
                record(QARetryProtocol.source.count == 1 && model.retry == nil,
                       "leaving the chart cancels pending work and invalidates automatic wake callbacks")
                await model.load(period: .hour, window: window)
                record(QARetryProtocol.source.count == 2 && model.history != nil,
                       "returning to the chart can load its current selection after lifecycle cancellation")
            }
        }
        record(result == nil, "all automatic chart retry fixtures complete using isolated clocks and public-data stubs")
        if let result { report.append("RETRY ERROR \(result)") }
    }
}
