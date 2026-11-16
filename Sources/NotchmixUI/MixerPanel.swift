import AppKit
import NotchmixCore
import SwiftUI

/// The menu bar panel: master volume, one row per app that is playing,
/// Spotify's transport buttons while Spotify is running, and Quit.
///
/// It draws no background of its own. The popover that hosts it supplies the
/// system's Liquid Glass, so the panel follows whatever transparency and
/// tint the user has chosen in System Settings.
public struct MixerPanel: View {
    @Bindable private var model: MixerModel

    /// Rows beyond this scroll instead of growing the panel.
    private static let maxVisibleApps = 8

    public init(model: MixerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masterSection
            PanelDivider()
            appsSection
            if model.needsPermission {
                PanelDivider()
                PermissionNotice()
            }
            if model.isSpotifyRunning {
                PanelDivider()
                SpotifyControls(model: model)
            }
            PanelDivider()
            PanelButton("Quit Notchmix") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .padding(.bottom, Metrics.highlightInset)
        }
        .padding(.top, 12)
        .frame(width: Metrics.panelWidth)
    }

    // MARK: Master

    @ViewBuilder
    private var masterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.output?.name ?? "Sound")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            if model.output?.hasVolumeControl == true {
                VolumeSlider(
                    value: Binding(
                        get: { model.masterVolume },
                        set: { model.setMasterVolume($0) }
                    ),
                    isMuted: model.isMasterMuted,
                    label: "Output volume",
                    onToggleMute: { model.toggleMasterMute() },
                    onEditingChanged: { model.setEditingMaster($0) }
                )
                .onHover { model.hover(.master, $0) }
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.bottom, 10)
    }

    // MARK: Apps

    @ViewBuilder
    private var appsSection: some View {
        if model.apps.isEmpty {
            Text("No apps are playing audio")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, 10)
        } else if model.apps.count > Self.maxVisibleApps {
            ScrollView {
                appRows
            }
            .frame(height: CGFloat(Self.maxVisibleApps) * AppRow.height + 8)
        } else {
            appRows
        }
    }

    private var appRows: some View {
        VStack(spacing: 0) {
            ForEach(model.apps) { app in
                AppRow(app: app, model: model)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One app: its icon (click to mute), its name, and its volume slider.
private struct AppRow: View {
    let app: MixerApp
    let model: MixerModel

    static let height: CGFloat = 50

    /// "Safari" alone, or "Safari  youtube, roll20" when the browser can say
    /// which sites are playing. The sites are what the eye is looking for, so
    /// they take the stronger colour.
    private var title: Text {
        let name = Text(app.name).foregroundStyle(.secondary)
        guard let detail = app.detail, !detail.isEmpty else { return name }
        return Text("\(name)  \(Text(detail).foregroundStyle(.primary))")
    }

    var body: some View {
        let setting = model.setting(for: app.id)

        HStack(spacing: Metrics.rowSpacing) {
            Button {
                model.toggleMute(for: app.id)
            } label: {
                Image(nsImage: model.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Metrics.appIconSize, height: Metrics.appIconSize)
                    .saturation(setting.isMuted ? 0 : 1)
                    .opacity(setting.isMuted ? 0.45 : 1)
            }
            .buttonStyle(PressScaleButtonStyle())
            .help(setting.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(setting.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")

            VStack(alignment: .leading, spacing: 4) {
                title
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                VolumeSlider(
                    value: Binding(
                        get: { model.setting(for: app.id).volume },
                        set: { model.setVolume($0, for: app.id) }
                    ),
                    isMuted: setting.isMuted,
                    label: "\(app.name) volume",
                    onToggleMute: { model.toggleMute(for: app.id) }
                )
                .onHover { model.hover(.app(app.id), $0) }
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(height: Self.height)
        .animation(.snappy(duration: 0.2), value: setting.isMuted)
    }
}

/// Shown when taps cannot be used. Audio is unaffected meanwhile.
private struct PermissionNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Per-app volume needs System Audio Recording access.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 4)

            PanelButton("Open Privacy Settings…") {
                let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
            }
        }
    }
}

/// Previous, play or pause, and next for Spotify.
private struct SpotifyControls: View {
    let model: MixerModel

    var body: some View {
        HStack(spacing: 2) {
            if let icon = model.spotifyIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 6)
            }
            Text("Spotify")
                .font(.system(size: 13))
            Spacer(minLength: 8)
            TransportButton(symbol: "backward.fill", label: "Previous track") {
                model.sendSpotify(.previous)
            }
            TransportButton(
                symbol: model.isSpotifyPlaying ? "pause.fill" : "play.fill",
                label: model.isSpotifyPlaying ? "Pause" : "Play"
            ) {
                model.sendSpotify(.playPause)
            }
            TransportButton(symbol: "forward.fill", label: "Next track") {
                model.sendSpotify(.next)
            }
        }
        .padding(.leading, Metrics.horizontalPadding)
        .padding(.trailing, Metrics.horizontalPadding - 6)
        .frame(height: 32)
    }
}

/// A glyph button with a round hover highlight and a physical press.
private struct TransportButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: Shared pieces

private struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 4)
    }
}

/// A full-width text row that highlights on hover, like "Sound Settings…"
/// at the bottom of the system's Sound module.
private struct PanelButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.horizontalPadding - Metrics.highlightInset)
                .frame(height: 26)
                .background {
                    // Concentric with the panel where the system exposes its
                    // shape, with a sensible radius where it does not.
                    ConcentricRectangle(corners: .concentric(minimum: .fixed(7)), isUniform: true)
                        .fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.highlightInset)
        .onHover { isHovered = $0 }
    }
}

/// Gives the app icon a physical press without drawing button chrome.
private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension MixerModel {
    /// Tracks the slider under the pointer. Leaving one slider only clears
    /// the target if the pointer has not already entered another.
    func hover(_ target: SliderTarget, _ inside: Bool) {
        if inside {
            hoveredSlider = target
        } else if hoveredSlider == target {
            hoveredSlider = nil
        }
    }
}
