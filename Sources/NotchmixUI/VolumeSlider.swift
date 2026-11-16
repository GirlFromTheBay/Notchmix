import SwiftUI

/// Layout constants for the panel, taken from Control Center's modules.
enum Metrics {
    static let panelWidth: CGFloat = 300
    static let horizontalPadding: CGFloat = 14
    static let sliderHeight: CGFloat = 22
    static let appIconSize: CGFloat = 28
    static let rowSpacing: CGFloat = 10
    /// Inset of hover highlights from the panel edge.
    static let highlightInset: CGFloat = 6
}

/// A Control Center style volume slider: a capsule track that fills from the
/// leading edge, a speaker glyph sitting inside it, and a knob at the fill's
/// end that turns to Liquid Glass while it is held.
///
/// Dragging or clicking the track sets the level. A click on the speaker
/// glyph that does not turn into a drag toggles mute instead.
struct VolumeSlider: View {
    @Binding var value: Double
    var isMuted: Bool
    var label: String
    var onToggleMute: () -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var drag: DragState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct DragState {
        let startedOnGlyph: Bool
        let startValue: Double
        var hasMoved: Bool
    }

    /// Movement below this is a click on the glyph, not the start of a drag.
    private static let clickSlop: CGFloat = 3

    private var isPressed: Bool { drag != nil }
    private var height: CGFloat { Metrics.sliderHeight }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - height, 1)
            let knobCenter = height / 2 + travel * value

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                // The fill runs to the knob's far edge so the two read as one
                // shape at rest; held, it stops at the centre and the glass
                // knob shows the boundary through itself.
                Capsule()
                    .fill(.white)
                    .frame(width: knobCenter + (isPressed ? 0 : height / 2))
                    .opacity(isMuted ? 0.4 : 1)

                knob
                    .position(x: knobCenter, y: height / 2)

                glyph
                    .frame(width: height, height: height)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .gesture(dragGesture(travel: travel))
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isPressed)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isMuted)
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1) { Text(label) }
        }
    }

    private var knob: some View {
        Capsule()
            .fill(.white.opacity(isPressed ? 0.5 : (isMuted ? 0.75 : 1)))
            .frame(
                width: height * (isPressed ? 1.35 : 1),
                height: height * (isPressed ? 1.15 : 1)
            )
            // Standard sliders do this in the new design: the knob becomes
            // glass for as long as it is held.
            .glassEffect(isPressed ? .clear.interactive() : .identity, in: .capsule)
            .shadow(color: .black.opacity(0.16), radius: 1.5, y: 0.5)
            .overlay {
                Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
            }
    }

    private var glyph: some View {
        Image(
            systemName: isMuted || value <= 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
            variableValue: value
        )
        .font(.system(size: 10.5, weight: .semibold))
        // Always drawn on the white fill or knob, in both appearances.
        .foregroundStyle(.black.opacity(0.55))
        .contentTransition(.symbolEffect(.replace))
    }

    private func dragGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                func position(at x: CGFloat) -> Double {
                    Double(min(max((x - height / 2) / travel, 0), 1))
                }

                guard var state = drag else {
                    let onGlyph = gesture.startLocation.x <= height + 2
                    drag = DragState(startedOnGlyph: onGlyph, startValue: value, hasMoved: false)
                    onEditingChanged(true)
                    // Clicking the track jumps the knob there, as the system's does.
                    if !onGlyph { value = position(at: gesture.location.x) }
                    return
                }

                if state.startedOnGlyph {
                    if !state.hasMoved {
                        guard abs(gesture.translation.width) >= Self.clickSlop else { return }
                        state.hasMoved = true
                        drag = state
                    }
                    // Started on the knob's resting place: drag relative to
                    // where it was rather than jumping.
                    value = min(max(state.startValue + Double(gesture.translation.width / travel), 0), 1)
                } else {
                    value = position(at: gesture.location.x)
                }
            }
            .onEnded { _ in
                if let state = drag, state.startedOnGlyph, !state.hasMoved {
                    onToggleMute()
                }
                drag = nil
                onEditingChanged(false)
            }
    }
}
