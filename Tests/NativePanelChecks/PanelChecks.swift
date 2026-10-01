import SwiftUI
import AppKit
import Darwin
import LedgerCore

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

@main struct PanelChecks {
    @MainActor static var output: URL!
    @MainActor static var report: [String] = []
    @MainActor static func main() throws {
        alarm(30)
        defer { alarm(0) }
        guard let path = ProcessInfo.processInfo.environment["QA_OUTPUT"], path.hasPrefix("/"), path != "/" else { fatalError("absolute isolated QA_OUTPUT directory required") }
        output = URL(fileURLWithPath: path, isDirectory: true)
        setenv("BITCOIN_LEDGER_DATA_PATH", output.appendingPathComponent("data-\(UUID().uuidString)/ledger.json").path, 1)
        let store = AppStore()
        let account = Account(name: "合成交易所", kind: .exchange)
        let wallet = Account(name: "合成钱包", kind: .selfCustody)
        try store.saveAccount(account); try store.saveAccount(wallet)
        let base = Date().addingTimeInterval(-86400)
        var u = LedgerEntry(date: base, sequence: 1, kind: .buyUSDT)
        u.amountCNY = 720; u.receivedUSDT = 100; u.feeValuationSource = .costBasis
        try store.saveEntry(u)
        var buy = LedgerEntry(date: base.addingTimeInterval(1), sequence: 2, kind: .buy)
        buy.settlementCurrency = .usdt; buy.amountUSDT = 20; buy.amountSats = 100_000; buy.toAccountID = account.id
        buy.feeValuationSource = .costBasis
        try store.saveEntry(buy)
        let adjustment = try store.prepareUSDTAdjustment(to: Decimal(string: "80.2")!, note: "合成手续费返还", date: base.addingTimeInterval(2))
        try store.saveEntry(adjustment.entry)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let small = NSSize(width: 600, height: 420)
        let cases: [(String, LedgerPanel.Destination)] = [
            ("buy-small", .entry(.buy, buy)),
            ("transfer-small", .entry(.transfer, nil)),
            ("adjustment-small", .entry(.adjustUSDT, adjustment.entry)),
            ("account-small", .account(account))
        ]
        for (name, destination) in cases {
            let probe = PanelProbe()
            let window = host(ProbeScene(probe: probe, panel: LedgerPanel(destination: destination)), store: store, size: small)
            try snapshot(window, name: name)
            logButtons(window, label: name)
            if let cancel = button("取消", in: window) {
                let before = store.document
                cancel.performClick(nil); settle()
                record(probe.dismissals == 1 && !probe.visible && store.document == before, "\(name): native cancel closes without saving")
            } else { report.append("LIMIT \(name): SwiftUI cancel has no discoverable native NSButton") }
            window.close()
        }
        let dark = host(ProbeScene(probe: PanelProbe(), panel: LedgerPanel(destination: .entry(.buy, buy))), store: store, size: NSSize(width: 1000, height: 650), dark: true)
        try snapshot(dark, name: "buy-dark"); dark.close()

        let savedProbe = PanelProbe()
        let savedWindow = host(ProbeScene(probe: savedProbe, panel: LedgerPanel(destination: .entry(.adjustUSDT, adjustment.entry))), store: store, size: small)
        if let save = button("保存记录", in: savedWindow) {
            save.performClick(nil); settle()
            record(savedProbe.dismissals == 1 && !savedProbe.visible && store.entries.count == 3, "native save on valid adjustment closes after successful persistence")
        } else { report.append("LIMIT save: no discoverable native NSButton") }
        savedWindow.close()

        let failedProbe = PanelProbe()
        let failedWindow = host(ProbeScene(probe: failedProbe, panel: LedgerPanel(destination: .entry(.buy, nil))), store: store, size: small)
        if let save = button("保存记录", in: failedWindow) {
            let before = store.document
            save.performClick(nil); settle()
            record(failedProbe.visible && failedProbe.dismissals == 0 && store.document == before, "invalid save keeps panel open and leaves ledger unchanged")
            if let alert = failedWindow.attachedSheet {
                failedWindow.endSheet(alert, returnCode: .cancel); alert.close()
            }
        } else { report.append("LIMIT failed save: no discoverable native NSButton") }
        failedWindow.close()

        let outside = PanelProbe()
        let outsideWindow = host(ProbeScene(probe: outside, panel: LedgerPanel(destination: .entry(.buy, buy))), store: store, size: small)
        clickOwnWindow(outsideWindow, at: NSPoint(x: 30, y: 45))
        record(outside.visible && outside.dismissals == 0, "clicking blank space inside card keeps panel open")
        clickOwnWindow(outsideWindow, at: NSPoint(x: 5, y: 5))
        if outside.visible {
            report.append("LIMIT backdrop: hidden NSHostingView did not dispatch its pure SwiftUI button from local mouse events; no end-to-end backdrop result claimed")
        } else { record(outside.dismissals == 1 && outside.backgroundActions == 0, "clicking backdrop cancels once without triggering background button") }
        outsideWindow.close()

        let actual = host(ContentView(), store: store, size: NSSize(width: 1100, height: 800))
        try snapshot(actual, name: "actual-home")
        logButtons(actual, label: "actual-home")
        // In our owned ContentView the production buy control occupies the
        // first large action card below the hero. NSWindow coordinates are local.
        if let buyButton = nativeButtons(actual.contentView!).filter({ $0.isEnabled && $0.bounds.width > 200 }).sorted(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }).first {
            buyButton.performClick(nil)
        }
        settle()
        try snapshot(actual, name: "actual-home-after-buy")
        logButtons(actual, label: "actual-home-after-buy")
        record(store.isPresentingPanel, "actual ContentView buy action opens production overlay")
        if let cancel = button("取消", in: actual) {
            record(cancel.isEnabled, "actual overlay cancel is enabled despite disabled background")
            let before = store.entries.count
            cancel.performClick(nil); settle()
            record(!store.isPresentingPanel && store.entries.count == before, "actual ContentView cancel resets presentation and creates no entry")
        } else { report.append("LIMIT actual overlay cancel: no native NSButton") }
        actual.close()
        report.append("\(report.filter { $0.hasPrefix("PASS ") }.count) panel checks passed.")
        report.append("Only harness-owned NSWindows receive direct local events. No AX, global event posting, real ledger access, or installed-app interaction.")
        report.append("Scope: native callbacks and owned-window hit testing; keyboard focus/Esc and interactions in the installed app are not automatically verified.")
        try report.joined(separator: "\n").write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
        if report.contains(where: { $0.hasPrefix("FAIL ") || $0.hasPrefix("LIMIT ") }) { exit(1) }
    }

    @MainActor static func host<V: View>(_ view: V, store: AppStore, size: NSSize, dark: Bool = false) -> NSWindow {
        let content = view.environmentObject(store).environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "zh_CN"))
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
    @MainActor static func button(_ title: String, in window: NSWindow) -> NSButton? {
        let all = nativeButtons(window.contentView!)
        if let exact = all.first(where: { $0.title == title }) { return exact }
        // SwiftUI hosts the label separately, so these NSButtons have empty
        // titles. Locate the two enabled footer controls by their native frames.
        let footer = all.filter { button in
            let rect = button.convert(button.bounds, to: nil)
            return button.isEnabled && rect.minY >= 0 && rect.maxY < 100 && rect.width > 40
        }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        guard footer.count == 2 else { return nil }
        return title == "取消" ? footer.first : footer.last
    }
    @MainActor static func logButtons(_ window: NSWindow, label: String) {
        for button in nativeButtons(window.contentView!) {
            let rect = button.convert(button.bounds, to: nil)
            report.append("BUTTON \(label): '\(button.title)' enabled=\(button.isEnabled) rect=\(rect)")
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
    @MainActor static func clickOwnWindow(_ window: NSWindow, at point: NSPoint) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0),
              let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        // AppKit controls may synchronously track mouse-down. Queue the matching
        // up in this process only before dispatching down to this owned window.
        NSApplication.shared.postEvent(up, atStart: true)
        if let root = window.contentView, let hit = root.hitTest(root.convert(point, from: nil)) {
            hit.mouseDown(with: down)
            hit.mouseUp(with: up)
        }
        settle()
    }
}
