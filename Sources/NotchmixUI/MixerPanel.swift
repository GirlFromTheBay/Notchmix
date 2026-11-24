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
            if let player = model.activeMediaPlayer {
                PanelDivider()
                MediaControls(player: player, model: model)
            }
            PanelDivider()
            PanelButton("Start at Login", isChecked: model.launchAtLogin) {
                model.toggleLaunchAtLogin()
            }
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
            if model.devices.count > 1 {
                Menu {
                    ForEach(model.devices) { device in
                        Button {
                            model.selectOutputDevice(uid: device.id)
                        } label: {
                            if device.isDefault {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.output?.name ?? "Sound")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
            } else {
                Text(model.output?.name ?? "Sound")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }

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
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    AppRow(app: .systemSounds, model: model)
                }
                .padding(.top, 4)

                Text("No apps are playing audio")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.horizontalPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        } else if model.apps.count + 1 > Self.maxVisibleApps {
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
            AppRow(app: .systemSounds, model: model)
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
        let routedName = app.id == SystemSounds.id ? nil : model.routedDeviceName(for: app.id)
        let canRoute = app.id != SystemSounds.id && (model.devices.count > 1 || routedName != nil)

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
                HStack(spacing: 6) {
                    title
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    if canRoute {
                        Menu {
                            routeMenuItems
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "airplayaudio")
                                    .font(.system(size: 9.5, weight: .medium))
                                if let routedName {
                                    Text(routedName)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                }
                            }
                            .foregroundStyle(routedName != nil ? .primary : .secondary)
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.plain)
                        .help(routedName.map { "Output: \($0)" } ?? "Choose output device for \(app.name)")
                    }
                }

                VolumeSlider(
                    value: Binding(
                        get: { model.setting(for: app.id).volume },
                        set: { model.setVolume($0, for: app.id) }
                    ),
                    isMuted: setting.isMuted,
                    peak: Double(app.id == SystemSounds.id ? model.systemSoundsPeak : app.peak),
                    label: "\(app.name) volume",
                    onToggleMute: { model.toggleMute(for: app.id) }
                )
                .onHover { model.hover(.app(app.id), $0) }
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .contextMenu {
            if canRoute {
                routeMenuItems
            }
        }
        .animation(.snappy(duration: 0.2), value: setting.isMuted)
    }

    @ViewBuilder
    private var routeMenuItems: some View {
        let selectedUID = model.setting(for: app.id).outputDeviceUID
        Button {
            model.setOutputDevice(nil, for: app.id)
        } label: {
            if selectedUID == nil {
                Label("Default Output", systemImage: "checkmark")
            } else {
                Text("Default Output")
            }
        }
        if !model.devices.isEmpty {
            Divider()
            ForEach(model.devices) { device in
                Button {
                    model.setOutputDevice(device.id, for: app.id)
                } label: {
                    if selectedUID == device.id {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        }
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

/// Previous, play or pause, and next for Spotify or Apple Music.
private struct MediaControls: View {
    let player: MediaPlayer
    let model: MixerModel

    var body: some View {
        let isPlaying = model.isActiveMediaPlaying
        HStack(spacing: 2) {
            if let icon = model.mediaIcon(for: player) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 6)
            }
            Text(player.displayName)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            TransportButton(symbol: "backward.fill", label: "Previous track") {
                model.sendMediaCommand(.previous, to: player)
            }
            TransportButton(
                symbol: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play"
            ) {
                model.sendMediaCommand(.playPause, to: player)
            }
            TransportButton(symbol: "forward.fill", label: "Next track") {
                model.sendMediaCommand(.next, to: player)
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
    var isChecked: Bool? = nil
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, isChecked: Bool? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isChecked = isChecked
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                if let isChecked {
                    Image(systemName: isChecked ? "checkmark" : "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .opacity(isChecked ? 1 : 0)
                }
            }
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
