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
    public private(set) var devices: [OutputDeviceInfo] = []
    public private(set) var systemSoundsPeak: Float = 0
    public private(set) var needsPermission = false
    public private(set) var settings: [String: AppSetting]

    public private(set) var masterVolume: Double = 1
    public private(set) var isMasterMuted = false

    /// What we know about one media player.
    struct PlayerState {
        var isRunning = false
        var isPlaying = false
        /// Once the player has announced its state, that is more exact than
        /// inferring it from whether audio is flowing.
        var hasAnnounced = false
    }

    private(set) var players: [MediaPlayer: PlayerState] = Dictionary(
        uniqueKeysWithValues: MediaPlayer.allCases.map { ($0, PlayerState()) }
    )
    public private(set) var preferredMediaPlayer: MediaPlayer?
    public private(set) var launchAtLogin = LoginItem.isEnabled

    @ObservationIgnored var hoveredSlider: SliderTarget?
    @ObservationIgnored private var isEditingMaster = false
    @ObservationIgnored private var isPanelVisible = false
    @ObservationIgnored private var engine: AudioEngine?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
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
        observeMediaPlayers()
    }

    /// A model with fixed content and no audio engine, for layout checks.
    public init(preview snapshot: MixerSnapshot, settings: [String: AppSetting], spotifyRunning: Bool = false) {
        self.defaults = nil
        self.settings = settings
        players[.spotify]?.isRunning = spotifyRunning
        apply(snapshot)
    }

    // MARK: Engine updates

    private func apply(_ snapshot: MixerSnapshot) {
        apps = snapshot.apps
        output = snapshot.output
        devices = snapshot.devices
        systemSoundsPeak = snapshot.systemSoundsPeak
        needsPermission = snapshot.needsPermission
        // While the master slider is being dragged the pointer is the truth;
        // an echo from the device would make the knob stutter.
        if !isEditingMaster, let output = snapshot.output {
            masterVolume = Double(output.volume)
            isMasterMuted = output.isMuted
        }
        for player in MediaPlayer.allCases where players[player]?.hasAnnounced == false {
            if let app = snapshot.apps.first(where: { $0.id == player.bundleID }) {
                players[player]?.isPlaying = app.isPlaying
            }
        }
    }

    // MARK: Media transport (Spotify & Apple Music)

    public var activeMediaPlayer: MediaPlayer? {
        MediaPlayer.activePlayer(
            spotifyRunning: players[.spotify]?.isRunning ?? false,
            spotifyPlaying: players[.spotify]?.isPlaying ?? false,
            musicRunning: players[.appleMusic]?.isRunning ?? false,
            musicPlaying: players[.appleMusic]?.isPlaying ?? false,
            preferred: preferredMediaPlayer
        )
    }

    public var isActiveMediaPlaying: Bool {
        activeMediaPlayer.flatMap { players[$0]?.isPlaying } ?? false
    }

    func mediaIcon(for player: MediaPlayer) -> NSImage? {
        if let cached = icons[player.bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[player.bundleID] = image
        return image
    }

    public func sendMediaCommand(_ command: SpotifyRemote.Command, to explicitPlayer: MediaPlayer? = nil) {
        guard let player = explicitPlayer ?? activeMediaPlayer else { return }
        preferredMediaPlayer = player
        if command == .playPause { players[player]?.isPlaying.toggle() }
        player.send(command)
    }

    private func observeMediaPlayers() {
        for player in MediaPlayer.allCases { players[player]?.isRunning = player.isRunning }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier,
                      let player = MediaPlayer(rawValue: bundleID) else { return }
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    self?.players[player] = PlayerState(isRunning: launched)
                }
            }
            observers.append((workspace, token))
        }

        let distributed = DistributedNotificationCenter.default()
        for player in MediaPlayer.allCases {
            let token = distributed.addObserver(
                forName: player.stateNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let playing = SpotifyRemote.isPlaying(in: note) else { return }
                MainActor.assumeIsolated {
                    self?.players[player]?.hasAnnounced = true
                    self?.players[player]?.isPlaying = playing
                    if playing {
                        self?.preferredMediaPlayer = player
                    }
                }
            }
            observers.append((distributed, token))
        }
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

    public func setOutputDevice(_ uid: String?, for id: String) {
        var setting = setting(for: id)
        let defaultUID = devices.first(where: \.isDefault)?.id
        setting.outputDeviceUID = (uid == nil || uid == defaultUID) ? nil : uid
        update(setting, for: id)
    }

    public func routedDeviceName(for id: String) -> String? {
        guard let uid = setting(for: id).outputDeviceUID else { return nil }
        return devices.first(where: { $0.id == uid })?.name ?? uid
    }

    private func update(_ setting: AppSetting, for id: String) {
        guard setting != self.setting(for: id) else { return }
        settings[id] = setting.isDefault ? nil : setting
        engine?.setSetting(setting, for: id)
        scheduleSave()
    }

    // MARK: Master volume & device switcher

    public func selectOutputDevice(uid: String) {
        engine?.selectOutputDevice(uid: uid)
        if let target = devices.first(where: { $0.id == uid }) {
            devices = devices.map { OutputDeviceInfo(id: $0.id, name: $0.name, isDefault: $0.id == uid) }
            if let output {
                self.output = OutputState(
                    name: target.name,
                    volume: output.volume,
                    isMuted: output.isMuted,
                    hasVolumeControl: output.hasVolumeControl
                )
            }
        }
    }

    public func toggleLaunchAtLogin() {
        launchAtLogin = LoginItem.setEnabled(!launchAtLogin)
    }

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
        launchAtLogin = LoginItem.isEnabled
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
        if app.id == SystemSounds.id {
            if let cached = icons[SystemSounds.id] { return cached }
            let image = Self.makeSystemSoundsIcon()
            icons[SystemSounds.id] = image
            return image
        }
        let key = app.bundlePath ?? ""
        if let cached = icons[key] { return cached }
        let image = app.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        icons[key] = image
        return image
    }

    private static func makeSystemSoundsIcon() -> NSImage {
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size, flipped: false) { rect in
            let body = rect.insetBy(dx: 2.5, dy: 2.5)
            let path = NSBezierPath(roundedRect: body, xRadius: 5.2, yRadius: 5.2)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.shadowBlurRadius = 1.5
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.set()
            NSColor.black.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.98, green: 0.34, blue: 0.32, alpha: 1),
                NSColor(calibratedRed: 0.82, green: 0.14, blue: 0.20, alpha: 1),
            ])
            gradient?.draw(in: body, angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            if let symbol = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: SystemSounds.name) {
                let config = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
                if let configured = symbol.withSymbolConfiguration(config) {
                    let symSize = configured.size
                    let symRect = NSRect(
                        x: rect.midX - symSize.width / 2,
                        y: rect.midY - symSize.height / 2,
                        width: symSize.width,
                        height: symSize.height
                    )
                    configured.draw(in: symRect)
                }
            }
            return true
        }
        image.isTemplate = false
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
