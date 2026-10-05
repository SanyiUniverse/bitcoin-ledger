import SwiftUI
import AppKit
import Darwin
import LedgerCore
import UniformTypeIdentifiers

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

actor QARateProbe {
    private(set) var dates: [Date] = []
    var fails = false
    var delay: UInt64 = 0
    func configure(fails: Bool = false, delay: UInt64 = 0) { self.fails = fails; self.delay = delay }
    func rate(asOf date: Date) async throws -> USDExchangeRate {
        dates.append(date)
        // A late provider result must not commit even if the provider ignores cancellation.
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if fails { throw URLError(.notConnectedToInternet) }
        return PanelChecks.syntheticRate(asOf: date)
    }
}

@MainActor private final class QAAsyncResult {
    var finished = false
    var error: Error?
}

private final class QADragPayload: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var text: String?
    func complete(_ value: String?) { lock.lock(); text = value; completed = true; lock.unlock() }
    var result: (finished: Bool, text: String?) { lock.lock(); defer { lock.unlock() }; return (completed, text) }
}

private final class QANetworkAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// A failed fixture must never fall through to a real market request.
private final class QAOfflineProtocol: URLProtocol, @unchecked Sendable {
    static let attempts = QANetworkAttempts()
    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.attempts.record()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// An intentional provider failure is local to the matrix's injected session.
private final class QAUnavailableMarketProtocol: URLProtocol, @unchecked Sendable {
    static let attempts = QANetworkAttempts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.attempts.record()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// AppKit exposes gesture properties as read-only. This synthetic event supplies
/// real responder methods with explicit phases without posting a global event.
private final class QAMagnifyEvent: NSEvent {
    let ownedWindow: NSWindow
    let ownedLocation: NSPoint
    let ownedPhase: NSEvent.Phase
    let ownedMagnification: CGFloat
    init(window: NSWindow, location: NSPoint, phase: NSEvent.Phase, magnification: CGFloat) {
        ownedWindow = window; ownedLocation = location
        ownedPhase = phase; ownedMagnification = magnification
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("synthetic gesture events are not archived") }
    override var type: NSEvent.EventType { .magnify }
    override var window: NSWindow? { ownedWindow }
    override var locationInWindow: NSPoint { ownedLocation }
    override var phase: NSEvent.Phase { ownedPhase }
    override var magnification: CGFloat { ownedMagnification }
}

@MainActor final class PanelProbe: ObservableObject {
    @Published var visible = true
    var dismissals = 0
    var backgroundActions = 0
    func dismiss() { dismissals += 1; visible = false }
}

struct ProbeScene: View {
    @ObservedObject var probe: PanelProbe
    let panel: LedgerPanel
    var body: some View {
        Button("背景操作") { probe.backgroundActions += 1 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(probe.visible)
            .overlay {
                if probe.visible { LedgerPanelOverlay(panel: panel, onDismiss: probe.dismiss, onEdit: { _ in }) }
            }
    }
}

@MainActor final class ChartSizeProbe: ObservableObject {
    @Published var expanded = false
}

struct ChartSizeScene: View {
    @ObservedObject var probe: ChartSizeProbe
    var body: some View {
        BTCChartView(expandedChart: $probe.expanded)
            .frame(height: probe.expanded ? 840 : 430)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@main struct PanelChecks {
    @MainActor static var output: URL!
    @MainActor static var report: [String] = []
    @MainActor static var preferences: UserDefaults!
    @MainActor static var preferenceSuite: String!
    @MainActor static func main() throws {
        alarm(120)
        defer { alarm(0) }
        guard let path = ProcessInfo.processInfo.environment["QA_OUTPUT"], path.hasPrefix("/"), path != "/" else { fatalError("absolute isolated QA_OUTPUT directory required") }
        output = URL(fileURLWithPath: path, isDirectory: true)
        preferenceSuite = "BitcoinLedger.PanelQA.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: preferenceSuite)!
        defer { preferences.removePersistentDomain(forName: preferenceSuite) }
        let dataFolder = output.appendingPathComponent("data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let isolatedLedger = dataFolder.appendingPathComponent("ledger.json").path
        guard setenv("BITCOIN_LEDGER_DATA_PATH", isolatedLedger, 1) == 0,
              ProcessInfo.processInfo.environment["BITCOIN_LEDGER_DATA_PATH"] == isolatedLedger else {
            fatalError("isolated synthetic ledger path must be active before any AppStore is created")
        }
        try writeSyntheticMarketCache(in: dataFolder)
        record(URLProtocol.registerClass(QAOfflineProtocol.self), "isolated QA blocks external market requests")
        defer { URLProtocol.unregisterClass(QAOfflineProtocol.self) }
        let rates = QARateProbe()
        let store = AppStore(rateProvider: { try await rates.rate(asOf: $0) })
        let account = store.accounts.first { $0.name == "欧易" }!
        let wallet = store.accounts.first { $0.name == "自有钱包" }!
        let base = Date().addingTimeInterval(-86400)
        let conversion = try PurchaseConversion.make(amountCNY: 500, rate: syntheticRate(asOf: base))
        let buy = LedgerEntry(date: base, sequence: 1, kind: .buy, toAccountID: account.id, receivedSats: 1_000_000, amountCNY: 500, conversion: conversion)
        let transfer = LedgerEntry(date: base.addingTimeInterval(1), sequence: 2, kind: .transfer, fromAccountID: account.id, toAccountID: wallet.id, amountSats: 500_000, receivedSats: 495_000, note: "合成转移")
        try store.saveEntry(buy); try store.saveEntry(transfer)
        var pricedFixture = store.document
        pricedFixture.lastPrice = PriceQuote(priceUSD: 90_000, source: "合成离线美元市价")
        try store.commit(pricedFixture)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let small = NSSize(width: 600, height: 420)
        let cases: [(String, LedgerPanel.Destination)] = [
            ("buy-small", .entry(.buy, buy)),
            ("transfer-small", .entry(.transfer, transfer)),
            ("detail-small", .detail(transfer)),
            ("rules-small", .rules)
        ]
        for (name, destination) in cases {
            let probe = PanelProbe()
            let window = host(ProbeScene(probe: probe, panel: LedgerPanel(destination: destination)), store: store, size: small)
            try snapshot(window, name: name)
            if case .entry = destination { checkDateTimePicker(in: window, label: name) }
            let before = store.document
            if let close = closeButton(in: window) {
                record(controlFits(close, in: window), "\(name): close button fits minimum window")
                close.performClick(nil); settle()
                record(probe.dismissals == 1 && !probe.visible && store.document == before, "\(name): native close cancels without saving")
            } else { record(false, "\(name): close button discoverable") }
            window.close()
        }
        let dark = host(ProbeScene(probe: PanelProbe(), panel: LedgerPanel(destination: .entry(.buy, buy))), store: store, size: NSSize(width: 1000, height: 650), dark: true)
        try snapshot(dark, name: "buy-dark"); dark.close()
        for (name, entry) in [("buy", buy), ("transfer", transfer)] {
            let cancelled = PanelProbe()
            let cancelledWindow = host(ProbeScene(probe: cancelled, panel: LedgerPanel(destination: .entry(entry.kind, entry))), store: store, size: small)
            if let cancel = button("取消", in: cancelledWindow) {
                let before = store.document
                record(controlFits(cancel, in: cancelledWindow), "\(name): cancel button fits minimum window")
                cancel.performClick(nil); settle()
                record(cancelled.dismissals == 1 && !cancelled.visible && store.document == before, "\(name): cancel leaves ledger unchanged")
            } else { record(false, "\(name): cancel button discoverable") }
            cancelledWindow.close()
            let saved = PanelProbe()
            let savedWindow = host(ProbeScene(probe: saved, panel: LedgerPanel(destination: .entry(entry.kind, entry))), store: store, size: small)
            if let picker = nativeDatePickers(savedWindow.contentView!).first {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
                picker.dateValue = calendar.dateInterval(of: .minute, for: entry.date)!.start
                _ = NSApp.sendAction(picker.action!, to: picker.target, from: picker)
            }
            if let save = button("保存记录", in: savedWindow) {
                record(controlFits(save, in: savedWindow), "\(name): save button fits minimum window")
                save.performClick(nil); settle()
                record(saved.dismissals == 1 && !saved.visible && store.entries.count == 2 && store.document.entries.contains(entry), "\(name): reconfirming the visible minute preserves exact Date, amounts and fixed conversion without a duplicate")
            } else { record(false, "\(name): save button discoverable") }
            savedWindow.close()
        }
        let escaped = PanelProbe()
        let escapedWindow = host(ProbeScene(probe: escaped, panel: LedgerPanel(destination: .entry(.buy, buy))), store: store, size: small)
        if let close = closeButton(in: escapedWindow) {
            record(close.keyEquivalent == "\u{1b}", "panel close retains native Esc shortcut")
            let before = store.document
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: escapedWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            let handled = escapedWindow.performKeyEquivalent(with: event)
            settle()
            record(handled && escaped.dismissals == 1 && store.document == before, "Esc in owned window cancels without saving")
        }
        escapedWindow.close()
        let failed = PanelProbe()
        let failedWindow = host(ProbeScene(probe: failed, panel: LedgerPanel(destination: .entry(.buy, nil))), store: store, size: small)
        if let save = button("保存记录", in: failedWindow) {
            let before = store.document
            save.performClick(nil); settle()
            record(failed.visible && failed.dismissals == 0 && store.document == before, "invalid purchase save keeps panel open and ledger unchanged")
            if let alert = failedWindow.attachedSheet { failedWindow.endSheet(alert, returnCode: .cancel); alert.close() }
        } else { record(false, "invalid save control discoverable") }
        failedWindow.close()

        let actual = host(ContentView(), store: store, size: NSSize(width: 1100, height: 800))
        waitForChart(in: actual)
        try snapshot(actual, name: "actual-home")
        checkDashboardFit(actual, label: "default-1100x800", minimumPlotHeight: 375)
        let initialNodes = accessibilityNodes(actual.contentView!)
        if let balance = initialNodes.first(where: { $0.accessibilityIdentifier() == "dashboard.balance" }) {
            record(!initialNodes.contains { $0.accessibilityIdentifier() == "dashboard.accounts" }, "account balances are collapsed by default")
            record(balance.accessibilityPerformPress(), "total BTC control accepts native accessibility press")
            settle()
            record(accessibilityNodes(actual.contentView!).contains { $0.accessibilityIdentifier() == "dashboard.accounts" }, "clicking total BTC expands account balances")
            try snapshot(actual, name: "actual-home-expanded")
            record(balance.accessibilityPerformPress(), "total BTC control accepts second press")
            settle()
            record(!accessibilityNodes(actual.contentView!).contains { $0.accessibilityIdentifier() == "dashboard.accounts" }, "clicking total BTC again collapses account balances")
        } else { report.append("SCOPE hidden test windows do not expose pure SwiftUI balance controls through accessibility; verify account expansion in the installed app.") }
        logButtons(actual, label: "actual-home")
        if let buyNode = initialNodes.first(where: { $0.accessibilityIdentifier() == "dashboard.buy" }) {
            _ = buyNode.accessibilityPerformPress()
        } else if let buyButton = nativeButtons(actual.contentView!).filter({
            $0.isEnabled && !($0 is NSPopUpButton) && $0.bounds.width > 60
        }).sorted(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }).first {
            // Hidden NSHostingView does not expose every SwiftUI identifier.
            // Purchase is the leftmost native action control, at either size.
            buyButton.performClick(nil)
        }
        settle()
        try snapshot(actual, name: "actual-home-after-buy")
        record(store.isPresentingPanel, "ContentView purchase opens production overlay")
        let disabledChartInputs = nativeChartInputs(actual.contentView!)
        let disabledSnapshots = disabledChartInputs.map(\.snapshot)
        record(disabledChartInputs.count == 2 && disabledChartInputs.allSatisfy {
            !$0.inputEnabled && $0.hitTest($0.frame.center) == nil
        }, "purchase overlay disables both native plot and price-axis hit testing")
        for input in disabledChartInputs {
            let center = input.convert(input.bounds.center, to: nil)
            let gesture = QAMagnifyEvent(window: actual, location: center, phase: .changed, magnification: 1)
            record(input.routeLocalEvent(gesture) === gesture, "disabled \(input.area) leaves owned magnify event unclaimed")
            input.magnify(with: gesture)
            input.mouseDown(with: mouseEvent(.leftMouseDown, window: actual, location: center, clicks: 2))
        }
        settle()
        record(disabledChartInputs.map(\.snapshot) == disabledSnapshots,
               "native gesture and price-axis reset cannot change chart state behind purchase overlay")
        if let cancel = button("取消", in: actual) {
            record(cancel.isEnabled, "overlay cancel remains enabled with disabled background")
            let before = store.entries.count
            cancel.performClick(nil); settle()
            record(!store.isPresentingPanel && store.entries.count == before, "ContentView cancel resets presentation and creates no entry")
            record(disabledChartInputs.allSatisfy(\.inputEnabled) && disabledChartInputs.map(\.snapshot) == disabledSnapshots,
                   "cancel restores both native chart inputs without changing their viewport")
        } else { record(false, "production overlay cancel discoverable") }
        actual.close()
        // The installed 1147×719 window has about 675 points of content after
        // native chrome. This smaller content fixture is the stricter check.
        let actualSize = host(ContentView(), store: store, size: NSSize(width: 1147, height: 675))
        waitForChart(in: actualSize)
        try snapshot(actualSize, name: "actual-home-1147x675")
        checkDashboardFit(actualSize, label: "actual-content-1147x675", minimumPlotHeight: 250)
        actualSize.close()
        let compactDashboard = host(ContentView(), store: store, size: small)
        waitForChart(in: compactDashboard)
        try snapshot(compactDashboard, name: "actual-home-600x420")
        try checkCompactDashboardScroll(compactDashboard)
        compactDashboard.close()
        let mediumDashboard = host(ContentView(), store: store, size: NSSize(width: 900, height: 675))
        waitForChart(in: mediumDashboard)
        try checkCompactDashboardScroll(mediumDashboard, label: "medium-900x675", snapshotName: "actual-home-900x675-scrolled")
        mediumDashboard.close()
        let darkDashboard = host(ContentView(), store: store, size: NSSize(width: 1147, height: 675), dark: true)
        waitForChart(in: darkDashboard)
        try snapshot(darkDashboard, name: "actual-home-dark-1147x675")
        checkDashboardFit(darkDashboard, label: "dark-content-1147x675", minimumPlotHeight: 250)
        darkDashboard.close()
        try checkChartDetailsState(store: store)
        try checkChartResizeState(store: store)
        try checkChartCombinationMatrix(store: store)
        try checkChartRequestSwitching()
        try checkChartAutomaticRetry()
        checkNativeInputGestureBoundaries()
        for kind in EntryKind.allCases {
            let window = host(ProbeScene(probe: PanelProbe(), panel: LedgerPanel(destination: .entry(kind, nil))), store: store, size: NSSize(width: 800, height: 650))
            record(nativeDatePickers(window.contentView!).first.map { $0.dateValue.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 } == true,
                   "\(kind.rawValue): new form starts at an exact minute without hidden seconds")
            let nodes = accessibilityNodes(window.contentView!)
            for node in nodes where node.accessibilityIdentifier()?.hasPrefix("entry.") == true {
                report.append("FIELD \(kind.rawValue) \(node.accessibilityIdentifier() ?? ""): label=\(node.accessibilityLabel() ?? "") value=\(String(describing: node.accessibilityValue()))")
            }
            let popups = nativePopups(window.contentView!).sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
            for popup in popups { report.append("POPUP \(kind.rawValue): selected=\(popup.indexOfSelectedItem) items=\(popup.numberOfItems)") }
            record(popups.count == (kind == .buy ? 1 : 2), "\(kind.rawValue): form contains exactly the required account selectors")
            try snapshot(window, name: "\(kind.rawValue)-defaults")
            window.close()
        }
        report.append("SCOPE SwiftUI popup menus are populated lazily; selected account labels must be verified from the default-form renders or in the installed app.")
        checkMetricOrdering()
        checkCurrencySaving(store: store, rates: rates, buy: buy, transfer: transfer)
        record(QAOfflineProtocol.attempts.count == 0, "fresh synthetic market cache renders chart without any network attempt")
        try checkDailyProfitUI()
        try checkDailyStoreScheduling()
        try checkSidebarOrdering()
        report.append("\(report.filter { $0.hasPrefix("PASS ") }.count) panel checks passed.")
        report.append("Only harness-owned NSWindows receive local native callbacks and key-equivalent events; fixture data is synthetic and isolated.")
        print(report.filter { $0.hasPrefix("BUTTON ") || $0.hasPrefix("POPUP ") || $0.hasPrefix("SCOPE ") }.joined(separator: "\n"))
        try report.joined(separator: "\n").write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        if report.contains(where: { $0.hasPrefix("FAIL ") }) { exit(1) }
    }

    @MainActor static func host<V: View>(_ view: V, store: AppStore, size: NSSize, dark: Bool = false) -> NSWindow {
        let content = view.environmentObject(store).environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .defaultAppStorage(preferences)
            .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded(); settle(); hosting.layoutSubtreeIfNeeded()
        return window
    }
    @MainActor static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
    @MainActor static func nativeButtons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { nativeButtons($0) } }
    @MainActor static func nativePopups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { nativePopups($0) } }
    @MainActor static func nativeDatePickers(_ view: NSView) -> [NSDatePicker] { (view as? NSDatePicker).map { [$0] } ?? view.subviews.flatMap { nativeDatePickers($0) } }
    @MainActor static func nativeScrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { nativeScrollViews($0) } }
    @MainActor static func nativeChartInputs(_ view: NSView) -> [BTCChartInputView] { (view as? BTCChartInputView).map { [$0] } ?? view.subviews.flatMap { nativeChartInputs($0) } }
    @MainActor static func nativePlotInputs(_ view: NSView) -> [BTCChartInputView] { nativeChartInputs(view).filter { $0.area == .plot } }
    @MainActor static func nativePriceAxisInputs(_ view: NSView) -> [BTCChartInputView] { nativeChartInputs(view).filter { $0.area == .priceAxis } }
    @MainActor static func nativeViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { nativeViews($0) } }
    @MainActor static func mouseEvent(_ type: NSEvent.EventType, window: NSWindow, location: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    static func syntheticRate(asOf date: Date) -> USDExchangeRate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return USDExchangeRate(date: calendar.startOfDay(for: date).addingTimeInterval(-86_400),
                               cnyPerUSD: 7, source: "合成离线历史汇率")
    }
    @MainActor static func checkDateTimePicker(in window: NSWindow, label: String) {
        guard let picker = nativeDatePickers(window.contentView!).first else {
            record(false, "\(label): native timestamp picker discoverable")
            return
        }
        record(picker.datePickerStyle == .textFieldAndStepper
               && picker.datePickerElements == [.yearMonthDay, .hourMinute]
               && picker.timeZone?.identifier == "Asia/Shanghai" && controlFits(picker, in: window),
               "\(label): native Shanghai date and hour-minute fields fit minimum window without a seconds control")
    }
    @MainActor @discardableResult static func runAsync(_ action: @escaping @MainActor () async throws -> Void) -> Error? {
        let result = QAAsyncResult()
        let task = Task {
            do { try await action() } catch { result.error = error }
            result.finished = true
        }
        for _ in 0..<40 { if result.finished { break }; settle() }
        if !result.finished {
            task.cancel()
            record(false, "isolated async currency check completes within six seconds")
            return UIError.text("synthetic async check timed out")
        }
        return result.error
    }
    @MainActor static func checkCurrencySaving(store: AppStore, rates: QARateProbe, buy: LedgerEntry, transfer: LedgerEntry) {
        let error = runAsync {
            record(await rates.dates.isEmpty, "unchanged purchase form saves reuse fixed USD conversion without requesting a rate")
            record(store.snapshot?.totalInvestedUSD == buy.amountUSD && Display.money(buy.amountUSD).hasPrefix("$")
                   && Display.cny(buy.amountCNY).hasPrefix("¥"), "USD totals and display use the fixed conversion while preserving original CNY")
            var btcEdit = buy
            btcEdit.receivedSats += 1; btcEdit.amountSats += 1; btcEdit.conversion = nil
            try await store.saveEntryResolvingCurrency(btcEdit)
            let reusedDates = await rates.dates
            record(store.document.entries.first(where: { $0.id == buy.id })?.conversion == buy.conversion
                   && reusedDates.isEmpty, "BTC-only purchase editing preserves fixed USD amount and historical rate")
            try store.saveEntry(buy)
            var cashEdit = buy
            cashEdit.amountCNY = 700; cashEdit.conversion = nil
            try await store.saveEntryResolvingCurrency(cashEdit)
            let convertedDates = await rates.dates
            record(store.document.entries.first(where: { $0.id == buy.id })?.amountUSD == 100
                   && store.snapshot?.totalInvestedUSD == 100 && convertedDates.count == 1,
                   "changed CNY input asynchronously fetches a historical rate and fixes the resulting USD investment")
            try store.saveEntry(buy)
            await rates.configure(fails: true)
        }
        record(error == nil, "synthetic purchase conversion and preserved-rate edits complete successfully")

        let failed = PanelProbe()
        let failedWindow = host(ProbeScene(probe: failed, panel: LedgerPanel(destination: .entry(.buy, buy))), store: store, size: NSSize(width: 600, height: 420))
        let before = store.document
        if let picker = nativeDatePickers(failedWindow.contentView!).first,
           let save = button("保存记录", in: failedWindow) {
            let editedDate = LedgerDateTimePicker.minuteDate(buy.date.addingTimeInterval(-60))
            picker.dateValue = editedDate
            _ = NSApp.sendAction(picker.action!, to: picker.target, from: picker)
            save.performClick(nil); settle(); settle()
            record(failed.visible && failed.dismissals == 0 && store.document == before && picker.dateValue == editedDate,
                   "historical-rate failure keeps the native timestamp draft open and leaves the ledger unchanged")
            _ = runAsync {
                record((await rates.dates).last == editedDate,
                       "failed purchase reaches the historical-rate provider with its edited timestamp")
            }
            if let alert = failedWindow.attachedSheet { failedWindow.endSheet(alert, returnCode: .cancel); alert.close() }
        } else { record(false, "purchase failure fixture has native date and save controls") }
        failedWindow.close()

        _ = runAsync { await rates.configure(delay: 2_000_000_000) }
        let cancelled = PanelProbe()
        let cancelledWindow = host(ProbeScene(probe: cancelled, panel: LedgerPanel(destination: .entry(.buy, buy))), store: store, size: NSSize(width: 600, height: 420))
        if let picker = nativeDatePickers(cancelledWindow.contentView!).first,
           let save = button("保存记录", in: cancelledWindow), let cancel = button("取消", in: cancelledWindow) {
            let requestedDate = LedgerDateTimePicker.minuteDate(buy.date.addingTimeInterval(-120))
            picker.dateValue = requestedDate
            _ = NSApp.sendAction(picker.action!, to: picker.target, from: picker)
            save.performClick(nil); settle()
            let loadingButtons = nativeButtons(cancelledWindow.contentView!)
            let currentSave = loadingButtons.first { $0.keyEquivalent == "\r" }
            let currentPicker = nativeDatePickers(cancelledWindow.contentView!).first
            var requestsWhileLoading = 0
            _ = runAsync {
                let requested = await rates.dates
                requestsWhileLoading = requested.count
                record(requested.last == requestedDate,
                       "loading purchase reaches the synthetic provider before cancellation")
            }
            let currentCancel = currentSave.flatMap { saveButton in
                let saveRect = saveButton.convert(saveButton.bounds, to: nil)
                return loadingButtons.filter {
                    let rect = $0.convert($0.bounds, to: nil)
                    return $0.isEnabled && rect.width > 40 && abs(rect.midY - saveRect.midY) < 25 && rect.minX < saveRect.minX
                }.max { $0.convert($0.bounds, to: nil).maxX < $1.convert($1.bounds, to: nil).maxX }
            }
            report.append("LOADING oldSaveEnabled=\(save.isEnabled) currentSaveEnabled=\(String(describing: currentSave?.isEnabled)) cancelEnabled=\(String(describing: currentCancel?.isEnabled)) pickerEnabled=\(String(describing: currentPicker?.isEnabled))")
            try? snapshot(cancelledWindow, name: "buy-loading")
            record(currentSave?.isEnabled == false && currentCancel?.isEnabled == true && currentPicker?.isEnabled == false,
                   "currency request disables duplicate save and editing while native cancel stays enabled")
            currentSave?.performClick(nil); settle()
            _ = runAsync {
                record((await rates.dates).count == requestsWhileLoading,
                       "repeated native save while FX is pending cannot start another request")
            }
            (currentCancel ?? cancel).performClick(nil)
            for _ in 0..<5 { settle() }
            record(cancelled.dismissals == 1 && store.document == before,
                   "cancel during the historical-rate request prevents any later ledger commit")
        } else { record(false, "purchase cancellation fixture has native date, save and cancel controls") }
        cancelledWindow.close()

        _ = runAsync { await rates.configure() }
        let timestamp = PanelProbe()
        let timestampWindow = host(ProbeScene(probe: timestamp, panel: LedgerPanel(destination: .entry(.transfer, transfer))), store: store, size: NSSize(width: 600, height: 420))
        if let picker = nativeDatePickers(timestampWindow.contentView!).first,
           let save = button("保存记录", in: timestampWindow) {
            let editedDate = LedgerDateTimePicker.minuteDate(transfer.date.addingTimeInterval(180.125))
            picker.dateValue = editedDate
            _ = NSApp.sendAction(picker.action!, to: picker.target, from: picker)
            save.performClick(nil); settle()
            record(timestamp.dismissals == 1 && store.document.entries.first(where: { $0.id == transfer.id })?.date == editedDate,
                   "editing to another visible minute saves that exact minute without duplicating the record")
        } else { record(false, "transfer timestamp fixture has native date and save controls") }
        timestampWindow.close()

        let concurrencyError = runAsync {
            await rates.configure(delay: 300_000_000)
            var draft = buy
            draft.amountCNY = 800; draft.conversion = nil
            let save = Task { try await store.saveEntryResolvingCurrency(draft) }
            try await Task.sleep(nanoseconds: 60_000_000)
            var concurrent = buy
            concurrent.note = "合成并发修改"
            try store.saveEntry(concurrent)
            do {
                try await save.value
                record(false, "a same-ID edit during FX lookup cannot be overwritten")
            } catch {
                record(store.document.entries.first(where: { $0.id == buy.id }) == concurrent,
                       "a same-ID edit during FX lookup remains intact and the stale save is rejected")
            }
            try store.saveEntry(buy)

            let pending = LedgerEntry(date: buy.date.addingTimeInterval(50), sequence: 3, kind: .buy,
                                      toAccountID: buy.toAccountID, receivedSats: 1000, amountCNY: 70)
            try store.saveEntry(pending)
            record(store.snapshot?.totalInvestedUSD == nil && store.snapshot?.totalSats == 996_000,
                   "legacy purchase awaiting FX preserves BTC balances and leaves USD totals unresolved")
            let migration = Task { await store.completeCurrencyMigration() }
            try await Task.sleep(nanoseconds: 60_000_000)
            var fresh = store.document
            fresh.lastPrice = PriceQuote(priceUSD: 95_000, source: "合成并发行情")
            try store.commit(fresh)
            await migration.value
            record(store.document.entries.first(where: { $0.id == pending.id })?.amountUSD == 10
                   && store.quote?.priceUSD == 95_000 && store.snapshot?.totalInvestedUSD == buy.amountUSD.map { $0 + 10 },
                   "currency migration merges fixed USD into current records without replacing a fresh market quote")

            try store.saveEntry(pending)
            let unresolved = store.document
            await rates.configure(fails: true)
            await store.completeCurrencyMigration()
            record(store.document == unresolved && store.snapshot?.totalInvestedUSD == nil
                   && store.snapshot?.totalSats == 996_000 && store.migrationNotice != nil,
                   "failed legacy FX conversion preserves every original CNY and BTC record and reports pending USD")
        }
        record(concurrencyError == nil, "isolated asynchronous conflict and migration checks complete successfully")
    }
    @MainActor static func waitForChart(in window: NSWindow) {
        for _ in 0..<10 {
            if nativePlotInputs(window.contentView!).contains(where: { $0.snapshot != nil }) { return }
            settle(); window.contentView!.layoutSubtreeIfNeeded()
        }
    }
    @MainActor static func writeSyntheticMarketCache(in folder: URL) throws {
        let now = Date()
        let midnight = MarketHistory.utcCalendar.startOfDay(for: now)
        let references = (0..<60).map { index in
            let price = Decimal(25_000 + index * 50)
            return MarketCandle(closeDate: midnight.addingTimeInterval(-Double(89 - index) * 86_400), interval: 86_400,
                                open: price, high: price, low: price, close: price, hasOHLC: false)
        }
        let candles = (0..<30).map { index in
            let price = Decimal(85_000 + index * 100)
            return MarketCandle(closeDate: midnight.addingTimeInterval(-Double(29 - index) * 86_400), interval: 86_400,
                                open: price, high: price + 200, low: price - 200, close: price + (index.isMultiple(of: 2) ? 100 : -100))
        }
        let history = MarketHistory(range: .all, fetchedAt: now, candles: references + candles, source: "合成离线日行情")
        try JSONEncoder().encode([history]).write(to: folder.appendingPathComponent("market-history-daily-usd-v1.json"), options: .atomic)
        report.append("FIXTURE 60 synthetic early reference closes and 30 daily OHLC candles; fresh cache next to the isolated QA ledger; network blocked.")
    }
    @MainActor static func checkChartCombinationMatrix(store: AppStore) throws {
        let folder = output.appendingPathComponent("matrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let observedThrough = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        for period in MarketPeriod.allCases where period.isIntraday || period == .day {
            let seconds = period.nominalSeconds
            let first = max(MarketRange.genesisDate,
                            Date(timeIntervalSince1970: floor(observedThrough.timeIntervalSince1970 / seconds) * seconds - 15_998 * seconds))
            let bars = stride(from: first.timeIntervalSince1970, to: observedThrough.timeIntervalSince1970, by: seconds).map { timestamp in
                let end = min(observedThrough, Date(timeIntervalSince1970: timestamp + seconds))
                let value = Decimal(70_000 + Int(timestamp / seconds).quotientAndRemainder(dividingBy: 100).remainder)
                return MarketCandle(closeDate: end, interval: end.timeIntervalSince1970 - timestamp,
                    open: value, high: value + 100, low: value - 100, close: value + 20,
                    isComplete: end.timeIntervalSince1970 == timestamp + seconds)
            }
            let history = MarketHistory(range: .all, period: period, fetchedAt: now,
                candles: bars, source: "合成全周期离线行情")
            let bytes: Data
            if period == .day { bytes = try JSONEncoder().encode([history]) }
            else {
                bytes = try JSONEncoder().encode(BTCMarketCacheRecord(period: period,
                    from: first, through: now, history: history, nativeGranularity: 60))
            }
            try bytes.write(to: folder.appendingPathComponent(BTCChartModel.fileName(period: period)))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QAUnavailableMarketProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = BTCChartModel(cacheDirectory: folder, client: MarketHistoryClient(session: session))
        let cache = BTCPlotCache()
        var supported = 0, limited = 0
        let matrixError = runAsync {
            for range in MarketRange.allCases {
                for period in MarketPeriod.allCases {
                let expected = BTCChartViewport(start: range.startDate(today: now), end: now)
                let base = [60, 300, 900, 3600, 21_600].last {
                    Int(period.nominalSeconds) % $0 == 0 && Double($0) <= expected.duration
                } ?? 60
                let first = floor(expected.start.timeIntervalSince1970 / period.nominalSeconds) * period.nominalSeconds
                let last = floor(now.timeIntervalSince1970 / Double(base)) * Double(base)
                let exceeds = period.isIntraday && (ceil((last - first) / period.nominalSeconds) > 16_000
                                                    || (last - first) / Double(base) > 100_000)
                await model.load(period: period, window: expected)
                let history = model.matchingHistory(period: period, window: expected)
                if exceeds {
                    limited += 1
                    record(history == nil
                           && model.rejected == BTCChartLoad(period: period, window: expected)
                           && model.error?.contains("数据量") == true,
                           "matrix \(range.title) / \(period.title): explicit limit never substitutes the previous plot")
                } else {
                    supported += 1
                    let data = history.map { cache.data(history: $0, key: BTCPlotCacheKey(
                        historyRevision: model.historyRevision, accounts: [], entries: [], range: range,
                        period: period, window: expected, priceWindow: nil)) }
                    record(data?.window == expected && data?.period == period
                           && data?.candles.isEmpty == false && data?.visibleOHLCDomain.map {
                               data!.yDomain.lowerBound <= $0.lowerBound && data!.yDomain.upperBound >= $0.upperBound
                           } == true && model.rejected == nil,
                           "matrix \(range.title) / \(period.title): production plot uses exact selected dates and period with nonempty bars and fitted prices")
                }
                }
            }
        }
        record(matrixError == nil && supported + limited == 153,
               "all 9 time ranges x 17 periods checked: \(supported) supported and \(limited) explicitly limited combinations")
        for period in MarketPeriod.allCases {
            let expected = BTCChartViewport(start: now.addingTimeInterval(-3600), end: now)
            _ = runAsync { await model.load(period: period, window: expected) }
            let window = host(BTCChartView(expandedChart: .constant(false), range: .hour,
                period: period, today: now, model: model), store: store, size: NSSize(width: 900, height: 450))
            let plot = nativePlotInputs(window.contentView!).first?.snapshot
            let labels = Set(nativePopups(window.contentView!).map(\.title))
            let passes = labels.contains(MarketRange.hour.title) && labels.contains(period.title)
                && plot?.timeWindow == expected.start...expected.end && plot?.period == period
                && (plot?.visibleCandleCount ?? 0) > 0 && fittedOHLC(plot)
            record(passes, "native one-hour viewport / \(period.title): selections, time span, period and visible OHLC match")
            if !passes { report.append("MATRIX_DIAGNOSTIC \(period.rawValue): titles=\(labels) snapshot=\(String(describing: plot)) error=\(model.error ?? "none")") }
            if period == .hour12 || period == .year { try snapshot(window, name: "chart-short-\(period.rawValue)") }
            window.contentView = nil
            window.close()
        }
        let previous = BTCChartViewport(start: now.addingTimeInterval(-86400), end: now)
        _ = runAsync { await model.load(period: .minute, window: previous) }
        let unavailable = BTCChartViewport(start: MarketRange.genesisDate, end: MarketRange.genesisDate.addingTimeInterval(3600))
        _ = runAsync { await model.load(period: .minute, window: unavailable) }
        record(model.matchingHistory(period: .minute, window: unavailable) == nil
               && model.rejected == BTCChartLoad(period: .minute, window: unavailable)
               && QAUnavailableMarketProtocol.attempts.count == 1,
               "a failed older request cannot reuse a recent cache of the same period outside its coverage")
    }
    @MainActor static func checkDashboardFit(_ window: NSWindow, label: String, minimumPlotHeight: CGFloat) {
        let root = window.contentView!
        logChartPlotRects(window, label: label)
        guard let scroll = nativeScrollViews(root).filter({ $0.bounds.width > root.bounds.width / 2 }).max(by: { $0.bounds.width < $1.bounds.width }),
              let document = scroll.documentView else {
            record(false, "\(label): dashboard scroll container discoverable")
            return
        }
        let visibleHeight = scroll.contentView.bounds.height
        report.append("LAYOUT \(label): content=\(root.bounds.size) document=\(document.frame.size) clip=\(scroll.contentView.bounds.size)")
        record(document.frame.height <= visibleHeight + 1, "\(label): complete dashboard document fits visible height without vertical scrolling")
        let plots = nativePlotInputs(root)
        record(plots.count == 1 && plots.allSatisfy { controlFits($0, in: window) && $0.bounds.height >= minimumPlotHeight },
               "\(label): real cached chart plot occupies at least \(minimumPlotHeight) points of visible height without clipping")
        let priceAxes = nativePriceAxisInputs(root)
        record(priceAxes.count == 1 && priceAxes.allSatisfy { axis in
            guard let plot = plots.first else { return false }
            return controlFits(axis, in: window) && axis.convert(axis.bounds, to: root).minX >= plot.convert(plot.bounds, to: root).maxX - 1
        }, "\(label): independent native price input occupies only the right axis beside the plot")
        let controls = nativeButtons(scroll).filter { !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled && $0.bounds.width > 0 && $0.bounds.height > 0 }
        record(!controls.isEmpty && controls.allSatisfy { controlFits($0, in: window) }, "\(label): purchase, transfer and chart native controls fit visible content")
        let dropTypes = nativeViews(root).flatMap(\.registeredDraggedTypes).map(\.rawValue)
        if dropTypes.contains(where: { UTType($0)?.conforms(to: .text) == true }) {
            record(true, "\(label): native view hierarchy registers text drop destinations")
        } else {
            report.append("SCOPE \(label): hidden hosting window does not expose SwiftUI drag registration; native payload and guarded order logic are checked, and full drag gesture needs installed-app verification.")
        }
    }
    @MainActor static func checkCompactDashboardScroll(_ window: NSWindow, label: String = "compact-600x420",
                                                      snapshotName: String = "actual-home-600x420-scrolled") throws {
        let root = window.contentView!
        logChartPlotRects(window, label: label)
        guard let scroll = nativeScrollViews(root).filter({ $0.bounds.width > root.bounds.width / 2 }).max(by: { $0.bounds.width < $1.bounds.width }),
              let document = scroll.documentView else {
            record(false, "\(label): dashboard scroll container discoverable")
            return
        }
        record(document.frame.height > scroll.contentView.bounds.height + 1,
               "\(label): readable dashboard keeps overflowing content in a vertical scroll container")
        let actions = nativeButtons(scroll).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.isEnabled && !($0 is NSPopUpButton) && $0.bounds.width > 60
        }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        record(actions.count >= 2 && actions.prefix(2).allSatisfy { control in
            _ = control.scrollToVisible(control.bounds)
            return controlFits(control, in: window)
                && scroll.contentView.bounds.contains(control.convert(control.bounds, to: scroll.contentView))
        }, "\(label): purchase and transfer actions can be fully revealed inside the scroll viewport")
        guard let plot = nativePlotInputs(root).first else {
            record(false, "\(label): cached chart remains in scrollable dashboard")
            return
        }
        record(plot.bounds.height >= 140,
               "\(label): scrollable chart keeps at least 140 points of readable plot height")
        _ = plot.scrollToVisible(plot.bounds)
        settle()
        record(controlFits(plot, in: window)
               && scroll.contentView.bounds.contains(plot.convert(plot.bounds, to: scroll.contentView)),
               "\(label): cached chart is fully reachable inside the scroll viewport")
        logChartPlotRects(window, label: "\(label)-scrolled")
        try snapshot(window, name: snapshotName)
    }
    @MainActor static func logChartPlotRects(_ window: NSWindow, label: String) {
        let root = window.contentView!
        for (index, plot) in nativePlotInputs(root).enumerated() {
            let rect = plot.convert(plot.bounds, to: root)
            let entry = "PLOT \(label)[\(index)]: rect=\(rect) width=\(plot.bounds.width) height=\(plot.bounds.height)"
            report.append(entry)
            print(entry)
        }
    }
    @MainActor static func checkMetricOrdering() {
        let defaults: [DashboardMetric] = [.cost, .marketValue, .profit, .profitRatio]
        record(DashboardMetric.ordered(from: "") == defaults, "metric default order presents actual cash cost, current value, unrealized profit and profit ratio")
        record(DashboardMetric.storageKey == "dashboard.metricOrder.v2", "revised summary starts with its requested layout independently of legacy metric preferences")
        let recovered = DashboardMetric.ordered(from: "profitRatio,profit,profitRatio,unknown")
        record(recovered.count == defaults.count && Set(recovered).count == defaults.count
               && Array(recovered.prefix(2)) == [.profitRatio, .profit] && Set(recovered) == Set(defaults),
               "stored metric order removes duplicates and unknown IDs while retaining every required metric")
        let legacy = "marketValue,invested,cost,profit,profitRatio,purchased,loss,currentPrice"
        record(DashboardMetric.ordered(from: legacy) == [.marketValue, .cost, .profit, .profitRatio],
               "obsolete purchase-total and auxiliary IDs cannot reappear as summary metrics")
        let drag = DashboardMetricDrag(.profitRatio)
        let provider = drag.itemProvider()
        record(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
               && provider.canLoadObject(ofClass: NSString.self), "native metric drag provider supports the typed text drop API")
        let payload = QADragPayload()
        provider.loadObject(ofClass: NSString.self) { object, _ in payload.complete(object as? String) }
        for _ in 0..<10 { if payload.result.finished { break }; settle() }
        guard let loaded = payload.result.text else {
            record(false, "native metric drag payload loads successfully")
            return
        }
        record(loaded == drag.token, "native drag provider round-trips its active local token")
        guard let reordered = drag.reordered([loaded], rawOrder: "", target: .cost) else {
            record(false, "active native drag reorders its target")
            return
        }
        record(DashboardMetric.ordered(from: reordered).first == .profitRatio
               && Set(DashboardMetric.ordered(from: reordered)) == Set(defaults), "active metric drag changes placement without deleting or duplicating a value")
        record(drag.reordered(["BitcoinLedger.metric.unknown"], rawOrder: "", target: .cost) == nil
               && drag.reordered([DashboardMetricDrag(.profitRatio).token], rawOrder: "", target: .cost) == nil
               && drag.reordered([loaded, loaded], rawOrder: "", target: .cost) == nil,
               "foreign, unknown, stale-session and multiple drag tokens cannot reorder metrics")
        preferences.set(reordered, forKey: DashboardMetric.storageKey)
        let reopened = UserDefaults(suiteName: preferenceSuite)!
        record(reopened.string(forKey: DashboardMetric.storageKey) == reordered
               && DashboardMetric.ordered(from: reopened.string(forKey: DashboardMetric.storageKey) ?? "").first == .profitRatio,
               "custom metric order persists through a fresh isolated UserDefaults instance")
        preferences.removeObject(forKey: DashboardMetric.storageKey)
        record(DashboardMetric.profitColor(1) == .green && DashboardMetric.profitColor(-1) == .red
               && DashboardMetric.profitColor(0) == .primary && DashboardMetric.profitColor(nil) == .primary,
               "profit amounts and ratios use green gains, red losses and neutral zero or missing price")
    }
    static func fittedOHLC(_ state: BTCChartInputSnapshot?) -> Bool {
        guard let state, state.visibleOHLCCount > 0, let ohlc = state.visibleOHLCDomain else { return false }
        return state.priceDomain.lowerBound <= ohlc.lowerBound && state.priceDomain.upperBound >= ohlc.upperBound
    }
    static func timeSpan(_ state: BTCChartInputSnapshot) -> TimeInterval {
        state.timeWindow.upperBound.timeIntervalSince(state.timeWindow.lowerBound)
    }
    static func priceSpan(_ state: BTCChartInputSnapshot) -> Double {
        state.priceDomain.upperBound - state.priceDomain.lowerBound
    }
    @MainActor static func checkChartDetailsState(store: AppStore) throws {
        let probe = ChartSizeProbe()
        let window = host(ChartSizeScene(probe: probe), store: store, size: NSSize(width: 900, height: 600))
        defer { window.close() }
        waitForChart(in: window)
        guard let plot = nativePlotInputs(window.contentView!).first, let initial = plot.snapshot else {
            record(false, "latest-details fixture contains real cached plot")
            return
        }
        record(initial.detailsDate == nil && initial.detailsSats == store.snapshot?.totalSats
               && initial.detailsPriceUSD == store.quote?.priceUSD
               && initial.detailsInvestedUSD == store.snapshot?.totalInvestedUSD,
               "chart summary defaults to latest ledger holdings and current quote rather than the last historical close")
        let oldPoint = CGPoint(x: plot.bounds.width * 0.2, y: plot.bounds.midY)
        let oldLocation = plot.convert(oldPoint, to: nil)
        plot.mouseMoved(with: mouseEvent(.mouseMoved, window: window, location: oldLocation))
        settle()
        record(plot.snapshot?.detailsDate != nil && plot.snapshot?.detailsSats == 0
               && plot.snapshot?.detailsInvestedUSD == 0
               && plot.snapshot?.detailsPriceUSD != nil && plot.snapshot?.detailsPriceUSD != initial.detailsPriceUSD,
               "native pointer movement shows historical holdings and historical market price before the synthetic purchase")
        try snapshot(window, name: "chart-details-history")
        let exit = NSEvent.enterExitEvent(with: .mouseExited, location: oldLocation, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, trackingNumber: 0, userData: nil)!
        plot.mouseExited(with: exit)
        settle()
        record(plot.snapshot?.detailsDate == nil && plot.snapshot?.detailsSats == initial.detailsSats
               && plot.snapshot?.detailsPriceUSD == initial.detailsPriceUSD
               && plot.snapshot?.detailsInvestedUSD == initial.detailsInvestedUSD,
               "leaving the plot immediately restores latest holdings and current quote")
        plot.mouseMoved(with: mouseEvent(.mouseMoved, window: window, location: oldLocation))
        settle()
        record(plot.snapshot?.detailsDate != nil, "a second pointer movement re-enters historical inspection")
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        settle()
        record(plot.snapshot?.detailsDate == nil && plot.snapshot?.detailsSats == initial.detailsSats
               && plot.snapshot?.detailsPriceUSD == initial.detailsPriceUSD
               && plot.snapshot?.detailsInvestedUSD == initial.detailsInvestedUSD,
               "stopping the pointer inside the plot restores latest holdings and quote after the idle delay")
        try snapshot(window, name: "chart-details-latest")
    }
    @MainActor static func checkChartResizeState(store: AppStore) throws {
        let probe = ChartSizeProbe()
        let window = host(ChartSizeScene(probe: probe), store: store, size: NSSize(width: 900, height: 850))
        defer { window.close() }
        waitForChart(in: window)
        guard let plot = nativePlotInputs(window.contentView!).first,
              let axis = nativePriceAxisInputs(window.contentView!).first, let initial = plot.snapshot else {
            record(false, "chart resizing fixture contains real cached plot")
            return
        }
        // Call only the harness-owned native input's production callback.
        plot.onMagnify?(0.5, CGPoint(x: plot.bounds.midX, y: plot.bounds.midY))
        settle()
        guard let zoomed = plot.snapshot else {
            record(false, "native time zoom publishes its viewport")
            return
        }
        record(timeSpan(zoomed) < timeSpan(initial) && !zoomed.manualPriceScale && fittedOHLC(zoomed),
               "plot magnify shrinks time range while fitting every visible OHLC inside the price domain")
        plot.onPan?(plot.bounds.width * 0.4); settle()
        let panned = plot.snapshot
        record(panned?.timeWindow != zoomed.timeWindow && panned?.priceDomain != zoomed.priceDomain
               && panned?.manualPriceScale == false && fittedOHLC(panned),
               "horizontal plot pan moves time and refits the automatic price range to all visible OHLC")
        plot.onMagnify?(0.8, plot.bounds.center); settle()
        record(fittedOHLC(plot.snapshot) && plot.snapshot?.manualPriceScale == false,
               "explicit plot zoom after panning refits nonempty visible OHLC")
        let beforeAxis = plot.snapshot!
        let axisCenter = axis.convert(axis.bounds.center, to: nil)
        axis.mouseDown(with: mouseEvent(.leftMouseDown, window: window, location: axisCenter))
        axis.mouseDragged(with: mouseEvent(.leftMouseDragged, window: window,
                                         location: NSPoint(x: axisCenter.x, y: axisCenter.y + axis.bounds.height * 0.05)))
        axis.mouseUp(with: mouseEvent(.leftMouseUp, window: window, location: axisCenter))
        settle()
        let manual = plot.snapshot!
        record(manual.manualPriceScale && manual.timeWindow == beforeAxis.timeWindow
               && priceSpan(manual) < priceSpan(beforeAxis),
               "upward native price-axis drag shrinks only price range and leaves time unchanged")
        // Two callback deltas before SwiftUI redraw must accumulate, not reuse
        // the same captured price domain from the previous render.
        axis.onMagnify?(0.8, axis.bounds.center)
        axis.onMagnify?(0.8, axis.bounds.center)
        settle()
        let cumulative = plot.snapshot!
        record(cumulative.timeWindow == manual.timeWindow && cumulative.manualPriceScale
               && abs(priceSpan(cumulative) / priceSpan(manual) - 0.64) < 0.000_001,
               "consecutive price-axis zoom callbacks accumulate before a hosting-view redraw")
        plot.onMagnify?(0.8, plot.bounds.center); settle()
        let manualTimeZoom = plot.snapshot!
        record(timeSpan(manualTimeZoom) < timeSpan(cumulative)
               && manualTimeZoom.priceDomain == cumulative.priceDomain && manualTimeZoom.manualPriceScale,
               "time zoom preserves a manually adjusted price domain")
        plot.onPan?(plot.bounds.width * 0.1); settle()
        let manualPan = plot.snapshot!
        record(manualPan.timeWindow != manualTimeZoom.timeWindow
               && manualPan.priceDomain == manualTimeZoom.priceDomain && manualPan.manualPriceScale,
               "time pan preserves a manually adjusted price domain")
        axis.mouseDown(with: mouseEvent(.leftMouseDown, window: window, location: axisCenter, clicks: 2))
        settle()
        let reset = plot.snapshot!
        record(reset.timeWindow == manualPan.timeWindow && !reset.manualPriceScale && fittedOHLC(reset),
               "native price-axis double click restores visible OHLC fit without resetting the time viewport")
        let pickerIDs = Set(nativePopups(window.contentView!).map { ObjectIdentifier($0) })
        let selections = nativePopups(window.contentView!).map(\.indexOfSelectedItem)
        let commandIDs = Set(nativeButtons(window.contentView!).filter { !($0 is NSPopUpButton) }.map { ObjectIdentifier($0) })
        let plotID = ObjectIdentifier(plot)
        let originalHeight = plot.bounds.height
        try snapshot(window, name: "chart-size-zoomed")
        probe.expanded = true; settle(); window.contentView!.layoutSubtreeIfNeeded()
        record(!pickerIDs.isEmpty && Set(nativePopups(window.contentView!).map { ObjectIdentifier($0) }) == pickerIDs
               && nativePopups(window.contentView!).map(\.indexOfSelectedItem) == selections,
               "expanding chart preserves actual native picker instances and selections")
        record(!commandIDs.isEmpty && Set(nativeButtons(window.contentView!).filter { !($0 is NSPopUpButton) }.map { ObjectIdentifier($0) }) == commandIDs,
               "expanding chart preserves native navigation, zoom, reset and action button instances")
        record(nativePlotInputs(window.contentView!).first.map { ObjectIdentifier($0) == plotID && $0.bounds.height > originalHeight + 100 } == true,
               "expanding chart grows the existing native plot instead of recreating it")
        record(plot.snapshot == reset && axis.snapshot == reset,
               "expanding the existing chart preserves its real time and price viewport")
        try snapshot(window, name: "chart-size-expanded")
        probe.expanded = false; settle(); window.contentView!.layoutSubtreeIfNeeded()
        record(Set(nativePopups(window.contentView!).map { ObjectIdentifier($0) }) == pickerIDs
               && nativePopups(window.contentView!).map(\.indexOfSelectedItem) == selections
               && nativePlotInputs(window.contentView!).first.map { ObjectIdentifier($0) == plotID } == true,
               "collapsing chart retains actual picker and plot instances")
        record(Set(nativeButtons(window.contentView!).filter { !($0 is NSPopUpButton) }.map { ObjectIdentifier($0) }) == commandIDs,
               "collapsing chart preserves native navigation, zoom, reset and action button instances")
        record(plot.snapshot == reset && axis.snapshot == reset,
               "collapsing the existing chart preserves its real time and price viewport")
        try snapshot(window, name: "chart-size-collapsed")
        plot.onMagnify?(4, plot.bounds.center); settle()
        let mixedHistory = plot.snapshot!
        record(!mixedHistory.manualPriceScale && fittedOHLC(mixedHistory)
               && mixedHistory.priceDomain.upperBound > 80_000,
               "widening time fits both recent OHLC and synthetic early reference closes")
        plot.onPan?(plot.bounds.width * 0.9); settle()
        let earlyHistory = plot.snapshot!
        record(earlyHistory.timeWindow != mixedHistory.timeWindow && !earlyHistory.manualPriceScale
               && earlyHistory.visibleOHLCCount == 0 && earlyHistory.priceDomain != mixedHistory.priceDomain
               && earlyHistory.priceDomain.lowerBound > 20_000 && earlyHistory.priceDomain.upperBound < 30_000,
               "panning into reference-close history replaces the recent price scale with the lower early-market scale")
        try snapshot(window, name: "chart-early-reference-fit")
    }
    @MainActor static func checkNativeInputGestureBoundaries() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let axis = BTCChartInputView(frame: NSRect(x: 300, y: 30, width: 60, height: 220))
        axis.area = .priceAxis; root.addSubview(axis)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        let foreign = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        foreign.isReleasedWhenClosed = false
        defer { window.close(); foreign.close() }
        var magnifyAnchors: [CGPoint] = []
        var dragDeltas: [Double] = []
        axis.onMagnify = { _, anchor in magnifyAnchors.append(anchor) }
        axis.onPriceDrag = { delta, _ in dragDeltas.append(delta) }
        let first = CGPoint(x: 30, y: 45), second = CGPoint(x: 30, y: 170)
        let firstWindow = axis.convert(first, to: nil), secondWindow = axis.convert(second, to: nil)
        let outside = QAMagnifyEvent(window: window, location: CGPoint(x: 30, y: 30), phase: .changed, magnification: 0.2)
        let foreignEvent = QAMagnifyEvent(window: foreign, location: firstWindow, phase: .changed, magnification: 0.2)
        record(axis.routeLocalEvent(outside) === outside && axis.routeLocalEvent(foreignEvent) === foreignEvent
               && magnifyAnchors.isEmpty && axis.hitTest(CGPoint(x: 10, y: axis.frame.midY)) == nil,
               "price-axis input ignores magnify outside its bounds and events from a different owned window")
        _ = axis.routeLocalEvent(QAMagnifyEvent(window: window, location: firstWindow, phase: .began, magnification: 0))
        _ = axis.routeLocalEvent(QAMagnifyEvent(window: window, location: secondWindow, phase: .changed, magnification: 0.2))
        _ = axis.routeLocalEvent(QAMagnifyEvent(window: window, location: secondWindow, phase: .ended, magnification: 0))
        _ = axis.routeLocalEvent(QAMagnifyEvent(window: window, location: secondWindow, phase: .began, magnification: 0))
        _ = axis.routeLocalEvent(QAMagnifyEvent(window: window, location: firstWindow, phase: .changed, magnification: 0.2))
        _ = axis.routeLocalEvent(QAMagnifyEvent(window: window, location: firstWindow, phase: .cancelled, magnification: 0))
        record(magnifyAnchors == [first, second],
               "zero-magnification gesture boundary events preserve one axis anchor per gesture and reset it on end or cancel")
        axis.mouseDown(with: mouseEvent(.leftMouseDown, window: window, location: firstWindow))
        axis.frame.origin.y += 30
        axis.mouseDragged(with: mouseEvent(.leftMouseDragged, window: window, location: firstWindow))
        axis.mouseDragged(with: mouseEvent(.leftMouseDragged, window: window,
                                         location: CGPoint(x: firstWindow.x, y: firstWindow.y + 10)))
        axis.mouseUp(with: mouseEvent(.leftMouseUp, window: window, location: firstWindow))
        record(dragDeltas == [0, -10],
               "price-axis drag uses physical window movement and ignores a view-frame shift during the gesture")
    }
    @MainActor static func accessibilityNodes(_ value: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 30, let node = value as? any NSAccessibilityProtocol else { return [] }
        return [node] + (node.accessibilityChildren() ?? []).flatMap { accessibilityNodes($0, depth: depth + 1) }
    }
    @MainActor static func closeButton(in window: NSWindow) -> NSButton? {
        nativeButtons(window.contentView!).first { $0.keyEquivalent == "\u{1b}" }
    }
    @MainActor static func button(_ title: String, in window: NSWindow) -> NSButton? {
        let all = nativeButtons(window.contentView!)
        if let exact = all.first(where: { $0.title == title }) { return exact }
        // The short form is centered in large windows. Find its default-action
        // button, then the native cancel control immediately to its left.
        guard let save = all.first(where: { $0.isEnabled && $0.keyEquivalent == "\r" }) else { return nil }
        if title == "保存记录" { return save }
        let saveRect = save.convert(save.bounds, to: nil)
        return all.filter { control in
            let rect = control.convert(control.bounds, to: nil)
            return control.isEnabled && rect.width > 40 && abs(rect.midY - saveRect.midY) < 25 && rect.minX < saveRect.minX
        }.max { $0.convert($0.bounds, to: nil).maxX < $1.convert($1.bounds, to: nil).maxX }
    }
    @MainActor static func controlFits(_ control: NSView, in window: NSWindow) -> Bool {
        let rect = control.convert(control.bounds, to: window.contentView)
        return window.contentView!.bounds.contains(rect) && rect.width > 0 && rect.height > 0
    }
    @MainActor static func logButtons(_ window: NSWindow, label: String) {
        for button in nativeButtons(window.contentView!) {
            let rect = button.convert(button.bounds, to: nil)
            report.append("BUTTON \(label): '\(button.title)' enabled=\(button.isEnabled) key=\(button.keyEquivalent.debugDescription) rect=\(rect)")
        }
    }
    @MainActor static func record(_ pass: Bool, _ message: String) { let text = "\(pass ? "PASS" : "FAIL") \(message)"; report.append(text); print(text) }
    @MainActor static func snapshot(_ window: NSWindow, name: String) throws {
        let view = window.contentView!; view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        print("RENDER \(name)")
    }
}
