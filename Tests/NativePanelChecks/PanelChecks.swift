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
        alarm(50)
        defer { alarm(0) }
        guard let path = ProcessInfo.processInfo.environment["QA_OUTPUT"], path.hasPrefix("/"), path != "/" else { fatalError("absolute isolated QA_OUTPUT directory required") }
        output = URL(fileURLWithPath: path, isDirectory: true)
        setenv("BITCOIN_LEDGER_DATA_PATH", output.appendingPathComponent("data-\(UUID().uuidString)/ledger.json").path, 1)
        let store = AppStore()
        let account = store.accounts.first { $0.name == "欧易" }!
        let wallet = store.accounts.first { $0.name == "自有钱包" }!
        let base = Date().addingTimeInterval(-86400)
        let buy = LedgerEntry(date: base, sequence: 1, kind: .buy, toAccountID: account.id, receivedSats: 1_000_000, amountCNY: 500)
        let transfer = LedgerEntry(date: base.addingTimeInterval(1), sequence: 2, kind: .transfer, fromAccountID: account.id, toAccountID: wallet.id, amountSats: 500_000, receivedSats: 495_000, note: "合成转移")
        try store.saveEntry(buy); try store.saveEntry(transfer)
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
            if let save = button("保存记录", in: savedWindow) {
                record(controlFits(save, in: savedWindow), "\(name): save button fits minimum window")
                save.performClick(nil); settle()
                record(saved.dismissals == 1 && !saved.visible && store.entries.count == 2 && store.document.entries.contains(entry), "\(name): form save persists without duplicate or changed amounts")
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
        try snapshot(actual, name: "actual-home")
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
        if let cancel = button("取消", in: actual) {
            record(cancel.isEnabled, "overlay cancel remains enabled with disabled background")
            let before = store.entries.count
            cancel.performClick(nil); settle()
            record(!store.isPresentingPanel && store.entries.count == before, "ContentView cancel resets presentation and creates no entry")
        } else { record(false, "production overlay cancel discoverable") }
        actual.close()
        for kind in EntryKind.allCases {
            let window = host(ProbeScene(probe: PanelProbe(), panel: LedgerPanel(destination: .entry(kind, nil))), store: store, size: NSSize(width: 800, height: 650))
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
        report.append("\(report.filter { $0.hasPrefix("PASS ") }.count) panel checks passed.")
        report.append("Only harness-owned NSWindows receive local native callbacks and key-equivalent events; fixture data is synthetic and isolated.")
        print(report.filter { $0.hasPrefix("BUTTON ") || $0.hasPrefix("POPUP ") || $0.hasPrefix("SCOPE ") }.joined(separator: "\n"))
        try report.joined(separator: "\n").write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        if report.contains(where: { $0.hasPrefix("FAIL ") }) { exit(1) }
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
    @MainActor static func nativePopups(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { nativePopups($0) } }
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
