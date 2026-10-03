import AppKit
import SwiftUI
import LedgerCore

/// NSEvent delivers a delta for each magnify event, not a gesture-total scale.
enum BTCChartInputMath {
    static func horizontalDelta(x: Double, y: Double, precise: Bool) -> Double? {
        guard x.isFinite, y.isFinite, abs(x) > abs(y), x != 0 else { return nil }
        return x * (precise ? 1 : 10)
    }
    static func zoomFactor(magnification: Double) -> Double? {
        guard magnification.isFinite, magnification != 0 else { return nil }
        return 1 / max(0.05, 1 + magnification)
    }
    static func priceDragFactor(points: Double, plotHeight: Double) -> Double {
        guard points.isFinite, plotHeight.isFinite, plotHeight > 0 else { return 1 }
        return exp(max(-4, min(4, points * 2 / plotHeight)))
    }
}

enum BTCChartInputArea { case plot, priceAxis }

struct BTCChartInputSnapshot: Equatable {
    let timeWindow: ClosedRange<Date>
    let priceDomain: ClosedRange<Double>
    let visibleOHLCCount: Int
    let visibleOHLCDomain: ClosedRange<Double>?
    let manualPriceScale: Bool
    var detailsDate: Date? = nil
    var detailsSats: Int64? = nil
    var detailsPriceUSD: Decimal? = nil
    var detailsInvestedUSD: Decimal? = nil
    var period: MarketPeriod = .day
    var visibleCandleCount: Int = 0
}

/// A plot-local responder: vertical scrolling continues to the surrounding
/// dashboard, and keyboard events are handled only after the plot is clicked.
struct BTCChartInput: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var onHover: (CGPoint?) -> Void
    var onPan: (Double) -> Void
    var onMagnify: (Double, CGPoint) -> Void
    var onStep: (Int) -> Void
    var onDismissDetails: () -> Void
    var area: BTCChartInputArea = .plot
    var onPriceDrag: ((Double, CGPoint) -> Void)? = nil
    var onPriceReset: (() -> Void)? = nil
    var snapshot: BTCChartInputSnapshot? = nil

    func makeNSView(context: Context) -> BTCChartInputView { BTCChartInputView() }
    func updateNSView(_ view: BTCChartInputView, context: Context) {
        view.inputEnabled = isEnabled
        view.onHover = onHover; view.onPan = onPan
        view.onMagnify = onMagnify; view.onStep = onStep
        view.onDismissDetails = onDismissDetails
        view.area = area; view.onPriceDrag = onPriceDrag; view.onPriceReset = onPriceReset
        view.snapshot = snapshot
    }
    static func dismantleNSView(_ view: BTCChartInputView, coordinator: ()) { view.removeEventMonitor() }
}

final class BTCChartInputView: NSView {
    var inputEnabled = true {
        didSet {
            if !inputEnabled {
                dragAnchor = nil; lastDragWindowPoint = nil; pinchAnchor = nil
                if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            }
        }
    }
    var onHover: ((CGPoint?) -> Void)?
    var onPan: ((Double) -> Void)?
    var onMagnify: ((Double, CGPoint) -> Void)?
    var onStep: ((Int) -> Void)?
    var onDismissDetails: (() -> Void)?
    var area: BTCChartInputArea = .plot
    var onPriceDrag: ((Double, CGPoint) -> Void)?
    var onPriceReset: (() -> Void)?
    var snapshot: BTCChartInputSnapshot?
    private var eventMonitor: Any?
    private var mouseTracking: NSTrackingArea?
    private var dragAnchor: CGPoint?
    private var lastDragWindowPoint: CGPoint?
    private var pinchAnchor: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { inputEnabled }

    override func hitTest(_ point: NSPoint) -> NSView? {
        inputEnabled ? super.hitTest(point) : nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeEventMonitor()
        guard window != nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            return self.routeLocalEvent(event)
        }
    }
    /// SwiftUI's surrounding ScrollView may claim gesture events before the
    /// representable's responder. Route only gestures inside this plot once.
    func routeLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard inputEnabled, let window, event.window === window else { return event }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        switch event.type {
        case .leftMouseDown:
            if !inside, area == .plot {
                onDismissDetails?()
                if window.firstResponder === self { window.makeFirstResponder(nil) }
            }
        case .scrollWheel:
            if inside, area == .plot, BTCChartInputMath.horizontalDelta(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                                        precise: event.hasPreciseScrollingDeltas) != nil {
                scrollWheel(with: event)
                return nil
            }
        case .magnify:
            if inside {
                magnify(with: event)
                return nil
            }
        default: break
        }
        return event
    }

    func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self)
        addTrackingArea(area); mouseTracking = area
    }
    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    override func mouseEntered(with event: NSEvent) { if inputEnabled { onHover?(point(event)) } }
    override func mouseMoved(with event: NSEvent) { if inputEnabled { onHover?(point(event)) } }
    override func mouseDragged(with event: NSEvent) {
        guard inputEnabled else { return }
        let current = point(event)
        if area == .priceAxis, let dragAnchor, let lastDragWindowPoint {
            onPriceDrag?(lastDragWindowPoint.y - event.locationInWindow.y, dragAnchor)
            self.lastDragWindowPoint = event.locationInWindow
        } else { onHover?(current) }
    }
    override func mouseUp(with event: NSEvent) { dragAnchor = nil; lastDragWindowPoint = nil }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) {
        guard inputEnabled else { super.mouseDown(with: event); return }
        if area == .priceAxis {
            if event.clickCount == 2 { onPriceReset?(); dragAnchor = nil; lastDragWindowPoint = nil }
            else { dragAnchor = point(event); lastDragWindowPoint = event.locationInWindow }
            return
        }
        window?.makeFirstResponder(self)
        onHover?(point(event))
    }
    override func scrollWheel(with event: NSEvent) {
        guard inputEnabled, area == .plot, let delta = BTCChartInputMath.horizontalDelta(
            x: event.scrollingDeltaX, y: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas) else {
            super.scrollWheel(with: event); return
        }
        onPan?(delta)
    }
    override func magnify(with event: NSEvent) {
        guard inputEnabled else {
            super.magnify(with: event); return
        }
        let current = point(event)
        if area == .priceAxis {
            if event.phase == .began || pinchAnchor == nil { pinchAnchor = current }
            if let factor = BTCChartInputMath.zoomFactor(magnification: event.magnification) {
                onMagnify?(factor, pinchAnchor ?? current)
            }
            if event.phase == .ended || event.phase == .cancelled || event.phase.isEmpty { pinchAnchor = nil }
        } else if let factor = BTCChartInputMath.zoomFactor(magnification: event.magnification) {
            onMagnify?(factor, current)
        }
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard inputEnabled, modifiers.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123: onStep?(-1)
        case 124: onStep?(1)
        default: super.keyDown(with: event)
        }
    }
}
