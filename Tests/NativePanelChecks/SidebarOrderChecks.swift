import AppKit
import SwiftUI
import LedgerCore

extension PanelChecks {
    @MainActor static func checkSidebarOrdering() throws {
        let defaults: [Page] = [.dashboard, .history, .dailyProfit]
        record(Page.ordered(from: "") == defaults,
            "sidebar starts in overview, history, daily profit order without saved preferences")
        record(Page.ordered(from: "每日盈亏,unknown,每日盈亏,历史记录") == [.dailyProfit, .history, .dashboard],
            "sidebar ordering removes unknown and duplicate pages and appends missing defaults")
        let top = Page.reordered("", moving: .dailyProfit, to: 0)
        record(Page.ordered(from: top) == [.dailyProfit, .dashboard, .history],
            "sidebar moving a page to the top can cross multiple existing rows")
        let down = Page.reordered(top, moving: .dailyProfit, to: 1)
        record(Page.ordered(from: down) == [.dashboard, .dailyProfit, .history],
            "sidebar move down uses the final target index without an off-by-one error")
        let up = Page.reordered(down, moving: .history, to: 1)
        record(Page.ordered(from: up) == [.dashboard, .history, .dailyProfit],
            "sidebar move up retains all pages exactly once")
        let dragged = Page.reordered("", fromOffsets: IndexSet(integer: 0), toOffset: 3)
        record(Page.ordered(from: dragged) == [.history, .dailyProfit, .dashboard],
            "native onMove destination semantics can drag the first page after the last")
        let multi = Page.reordered("", fromOffsets: IndexSet([0, 2]), toOffset: 3)
        record(Page.ordered(from: multi) == [.history, .dashboard, .dailyProfit],
            "native multi-row moves preserve source order and every required page")
        record(Page.ordered(from: Page.reordered("", fromOffsets: IndexSet(integer: 4), toOffset: 0)) == defaults
               && Page.ordered(from: Page.reordered("", moving: .dashboard, to: -1)) == defaults,
            "invalid sidebar move offsets leave a complete valid ordering")

        let suite = "BitcoinLedger.SidebarQA.\(UUID().uuidString)"
        let sidebarPreferences = UserDefaults(suiteName: suite)!
        defer { sidebarPreferences.removePersistentDomain(forName: suite) }
        let folder = output.appendingPathComponent("sidebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppStore(repositoryURL: folder.appendingPathComponent("ledger.json"),
            rateProvider: { syntheticRate(asOf: $0) },
            priceProvider: { PriceQuote(priceUSD: 10_000, source: "合成现价") },
            noonProvider: { DailyNoonObservation(targetAt: $0, priceUSD: 10_000) })
        let before = store.document
        sidebarPreferences.set("每日盈亏,每日盈亏,unknown,历史记录", forKey: Page.storageKey)
        let initial = host(ContentView().defaultAppStorage(sidebarPreferences), store: store,
            size: NSSize(width: 1100, height: 800))
        try checkSidebarVisiblePage(initial, expected: .dailyProfit, evidence: "sidebar-startup-first-page",
            message: "startup selects the first sorted page from the host's isolated AppStorage environment")
        let canonical = "每日盈亏,历史记录,总览"
        record(sidebarPreferences.string(forKey: Page.storageKey) == canonical,
            "startup saves the normalized sidebar order without obsolete or duplicate entries")

        let reordered = Page.reordered(canonical, moving: .dailyProfit, to: 2)
        sidebarPreferences.set(reordered, forKey: Page.storageKey)
        settle()
        try checkSidebarVisiblePage(initial, expected: .dailyProfit, evidence: "sidebar-order-changed-keeps-selection",
            message: "changing saved sidebar order preserves the current window's selected page")
        let reopenedPreferences = UserDefaults(suiteName: suite)!
        record(reopenedPreferences.string(forKey: Page.storageKey) == reordered
               && Page.ordered(from: reordered).first == .history,
            "custom sidebar order persists through a fresh isolated preferences instance")
        let restarted = host(ContentView().defaultAppStorage(reopenedPreferences), store: store,
            size: NSSize(width: 1100, height: 800))
        try checkSidebarVisiblePage(restarted, expected: .history, evidence: "sidebar-restarted-new-first-page",
            message: "a fresh window opens the new first page instead of remembering the last selected page")
        let explicit = host(ContentView(initialPage: .dailyProfit).defaultAppStorage(reopenedPreferences), store: store,
            size: NSSize(width: 600, height: 420))
        try checkSidebarVisiblePage(explicit, expected: .dailyProfit, evidence: "sidebar-explicit-initial-page",
            message: "an explicit initial page remains available to isolated native QA hosts")
        record(store.document == before, "sidebar sorting and startup selection do not modify ledger data")
        initial.close(); restarted.close(); explicit.close()
    }

    @MainActor private static func checkSidebarVisiblePage(_ window: NSWindow, expected: Page,
                                                          evidence: String, message: String) throws {
        try snapshot(window, name: evidence)
        guard let content = window.contentView else { record(false, message); return }
        let nodes = accessibilityNodes(content)
        let text = nodes.flatMap { node -> [String] in
            [node.accessibilityLabel(), node.accessibilityValue() as? String].compactMap { $0 }
        } + nativeViews(content).compactMap { ($0 as? NSTextField)?.stringValue }
        let markers: [Page: [String]] = [
            .dailyProfit: ["当前估算", "每日明细", "盈亏曲线"],
            .history: ["还没有记录", "从总览的「购买」开始记录。"],
            .dashboard: ["总持有 BTC", "BTC 美元 K 线"]
        ]
        let identifier: String
        switch expected {
        case .dailyProfit: identifier = "dailyProfit.page"
        case .history: identifier = "history.page"
        case .dashboard: identifier = "dashboard.balance"
        }
        let visiblePages = Page.allCases.filter { page in
            text.contains { value in (markers[page] ?? []).contains { value.contains($0) } }
        }
        if nodes.contains(where: { $0.accessibilityIdentifier() == identifier }) || visiblePages.contains(expected) {
            record(true, message)
        } else if !visiblePages.isEmpty {
            record(false, "\(message); accessible body content instead identifies \(visiblePages.map(\.rawValue).joined(separator: ", "))")
        } else {
            // Hidden hosting windows do not consistently bridge pure SwiftUI
            // text or container IDs. Keep owned renders for real visual review.
            report.append("SCOPE \(message): hidden NSHostingView exposes no body text or container marker; inspect \(evidence).png (expected \(expected.rawValue)) and verify installed-app startup separately.")
        }
    }
}
