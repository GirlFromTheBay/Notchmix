import AppKit
import NotchmixCore
import Observation

/// Which slider the pointer is over, for scroll-wheel adjustment.
public enum SliderTarget: Hashable, Sendable {
    case master
    case app(String)
}

/// The panel's state, on the main actor.
///
/// It owns the per-app settings (and saves them); the engine keeps a mirror
/// so it can apply them to apps that start playing later. Slider values are
/// written here first and sent to the engine second, so a drag never waits
/// on, or gets overwritten by, anything coming back from the audio side.
@MainActor
@Observable
public final class MixerModel {
    public private(set) var apps: [MixerApp] = []
    public private(set) var output: OutputState?
    public private(set) var needsPermission = false
    public private(set) var settings: [String: AppSetting]

    public private(set) var masterVolume: Double = 1
    public private(set) var isMasterMuted = false

    public private(set) var isSpotifyRunning = false
    public private(set) var isSpotifyPlaying = false

    @ObservationIgnored var hoveredSlider: SliderTarget?
    @ObservationIgnored private var isEditingMaster = false
    @ObservationIgnored private var isPanelVisible = false
    @ObservationIgnored private var engine: AudioEngine?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// Once Spotify has announced its state, that is more exact than
    /// inferring it from whether audio is flowing.
    @ObservationIgnored private var hasSpotifyState = false
    /// `nil` for preview models, which must never touch saved settings.
    @ObservationIgnored private let defaults: UserDefaults?

    private static let settingsKey = "AppSettings"

    /// The live model: loads saved settings and starts the audio engine.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.loadSettings(from: defaults)

        let engine = AudioEngine(settings: settings) { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
        }
        self.engine = engine
        engine.start()

        // Release every tap before exit so apps are audible again at once
        // instead of when the system notices this process is gone.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSettings()
                self?.engine?.shutdown()
            }
        }
        observeSpotify()
    }

    /// A model with fixed content and no audio engine, for layout checks.
    public init(preview snapshot: MixerSnapshot, settings: [String: AppSetting], spotifyRunning: Bool = false) {
        self.defaults = nil
        self.settings = settings
        self.isSpotifyRunning = spotifyRunning
        apply(snapshot)
    }

    // MARK: Engine updates

    private func apply(_ snapshot: MixerSnapshot) {
        apps = snapshot.apps
        output = snapshot.output
        needsPermission = snapshot.needsPermission
        // While the master slider is being dragged the pointer is the truth;
        // an echo from the device would make the knob stutter.
        if !isEditingMaster, let output = snapshot.output {
            masterVolume = Double(output.volume)
            isMasterMuted = output.isMuted
        }
        if !hasSpotifyState, let spotify = snapshot.apps.first(where: { $0.id == SpotifyRemote.bundleID }) {
            isSpotifyPlaying = spotify.isPlaying
        }
    }

    // MARK: Spotify

    var spotifyIcon: NSImage? {
        if let cached = icons[SpotifyRemote.bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyRemote.bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[SpotifyRemote.bundleID] = image
        return image
    }

    public func sendSpotify(_ command: SpotifyRemote.Command) {
        // Show the new state at once; Spotify's own announcement follows and
        // corrects it if the command did not take.
        if command == .playPause { isSpotifyPlaying.toggle() }
        SpotifyRemote.send(command)
    }

    private func observeSpotify() {
        isSpotifyRunning = SpotifyRemote.isRunning

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyRemote.bundleID else { return }
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    self?.isSpotifyRunning = launched
                    if !launched {
                        self?.isSpotifyPlaying = false
                        self?.hasSpotifyState = false
                    }
                }
            }
            observers.append((workspace, token))
        }

        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(
            forName: SpotifyRemote.stateNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let playing = SpotifyRemote.isPlaying(in: note) else { return }
            MainActor.assumeIsolated {
                self?.hasSpotifyState = true
                self?.isSpotifyPlaying = playing
            }
        }
        observers.append((distributed, token))
    }

    // MARK: Per-app control

    public func setting(for id: String) -> AppSetting {
        settings[id] ?? .default
    }

    public func setVolume(_ volume: Double, for id: String) {
        var setting = setting(for: id)
        setting.volume = min(max(volume, 0), 1)
        // Moving the slider is an unambiguous request to hear the app.
        setting.isMuted = false
        update(setting, for: id)
    }

    public func toggleMute(for id: String) {
        var setting = setting(for: id)
        setting.isMuted.toggle()
        update(setting, for: id)
    }

    private func update(_ setting: AppSetting, for id: String) {
        guard setting != self.setting(for: id) else { return }
        settings[id] = setting.isDefault ? nil : setting
        engine?.setSetting(setting, for: id)
        scheduleSave()
    }

    // MARK: Master volume

    public func setMasterVolume(_ volume: Double) {
        masterVolume = min(max(volume, 0), 1)
        engine?.setMasterVolume(Float(masterVolume))
        if isMasterMuted {
            isMasterMuted = false
            engine?.setMasterMuted(false)
        }
    }

    public func toggleMasterMute() {
        isMasterMuted.toggle()
        engine?.setMasterMuted(isMasterMuted)
    }

    func setEditingMaster(_ editing: Bool) {
        isEditingMaster = editing
    }

    // MARK: Scroll wheel

    /// Nudges whichever slider the pointer is over. Returns false when the
    /// pointer is not over a slider, so the event can continue normally.
    func scrollHoveredSlider(by delta: Double) -> Bool {
        guard let hoveredSlider else { return false }
        switch hoveredSlider {
        case .master:
            guard output?.hasVolumeControl == true else { return false }
            setMasterVolume(masterVolume + delta)
        case .app(let id):
            let current = setting(for: id)
            // Scrolling up from mute should come up from silence, not jump
            // back to the old level.
            setVolume((current.isMuted ? 0 : current.volume) + delta, for: id)
        }
        return true
    }

    // MARK: Panel lifecycle

    func panelDidAppear() {
        guard !isPanelVisible else { return }
        isPanelVisible = true
        if needsPermission { engine?.retryPermission() }
        engine?.setPanelVisible(true)
    }

    func panelDidDisappear() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        hoveredSlider = nil
        isEditingMaster = false
        engine?.setPanelVisible(false)
        flushSettings()
    }

    // MARK: Icons

    func icon(for app: MixerApp) -> NSImage {
        let key = app.bundlePath ?? ""
        if let cached = icons[key] { return cached }
        let image = app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        icons[key] = image
        return image
    }

    // MARK: Persistence

    private static func loadSettings(from defaults: UserDefaults) -> [String: AppSetting] {
        guard let data = defaults.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode([String: AppSetting].self, from: data) else {
            return [:]
        }
        return decoded.filter { !$0.value.isDefault }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushSettings()
        }
    }

    private func flushSettings() {
        saveTask?.cancel()
        saveTask = nil
        guard let defaults, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }
}
