import AppKit

/// Turns scroll-wheel and trackpad scrolling over a slider into level changes.
///
/// SwiftUI has no scroll-wheel event on macOS, so this watches the app's own
/// scroll events while the panel is open. It sees nothing from other apps.
@MainActor
final class ScrollWheelMonitor {
    private var monitor: Any?

    /// - Parameter handler: Receives a signed change in slider position and
    ///   returns whether a slider consumed it.
    func start(handler: @escaping @MainActor (Double) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let delta = Self.sliderDelta(for: event)
            guard delta != 0 else { return event }
            let consumed = MainActor.assumeIsolated { handler(delta) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Up or right raises the level, whatever the "natural scrolling" setting.
    nonisolated static func sliderDelta(for event: NSEvent) -> Double {
        sliderDelta(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            isPrecise: event.hasPreciseScrollingDeltas,
            isInverted: event.isDirectionInvertedFromDevice
        )
    }

    nonisolated static func sliderDelta(
        deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool, isInverted: Bool
    ) -> Double {
        // Undo natural scrolling so the result follows the fingers or wheel.
        let up = isInverted ? -deltaY : deltaY
        let right = isInverted ? deltaX : -deltaX
        let movement = abs(up) >= abs(right) ? up : right
        // A trackpad reports points; a wheel reports lines. Roughly 250 points
        // of travel, or 25 wheel notches, cover the whole slider.
        let scale: CGFloat = isPrecise ? 1.0 / 250 : 1.0 / 25
        return Double(min(max(movement * scale, -0.2), 0.2))
    }
}
