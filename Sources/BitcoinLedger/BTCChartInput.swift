import AppKit
import SwiftUI

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

    func makeNSView(context: Context) -> BTCChartInputView { BTCChartInputView() }
    func updateNSView(_ view: BTCChartInputView, context: Context) {
        view.inputEnabled = isEnabled
        view.onHover = onHover; view.onPan = onPan
        view.onMagnify = onMagnify; view.onStep = onStep
        view.onDismissDetails = onDismissDetails
    }
    static func dismantleNSView(_ view: BTCChartInputView, coordinator: ()) { view.removeEventMonitor() }
}

final class BTCChartInputView: NSView {
    var inputEnabled = true {
        didSet {
            if !inputEnabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
    }
    var onHover: ((CGPoint?) -> Void)?
    var onPan: ((Double) -> Void)?
    var onMagnify: ((Double, CGPoint) -> Void)?
    var onStep: ((Int) -> Void)?
    var onDismissDetails: (() -> Void)?
    private var eventMonitor: Any?
    private var mouseTracking: NSTrackingArea?
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
            if !inside {
                onDismissDetails?()
                if window.firstResponder === self { window.makeFirstResponder(nil) }
            }
        case .scrollWheel:
            if inside, BTCChartInputMath.horizontalDelta(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                                        precise: event.hasPreciseScrollingDeltas) != nil {
                scrollWheel(with: event)
                return nil
            }
        case .magnify:
            if inside, BTCChartInputMath.zoomFactor(magnification: event.magnification) != nil {
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
    override func mouseDragged(with event: NSEvent) { if inputEnabled { onHover?(point(event)) } }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) {
        guard inputEnabled else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        onHover?(point(event))
    }
    override func scrollWheel(with event: NSEvent) {
        guard inputEnabled, let delta = BTCChartInputMath.horizontalDelta(
            x: event.scrollingDeltaX, y: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas) else {
            super.scrollWheel(with: event); return
        }
        onPan?(delta)
    }
    override func magnify(with event: NSEvent) {
        guard inputEnabled, let factor = BTCChartInputMath.zoomFactor(magnification: event.magnification) else {
            super.magnify(with: event); return
        }
        onMagnify?(factor, point(event))
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
