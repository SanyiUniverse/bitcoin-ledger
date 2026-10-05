import AppKit
import SwiftUI
import LedgerCore

private extension CGRect {
    var dailyCenter: CGPoint { CGPoint(x: midX, y: midY) }
}

private final class QADailyChartGesture: NSEvent {
    let ownedWindow: NSWindow
    let ownedLocation: NSPoint
    let horizontal: CGFloat
    let vertical: CGFloat
    let magnificationValue: CGFloat?
    init(window: NSWindow, location: NSPoint, horizontal: CGFloat = 0, vertical: CGFloat = 0,
         magnification: CGFloat? = nil) {
        ownedWindow = window; ownedLocation = location
        self.horizontal = horizontal; self.vertical = vertical; magnificationValue = magnification
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("owned daily chart events are not archived") }
    override var type: NSEvent.EventType { magnificationValue == nil ? .scrollWheel : .magnify }
    override var window: NSWindow? { ownedWindow }
    override var locationInWindow: NSPoint { ownedLocation }
    override var scrollingDeltaX: CGFloat { horizontal }
    override var scrollingDeltaY: CGFloat { vertical }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var magnification: CGFloat { magnificationValue ?? 0 }
    override var phase: NSEvent.Phase { .changed }
}

@MainActor private final class QADailyRowsProbe: ObservableObject {
    @Published var rows: [DailyProfitRow]
    @Published var selectedDate: Date?
    @Published var selectionRevision = 0
    init(rows: [DailyProfitRow]) { self.rows = rows }
}

private struct QADailyChartScene: View {
    @ObservedObject var probe: QADailyRowsProbe
    var body: some View { DailyProfitChart(rows: probe.rows) }
}

private struct QADailyLinkedChartScene: View {
    @ObservedObject var probe: QADailyRowsProbe
    var body: some View {
        DailyProfitChart(rows: probe.rows, selection: $probe.selectedDate,
                         revealSelectionRevision: probe.selectionRevision)
    }
}

extension PanelChecks {
    @MainActor static func checkDailyProfitUI() throws {
        let folder = output.appendingPathComponent("daily-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("ledger.json")
        let store = AppStore(repositoryURL: url,
            rateProvider: { syntheticRate(asOf: $0) },
            priceProvider: { PriceQuote(priceUSD: 10_500, source: "合成美元行情") },
            noonProvider: { DailyNoonObservation(targetAt: $0, priceUSD: 10_500) })
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let firstTarget = DailyProfitEngine.calendar.date(byAdding: .day, value: -35,
            to: DailyProfitEngine.noon(on: now))!.addingTimeInterval(-3600 + 17.25)
        let purchaseDate = firstTarget
        let buy = LedgerEntry(date: purchaseDate, sequence: 1, kind: .buy, toAccountID: store.accounts[0].id,
            receivedSats: 1_000_000, amountCNY: 700,
            conversion: try PurchaseConversion.make(amountCNY: 700, rate: syntheticRate(asOf: purchaseDate)))
        let lateDate = firstTarget.addingTimeInterval(10 * 86_400 + 3600)
        let lateBuy = LedgerEntry(date: lateDate, sequence: 2, kind: .buy, toAccountID: store.accounts[0].id,
            receivedSats: 10_000, amountCNY: 14,
            conversion: try PurchaseConversion.make(amountCNY: 14, rate: syntheticRate(asOf: lateDate)))
        let boundaryDate = firstTarget.addingTimeInterval(22 * 86_400)
        let boundaryBuy = LedgerEntry(date: boundaryDate, sequence: 4, kind: .buy, toAccountID: store.accounts[0].id,
            receivedSats: 10_000, amountCNY: 14,
            conversion: try PurchaseConversion.make(amountCNY: 14, rate: syntheticRate(asOf: boundaryDate)))
        let transfer = LedgerEntry(date: firstTarget.addingTimeInterval(15 * 86_400), sequence: 3,
            kind: .transfer, fromAccountID: store.accounts[0].id, toAccountID: store.accounts[1].id,
            amountSats: 10_000, receivedSats: 9_000)
        var fixture = store.document
        fixture.exportedAt = now
        fixture.entries = [buy, lateBuy, transfer, boundaryBuy]
        fixture.lastPrice = PriceQuote(priceUSD: 10_500, fetchedAt: now, source: "合成美元行情")
        fixture.dailyNoonObservations = DailyProfitEngine.settlementTargets(entries: fixture.entries, now: now).enumerated().map { index, target in
            DailyNoonObservation(targetAt: target, priceUSD: index == 16 ? nil : Decimal(9_000 + index * 70),
                fetchedAt: now, status: index == 16 ? .missing : .available)
        }
        try store.commit(fixture)
        let rows = store.dailyProfitRows
        let points = DailyProfitChart.points(rows)
        record(Page.allCases.map(\.rawValue) == ["总览", "历史记录", "每日盈亏"],
               "sidebar orders daily profit below overview and transaction history")
        record(rows.first?.date == firstTarget && rows.count >= 35 && rows.filter { $0.profitUSD == nil }.count == 1
            && store.dailyProfitSettlementAnchor == firstTarget
            && ProfitDates.time(firstTarget) == "11:00:17"
            && ProfitDates.time(firstTarget.addingTimeInterval(-17.25)) == "11:00",
               "daily UI retains the first purchase's precise settlement timestamp and formats nonzero seconds")
        record(rows[0].purchaseEntryIDs == [buy.id] && rows[10].purchaseCount == 0
            && rows[11].purchaseEntryIDs == [lateBuy.id] && rows[22].purchaseEntryIDs == [boundaryBuy.id]
            && rows[23].purchaseCount == 0,
               "purchase-record color follows the first settlement that includes each buy, including exact cutoff and late purchases")
        record(DailyProfitView.costColor(rows[0]) == DashboardMetric.profitColor(100)
            && DailyProfitView.costColor(rows[11]) == DashboardMetric.profitColor(2)
            && DailyProfitView.costColor(rows[10]) == .primary
            && rows[15].purchaseCount == 0 && DailyProfitView.costColor(rows[15]) == .primary,
               "only settlement cost numbers with a purchase use the shared gain color; unchanged days and transfers keep the ordinary cost color")
        var unknownFX = fixture
        unknownFX.entries[1].conversion = nil
        let pendingRows = try DailyProfitEngine.rows(document: unknownFX, now: now)
        record(pendingRows[11].purchaseEntryIDs == [lateBuy.id] && pendingRows[11].costUSD == nil
            && pendingRows[11].purchaseCostChangeUSD == nil && DailyProfitView.costColor(pendingRows[11]) == .secondary,
               "purchase metadata survives missing FX while the unknown cost placeholder remains secondary")
        var removedPurchase = fixture
        removedPurchase.entries.removeAll { $0.id == boundaryBuy.id }
        let removedRows = try DailyProfitEngine.rows(document: removedPurchase, now: now)
        record(removedRows[22].purchaseCount == 0 && DailyProfitView.costColor(removedRows[22]) == .primary,
               "deleting a purchase removes the corresponding settlement cost color without a separate monitor")
        let zeroChange = DailyProfitRow(date: firstTarget, totalSats: 1_000_000, costUSD: 100,
            marketValueUSD: 100, profitUSD: 0, profitRatio: 0, status: .available,
            purchaseEntryIDs: [buy.id], purchaseCostChangeUSD: 0)
        record(DailyProfitView.costColor(zeroChange) == .primary,
               "a zero purchase-cost change retains the ordinary cost color")
        record(Set(points.map(\.segment)).count == 2 && points.count == rows.count - 1,
               "profit line uses separate series on either side of a missing daily price")
        record(rows.contains { ($0.profitUSD ?? 0) < 0 } && rows.contains { ($0.profitUSD ?? 0) > 0 },
               "synthetic profit chart includes both losses and gains around its zero reference")
        checkDailyProfitProjection(rows: rows)
        let reopened = AppStore(repositoryURL: url,
            rateProvider: { syntheticRate(asOf: $0) },
            priceProvider: { PriceQuote(priceUSD: 10_500, source: "合成美元行情") },
            noonProvider: { DailyNoonObservation(targetAt: $0, priceUSD: 10_500) })
        record(reopened.document == fixture && reopened.dailyProfitRows == rows,
               "restarting an isolated store preserves settlement prices and the same profit curve and table")
        let normal = host(ContentView(initialPage: .dailyProfit), store: store, size: NSSize(width: 1100, height: 800))
        waitForChart(in: normal)
        try snapshot(normal, name: "daily-profit-1100x800")
        try checkDailyProfitPageFit(normal, rows: rows, minimumPlotHeight: 200,
                                   label: "daily-1100x800", scrolledSnapshot: "daily-profit-table")
        try checkDailyProfitLinkedPage(normal, rows: rows, label: "daily-linked-normal")
        normal.close()
        let small = host(ContentView(initialPage: .dailyProfit), store: store, size: NSSize(width: 600, height: 420))
        waitForChart(in: small)
        try snapshot(small, name: "daily-profit-600x420")
        try checkDailyProfitPageFit(small, rows: rows, minimumPlotHeight: 120,
                                   label: "daily-600x420", scrolledSnapshot: "daily-profit-small-table")
        try checkDailyProfitLinkedPage(small, rows: rows, label: "daily-linked-small")
        small.close()
        let dark = host(ContentView(initialPage: .dailyProfit), store: store, size: NSSize(width: 1100, height: 800), dark: true)
        waitForChart(in: dark)
        try snapshot(dark, name: "daily-profit-dark")
        try checkDailyProfitPageFit(dark, rows: rows, minimumPlotHeight: 200,
                                   label: "daily-dark", scrolledSnapshot: "daily-profit-dark-table")
        dark.close()
        record(store.document == fixture && store.dailyProfitRows == rows,
               "same-screen layout and list scrolling preserve every synthetic transaction and fixed settlement price")
        try checkDailyProfitChartNavigation(rows: rows, store: store)
        try checkDailyProfitSharedSelection(rows: rows, store: store)
    }

    @MainActor private static func dailyListScroll(in window: NSWindow) -> NSScrollView? {
        let root = window.contentView!
        guard let plot = nativePlotInputs(root).first else { return nil }
        let plotRect = plot.convert(plot.bounds, to: root)
        return nativeScrollViews(root).filter {
            $0.hasVerticalScroller && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1
                && $0.convert($0.bounds, to: root).maxX <= plotRect.minX + 1
        }.max { $0.bounds.width < $1.bounds.width }
    }

    @MainActor private static func pressDailyRow(_ date: Date, in window: NSWindow) -> Bool {
        let id = "dailyProfit.row.\(ProfitDates.day(date))"
        if let node = accessibilityNodes(window.contentView!).first(where: { $0.accessibilityIdentifier() == id }),
           node.accessibilityPerformPress() { settle(); return true }
        if let button = nativeButtons(window.contentView!).first(where: { $0.accessibilityIdentifier() == id }) {
            button.performClick(nil); settle(); return true
        }
        return false
    }

    @MainActor private static func checkDailyProfitLinkedPage(_ window: NSWindow, rows: [DailyProfitRow],
                                                             label: String) throws {
        guard let plot = nativePlotInputs(window.contentView!).first, let first = rows.first?.date,
              let last = rows.last?.date, let missing = rows.first(where: { $0.profitUSD == nil }) else {
            record(false, "\(label): production linked page exposes its plot and missing-row fixture"); return
        }
        plot.onMagnify?(10_000, plot.bounds.dailyCenter); settle()
        let list = dailyListScroll(in: window)
        let previousOrigin = list?.contentView.bounds.origin
        plot.onHover?(CGPoint(x: plot.bounds.width, y: plot.bounds.midY)); settle()
        record(plot.snapshot?.detailsDate == last,
               "\(label): production plot hover selects the last exact daily record")
        if let list, let previousOrigin {
            record(list.contentView.bounds.origin != previousOrigin,
                   "\(label): plot selection automatically scrolls only the left daily list")
        } else {
            report.append("SCOPE \(label): hidden hosting bridge does not expose the daily list scroller; installed-app verification covers its automatic centering.")
        }
        if let selected = accessibilityNodes(window.contentView!).first(where: {
            $0.accessibilityIdentifier() == "dailyProfit.row.\(ProfitDates.day(last))"
        }) {
            record((selected.accessibilityValue() as? String) == "已选中",
                   "\(label): production daily row exposes the plot's shared selected state")
        } else {
            report.append("SCOPE \(label): hidden SwiftUI row accessibility bridge is absent; shared-selection render verifies the row highlight and installed-app checks cover single/double row clicks.")
        }
        let retained = plot.snapshot?.detailsDate
        plot.onHover?(nil); settle()
        record(plot.snapshot?.detailsDate == retained,
               "\(label): leaving the plot keeps its last exact row selection")
        let fraction = missing.date.timeIntervalSince(first) / last.timeIntervalSince(first)
        let point = plot.convert(NSPoint(x: plot.bounds.width * fraction, y: plot.bounds.midY), to: nil)
        plot.mouseDown(with: mouseEvent(.leftMouseDown, window: window, location: point)); settle()
        record(plot.snapshot?.detailsDate == missing.date && plot.snapshot?.detailsPriceUSD == nil
            && fittedProfit(plot.snapshot, rows: rows),
               "\(label): native plot click selects a missing-price daily row without manufacturing a chart point")
        try snapshot(window, name: label)
        plot.onMagnify?(0.25, plot.bounds.dailyCenter); plot.onPan?(-plot.bounds.width * 10_000); settle()
        let narrow = plot.snapshot!
        if pressDailyRow(missing.date, in: window) {
            record(plot.snapshot?.detailsDate == missing.date && plot.snapshot!.timeWindow.contains(missing.date)
                && abs(timeSpan(plot.snapshot!) - timeSpan(narrow)) < 0.01,
                   "\(label): pressing the already selected daily row reveals its blue-gray line while preserving zoom width")
            try snapshot(window, name: label + "-row-revealed")
        } else {
            report.append("SCOPE \(label): pure SwiftUI daily row button cannot be pressed in this hidden window; shared Binding tests cover date reveal and the installed app verifies single/double-click actions.")
        }
        checkDailyRowDoubleClick(window, rows: rows, label: label)
    }

    @MainActor private static func checkDailyRowDoubleClick(_ window: NSWindow, rows: [DailyProfitRow], label: String) {
        guard let plot = nativePlotInputs(window.contentView!).first, let scroll = dailyListScroll(in: window),
              let candidate = nativeButtons(window.contentView!).first(where: { button in
                  rows.contains { $0.date != plot.snapshot?.detailsDate
                      && button.accessibilityIdentifier() == "dailyProfit.row.\(ProfitDates.day($0.date))" }
                    && scroll.contentView.bounds.contains(button.convert(button.bounds, to: scroll.contentView))
              }), let date = rows.first(where: {
                  candidate.accessibilityIdentifier() == "dailyProfit.row.\(ProfitDates.day($0.date))"
              })?.date else {
            report.append("SCOPE \(label): hidden SwiftUI row bridge lacks a native mouse-tracking button; installed-app verification covers two clicks at the same row coordinate and the unchanged left scroll position.")
            return
        }
        let origin = scroll.contentView.bounds.origin
        let location = candidate.convert(candidate.bounds.dailyCenter, to: nil)
        let originalRect = candidate.convert(candidate.bounds, to: window.contentView)
        for count in [1, 2] {
            NSApp.postEvent(mouseEvent(.leftMouseUp, window: window, location: location, clicks: count), atStart: false)
            candidate.mouseDown(with: mouseEvent(.leftMouseDown, window: window, location: location, clicks: count))
            settle()
            record(plot.snapshot?.detailsDate == date && scroll.contentView.bounds.origin == origin
                && candidate.convert(candidate.bounds, to: window.contentView) == originalRect,
                   "\(label): click \(count) at the same row coordinate retains that date without moving the left list")
        }
    }

    @MainActor private static func checkDailyProfitProjection(rows: [DailyProfitRow]) {
        let window = rows[14].date...rows[18].date
        let data = DailyProfitChart.plotData(rows: rows, window: window)
        record(data.visibleRows.count == 5 && data.points.count == 4 && Set(data.points.map(\.segment)).count == 2
            && data.profitDomain.contains(0) && data.points.allSatisfy { data.profitDomain.contains($0.value) }
            && data.symbolSize == 22 && data.hasPrices,
               "one daily render projection retains the missing row, gap segments, exact date window and zero-fitting profit range")
        var large: [DailyProfitRow] = []
        large.reserveCapacity(2_000)
        for index in 0..<2_000 {
            let timestamp: TimeInterval = 1_600_000_000.0 + Double(index) * 86_400.0
            let missing: Bool = index % 53 == 0
            let profit: Decimal? = missing ? nil : Decimal(index % 201 - 100)
            let status: DailyProfitStatus = missing ? .missingPrice : .available
            let row = DailyProfitRow(date: Date(timeIntervalSince1970: timestamp), totalSats: 1,
                costUSD: Decimal(100), marketValueUSD: nil, profitUSD: profit, profitRatio: nil, status: status)
            large.append(row)
        }
        let full: ClosedRange<Date> = large.first!.date...large.last!.date
        let count: Int = DailyProfitChart.points(large).count
        let before = Date().timeIntervalSinceReferenceDate
        var priorCount = 0
        for _ in 0..<count { priorCount += DailyProfitChart.points(large).filter { full.contains($0.date) }.count }
        let oldSeconds = Date().timeIntervalSinceReferenceDate - before
        let after = Date().timeIntervalSinceReferenceDate
        let projected = DailyProfitChart.plotData(rows: large, window: full)
        var sharedCount = 0
        for _ in projected.points { sharedCount += projected.points.count }
        let newSeconds = Date().timeIntervalSinceReferenceDate - after
        let sameWorkCount: Bool = priorCount == sharedCount
        let denseSymbols: Bool = projected.symbolSize == CGFloat(8)
        let sameRows: Bool = projected.visibleRows.count == large.count
        let samePoints: Bool = projected.points.count == count
        record(sameWorkCount && denseSymbols && sameRows && samePoints,
               "a large synthetic daily projection preserves point counts while dense symbols reuse one computed count")
        let benchmark = String(format: "BENCH daily projection, %d synthetic rows: per-point rescan %.3f ms, shared render %.3f ms, identical count %d",
                               large.count, oldSeconds * 1000, newSeconds * 1000, sharedCount)
        report.append(benchmark); print(benchmark)
    }

    @MainActor private static func checkDailyProfitSharedSelection(rows: [DailyProfitRow], store: AppStore) throws {
        let before = store.document
        let probe = QADailyRowsProbe(rows: rows)
        let window = host(QADailyLinkedChartScene(probe: probe), store: store, size: NSSize(width: 900, height: 500))
        defer { window.close() }
        waitForChart(in: window)
        guard let plot = nativePlotInputs(window.contentView!).first, let first = rows.first,
              let missing = rows.first(where: { $0.profitUSD == nil }) else {
            record(false, "shared daily selection exposes native input"); return
        }
        plot.onMagnify?(0.25, plot.bounds.dailyCenter); settle()
        let narrow = plot.snapshot!
        probe.selectedDate = first.date; settle()
        record(plot.snapshot?.detailsDate == first.date && plot.snapshot!.timeWindow.contains(first.date)
            && abs(timeSpan(plot.snapshot!) - timeSpan(narrow)) < 0.01,
               "table-style shared selection reveals an offscreen first record without changing date zoom width")
        probe.selectedDate = missing.date; settle()
        record(plot.snapshot?.detailsDate == missing.date && plot.snapshot?.detailsPriceUSD == nil
            && plot.snapshot!.timeWindow.contains(missing.date) && fittedProfit(plot.snapshot, rows: rows),
               "shared selection reveals a missing record's blue-gray rule and original accounting detail across its gap")
        let visible = rows.filter { plot.snapshot!.timeWindow.contains($0.date) && $0.profitUSD != nil }
        if let hoverRow = visible.first, let clickRow = visible.last {
            let current = plot.snapshot!
            let hoverFraction = hoverRow.date.addingTimeInterval(17).timeIntervalSince(current.timeWindow.lowerBound) / timeSpan(current)
            plot.onHover?(CGPoint(x: plot.bounds.width * hoverFraction, y: plot.bounds.midY)); settle()
            record(probe.selectedDate == hoverRow.date && plot.snapshot?.detailsDate == hoverRow.date,
                   "plot hover publishes the nearest actual daily row ID rather than a raw pixel timestamp")
            let clickFraction = clickRow.date.timeIntervalSince(plot.snapshot!.timeWindow.lowerBound) / timeSpan(plot.snapshot!)
            let clickPoint = plot.convert(NSPoint(x: plot.bounds.width * clickFraction, y: plot.bounds.midY), to: nil)
            plot.mouseDown(with: mouseEvent(.leftMouseDown, window: window, location: clickPoint)); settle()
            record(probe.selectedDate == clickRow.date && plot.snapshot?.detailsInvestedUSD == clickRow.costUSD,
                   "native plot click updates the shared table date and preserves its original cost")
            let selected = probe.selectedDate
            plot.onHover?(nil); settle()
            record(probe.selectedDate == selected, "hover exit does not clear shared daily selection or jump the table")
            plot.onPan?(plot.bounds.width * 10_000); settle()
            let panned = plot.snapshot!
            probe.selectionRevision &+= 1; settle()
            record(plot.snapshot!.timeWindow.contains(clickRow.date) && abs(timeSpan(plot.snapshot!) - timeSpan(panned)) < 0.01,
                   "a repeated table selection reveals its date after a manual pan while retaining the same zoom width")
            try snapshot(window, name: "daily-profit-shared-reveal")
            let nextDate = rows.last!.date.addingTimeInterval(86_400)
            probe.rows.append(DailyProfitRow(date: nextDate, totalSats: clickRow.totalSats, costUSD: clickRow.costUSD,
                marketValueUSD: clickRow.marketValueUSD, profitUSD: clickRow.profitUSD,
                profitRatio: clickRow.profitRatio, status: .available)); settle()
            record(probe.selectedDate == selected, "appending a day preserves a valid shared daily selection")
            probe.rows.removeAll { $0.date == selected }; settle()
            record(probe.selectedDate == nil, "removing the selected date clears its shared selection safely")
        } else { record(false, "linked daily zoom retains available rows for hover and click") }
        try snapshot(window, name: "daily-profit-selection-cleared")
        let missingRows = rows.map { row in
            DailyProfitRow(date: row.date, totalSats: row.totalSats, costUSD: row.costUSD,
                marketValueUSD: nil, profitUSD: nil, profitRatio: nil, status: .missingPrice,
                observation: DailyNoonObservation(targetAt: row.date, priceUSD: nil, status: .missing))
        }
        let allMissing = host(DailyProfitChart(rows: missingRows), store: store, size: NSSize(width: 900, height: 500))
        defer { allMissing.close() }
        waitForChart(in: allMissing)
        if let input = nativePlotInputs(allMissing.contentView!).first {
            input.onHover?(input.bounds.dailyCenter); settle()
            record(input.snapshot?.detailsDate != nil && input.snapshot?.detailsPriceUSD == nil
                && input.snapshot?.visibleCandleCount == 0 && input.snapshot?.priceDomain.contains(0) == true,
                   "an entirely missing-price history retains selectable dates and a zero axis without creating any points")
            try snapshot(allMissing, name: "daily-profit-all-missing")
        } else { record(false, "all-missing daily history exposes its native date-selection plot") }
        record(store.document == before && DailyProfitChart.points(rows).count == rows.count - 1,
               "linked daily selection preserves the ledger, fixed prices, accounting values and missing-price points")
    }

    @MainActor private static func checkDailyProfitPageFit(_ window: NSWindow, rows: [DailyProfitRow],
                minimumPlotHeight: CGFloat, label: String, scrolledSnapshot: String) throws {
        let root = window.contentView!
        guard let plot = nativePlotInputs(root).first, let state = plot.snapshot else {
            record(false, "\(label): same-screen daily page exposes its profit plot"); return
        }
        let plotRect = plot.convert(plot.bounds, to: root)
        report.append("DAILY_LAYOUT \(label): root=\(root.bounds) plot=\(plotRect)")
        record(controlFits(plot, in: window) && plot.bounds.height >= minimumPlotHeight
            && plot.bounds.width >= 100 && plotRect.midX > root.bounds.midX,
               "\(label): right-side profit plot fits the visible window with at least \(minimumPlotHeight) points of height")
        record(fittedProfit(state, rows: rows),
               "\(label): fitted same-screen plot includes every visible daily value and zero")
        let scrolls = nativeScrollViews(root)
        let overflow = scrolls.filter { scroll in
            scroll.hasVerticalScroller && (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 1
        }
        record(!overflow.contains { $0.convert($0.bounds, to: root).intersects(plotRect) },
               "\(label): profit plot has no surrounding page scroll that hides the other panel")
        let candidates = overflow.filter { scroll in
            let rect = scroll.convert(scroll.bounds, to: root)
            return rect.width >= 100 && rect.maxX <= plotRect.minX + 1
                && min(rect.maxY, plotRect.maxY) - max(rect.minY, plotRect.minY) >= 120
        }
        guard let scroll = candidates.max(by: { $0.bounds.width < $1.bounds.width }),
              let document = scroll.documentView else {
            report.append("SCOPE \(label): hidden SwiftUI bridge does not expose the left daily list's native scroller; verify independent list scrolling from the owned render and installed app. The visible profit plot and absence of a surrounding page scroll are checked above.")
            return
        }
        let listRect = scroll.convert(scroll.bounds, to: root)
        report.append("DAILY_LIST \(label): viewport=\(listRect) document=\(document.bounds.size)")
        record(controlFits(scroll, in: window) && listRect.maxX <= plotRect.minX + 1,
               "\(label): historical list has its own visible left-side scroll viewport beside the profit plot")
        let previousOrigin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView); settle()
        let afterRect = plot.convert(plot.bounds, to: root)
        record(scroll.contentView.bounds.origin != previousOrigin && plot.snapshot == state
            && abs(afterRect.minY - plotRect.minY) <= 1 && abs(afterRect.height - plotRect.height) <= 1,
               "\(label): scrolling daily rows moves only the list and leaves the full profit plot in place")
        try snapshot(window, name: scrolledSnapshot)
    }

    @MainActor private static func pressDailyChart(_ name: String, in window: NSWindow) -> Bool {
        let id = "dailyProfit.chart.\(name)"
        if let node = accessibilityNodes(window.contentView!).first(where: { $0.accessibilityIdentifier() == id }) {
            let pressed = node.accessibilityPerformPress()
            if pressed { settle(); return true }
        }
        let titles = ["back": "向前", "zoomIn": "放大", "zoomOut": "缩小", "reset": "重置", "forward": "向后"]
        if let control = nativeButtons(window.contentView!).first(where: {
            $0.isEnabled && ($0.accessibilityIdentifier() == id || $0.title == titles[name])
        }) {
            control.performClick(nil); settle(); return true
        }
        return false
    }

    @MainActor private static func fittedProfit(_ state: BTCChartInputSnapshot?, rows: [DailyProfitRow]) -> Bool {
        guard let state, state.priceDomain.contains(0) else { return false }
        let points = DailyProfitChart.points(rows).filter { state.timeWindow.contains($0.date) }
        return state.visibleCandleCount == points.count && points.allSatisfy { state.priceDomain.contains($0.value) }
    }

    @MainActor private static func checkDailyProfitChartNavigation(rows: [DailyProfitRow], store: AppStore) throws {
        let before = store.document
        let window = host(DailyProfitChart(rows: rows), store: store, size: NSSize(width: 900, height: 500))
        defer { window.close() }
        waitForChart(in: window)
        guard let plot = nativePlotInputs(window.contentView!).first, let initial = plot.snapshot,
              let first = rows.first?.date, let last = rows.last?.date else {
            record(false, "daily chart exposes its owned date-navigation input and snapshot"); return
        }
        record(initial.timeWindow == (first...last) && fittedProfit(initial, rows: rows),
               "daily chart starts with all history and a fitted profit axis containing zero")
        let titles: Set<String> = ["向前", "放大", "缩小", "重置", "向后"]
        let buttonBridge = pressDailyChart("zoomIn", in: window)
        if buttonBridge {
            record(true, "daily chart zoom-in button accepts a native press")
        } else {
            report.append("SCOPE hidden NSHostingView does not expose the pure SwiftUI daily-navigation buttons for native or accessibility press. Verify all five visible buttons, including reset and narrow-window wrapping, in the installed app; native plot callbacks verify the date operations below.")
            plot.onMagnify?(0.5, plot.bounds.dailyCenter); settle()
        }
        guard let zoomed = plot.snapshot else { record(false, "daily zoom publishes its date window"); return }
        record(timeSpan(zoomed) < timeSpan(initial) && fittedProfit(zoomed, rows: rows)
            && zoomed.priceDomain != initial.priceDomain,
               "date zoom limits visible days and refits profit values while retaining zero")
        if buttonBridge {
            record(pressDailyChart("forward", in: window), "daily forward button accepts a native press")
        } else { plot.onStep?(1); settle() }
        let later = plot.snapshot!
        record(later.timeWindow.lowerBound > zoomed.timeWindow.lowerBound && later.timeWindow.upperBound <= last,
               "forward date navigation moves toward newer records and stops at the last settlement")
        if buttonBridge {
            record(pressDailyChart("back", in: window), "daily back button accepts a native press")
        } else { plot.onStep?(-1); settle() }
        record(plot.snapshot!.timeWindow.lowerBound < later.timeWindow.lowerBound && fittedProfit(plot.snapshot, rows: rows),
               "back date navigation moves earlier and keeps the automatic profit fit")
        if buttonBridge {
            record(pressDailyChart("zoomOut", in: window) && plot.snapshot?.timeWindow == initial.timeWindow,
                   "zoom-out button restores the full date extent")
            record(pressDailyChart("zoomIn", in: window) && pressDailyChart("reset", in: window)
                && plot.snapshot?.timeWindow == initial.timeWindow,
                   "reset button returns a narrowed chart to all history")
        } else {
            plot.onMagnify?(2, plot.bounds.dailyCenter); settle()
            record(plot.snapshot?.timeWindow == initial.timeWindow,
                   "native zoom-out callback restores the full date extent")
            plot.onMagnify?(0.5, plot.bounds.dailyCenter); settle()
            plot.onMagnify?(10_000, plot.bounds.dailyCenter); settle()
            record(plot.snapshot?.timeWindow == initial.timeWindow,
                   "widening a narrowed native viewport clamps back to all history")
        }

        if let missing = rows.first(where: { $0.profitUSD == nil }) {
            let fraction = missing.date.timeIntervalSince(first) / last.timeIntervalSince(first)
            let local = NSPoint(x: plot.bounds.width * fraction, y: plot.bounds.midY)
            plot.onHover?(local); settle()
            record(plot.snapshot?.detailsDate == missing.date && plot.snapshot?.detailsPriceUSD == nil,
                   "hover still selects a missing daily record without supplying a price across its gap")
            let available = rows[10]
            let tapFraction = available.date.timeIntervalSince(first) / last.timeIntervalSince(first)
            let tap = plot.convert(NSPoint(x: plot.bounds.width * tapFraction, y: plot.bounds.midY), to: nil)
            plot.mouseDown(with: mouseEvent(.leftMouseDown, window: window, location: tap)); settle()
            record(plot.snapshot?.detailsDate == available.date && plot.snapshot?.detailsInvestedUSD == available.costUSD,
                   "native plot click preserves the selected day's original cost and detail")
            plot.onHover?(nil); settle()
        }
        let anchorPoint = NSPoint(x: plot.bounds.width * 0.25, y: plot.bounds.midY)
        let event = QADailyChartGesture(window: window, location: plot.convert(anchorPoint, to: nil), magnification: 1)
        record(plot.routeLocalEvent(event) == nil, "daily plot claims its own native pinch event")
        settle()
        let pinched = plot.snapshot!
        let anchor = first.addingTimeInterval(timeSpan(initial) * 0.25)
        let anchorFraction = anchor.timeIntervalSince(pinched.timeWindow.lowerBound) / timeSpan(pinched)
        record(abs(timeSpan(pinched) / timeSpan(initial) - 0.5) < 0.000_001 && abs(anchorFraction - 0.25) < 0.000_001,
               "native pinch halves the date window around the pointer's date")
        plot.onMagnify?(0.8, anchorPoint); plot.onMagnify?(0.8, anchorPoint); settle()
        let cumulative = plot.snapshot!
        record(abs(timeSpan(cumulative) / timeSpan(pinched) - 0.64) < 0.000_001,
               "consecutive daily zoom callbacks accumulate before a SwiftUI redraw")
        let vertical = QADailyChartGesture(window: window, location: plot.convert(plot.bounds.dailyCenter, to: nil), vertical: 30)
        record(plot.routeLocalEvent(vertical) === vertical && plot.snapshot == cumulative,
               "ordinary vertical scroll passes through the daily plot without panning its dates")
        let horizontal = QADailyChartGesture(window: window, location: plot.convert(plot.bounds.dailyCenter, to: nil),
                                             horizontal: plot.bounds.width * 0.2)
        record(plot.routeLocalEvent(horizontal) == nil, "daily plot claims horizontal two-finger scrolling")
        settle()
        record(plot.snapshot!.timeWindow.lowerBound < cumulative.timeWindow.lowerBound && fittedProfit(plot.snapshot, rows: rows),
               "horizontal two-finger scrolling pans the current date window and refits profit")
        plot.onMagnify?(0.001, plot.bounds.dailyCenter); settle()
        record(abs(timeSpan(plot.snapshot!) - 3 * 86_400) < 0.01,
               "long daily history cannot zoom narrower than three days")
        plot.onPan?(plot.bounds.width * 10_000); settle()
        record(plot.snapshot?.timeWindow.lowerBound == first, "daily pan clamps at the first recorded settlement")
        plot.onPan?(-plot.bounds.width * 10_000); settle()
        record(plot.snapshot?.timeWindow.upperBound == last && fittedProfit(plot.snapshot, rows: rows),
               "daily pan clamps at the last recorded settlement without changing the profit zero baseline")
        try snapshot(window, name: "daily-profit-zoomed")
        if buttonBridge {
            record(pressDailyChart("reset", in: window) && plot.snapshot?.timeWindow == initial.timeWindow,
                   "reset after native gestures restores the complete daily chart")
        } else {
            plot.onMagnify?(10_000, plot.bounds.dailyCenter); settle()
            record(plot.snapshot?.timeWindow == initial.timeWindow,
                   "native zoom-out after boundary gestures restores the complete daily chart")
        }
        try snapshot(window, name: "daily-profit-navigation-full")

        for count in [1, 2, 3] {
            let shortRows = Array(rows.prefix(count))
            let short = host(DailyProfitChart(rows: shortRows), store: store, size: NSSize(width: 350, height: 500))
            waitForChart(in: short)
            if let input = nativePlotInputs(short.contentView!).first, let full = input.snapshot {
                input.onMagnify?(0.01, input.bounds.dailyCenter); input.onPan?(input.bounds.width * 100); settle()
                record(input.snapshot?.timeWindow == full.timeWindow && timeSpan(full) > 0 && fittedProfit(input.snapshot, rows: shortRows),
                       "\(count)-day history retains its nonzero full range under zoom and pan")
                let controls = nativeButtons(short.contentView!).filter { titles.contains($0.title) }
                if controls.count == 5 {
                    record(controls.allSatisfy { controlFits($0, in: short) },
                           "daily navigation buttons wrap inside a narrow chart window")
                }
            } else { record(false, "short daily history has its native plot input") }
            if count == 1 { try snapshot(short, name: "daily-profit-single-day") }
            short.close()
        }
        let probe = QADailyRowsProbe(rows: Array(rows.prefix(20)))
        let growing = host(QADailyChartScene(probe: probe), store: store, size: NSSize(width: 900, height: 500))
        defer { growing.close() }
        waitForChart(in: growing)
        if let input = nativePlotInputs(growing.contentView!).first {
            probe.rows = rows; settle()
            record(input.snapshot?.timeWindow.upperBound == last,
                   "all-history mode automatically includes newly appended daily records")
            probe.rows = Array(rows.prefix(20)); settle()
            input.onMagnify?(0.5, input.bounds.dailyCenter); settle()
            let manual = input.snapshot!.timeWindow
            probe.rows = rows; settle()
            record(input.snapshot?.timeWindow == manual,
                   "appending records preserves a user's manually narrowed date window")
        } else { record(false, "growing daily history has its native plot input") }
        record(store.document == before && Self.pointsForDailyGap(rows) == 2,
               "date navigation leaves all fixed settlement prices, ledger data and missing-price line segments intact")
    }
    @MainActor private static func pointsForDailyGap(_ rows: [DailyProfitRow]) -> Int {
        Set(DailyProfitChart.points(rows).map(\.segment)).count
    }
}
