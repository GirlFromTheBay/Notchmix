import AppKit
import CoreAudio
import Foundation
import os

/// Owns every Core Audio object the app creates.
///
/// All state lives on one serial queue, which is the only place HAL calls are
/// made: they can block on `coreaudiod`, so they must stay off the main
/// thread, and a single writer keeps tap and aggregate lifetimes simple.
/// The only state shared with the audio thread is each session's atomics.
///
/// The invariant throughout: any failure ends with taps torn down, which
/// restores the app's normal audio. Control is lost, sound never is.
public final class AudioEngine: @unchecked Sendable {
    /// How long a row stays after its app goes quiet, so a short pause
    /// does not make it vanish.
    static let lingerSeconds: TimeInterval = 4
    /// How long a tap outlives a return to full volume, so dragging through
    /// 100% does not create and destroy taps.
    static let releaseSeconds: TimeInterval = 1.5

    private let queue = DispatchQueue(label: "Notchmix.AudioEngine", qos: .userInitiated)
    private let log = Logger(subsystem: "Notchmix", category: "engine")
    private let catalog = AudioProcessCatalog()
    private let onSnapshot: @Sendable (MixerSnapshot) -> Void

    // Everything below is confined to `queue`.
    private var settings: [String: AppSetting]
    private var latestProcesses: [AudioProcess] = []
    private var groups: [AudioAppGroup] = []
    private var sessions: [String: TapSession] = [:]
    private var output: OutputDevice?
    private var savedAlertVolume: Float?

    private var lastPlaying: [String: Date] = [:]
    private var lastNonDefault: [String: Date] = [:]
    private var shownIDs: Set<String> = []
    private var isPanelVisible = false
    private var lastSnapshot: MixerSnapshot?

    private var needsRestart: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private var failureCount: [String: Int] = [:]
    private var heartbeat: [String: UInt64] = [:]

    private var isPermissionBlocked = false
    private var permissionCache: (mayTap: Bool, at: Date)?
    private var isPermissionRequestInFlight = false
    private var hasHeardAudio = false

    // Which sites are playing in each browser. Asking the browser can block,
    // so it happens on its own queue and the answer comes back here.
    private let siteQueue = DispatchQueue(label: "Notchmix.BrowserSites", qos: .utility)
    private var siteLabels: [String: String] = [:]
    private var siteQueriesInFlight: Set<String> = []
    private var nextSiteQuery: [String: Date] = [:]

    private var systemListeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []
    private var processListeners: [AudioObjectID: PropertyListener] = [:]
    private var timer: DispatchSourceTimer?
    private var isRefreshScheduled = false
    private var wakeObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - settings: Saved per-app settings, keyed by `AppIdentity.id`.
    ///   - onSnapshot: Called on the engine's queue whenever the visible
    ///     state changes.
    public init(settings: [String: AppSetting], onSnapshot: @escaping @Sendable (MixerSnapshot) -> Void) {
        self.settings = settings
        self.onSnapshot = onSnapshot
    }

    // MARK: Public API (any thread)

    public func start() {
        queue.async { [self] in
            installSystemListeners()
            applySystemSoundsAlertVolume()
            outputDidChange()
            startTimer()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Devices re-enumerate after wake; give the HAL a moment, then
            // rebuild every session rather than trust a stale one.
            self?.queue.asyncAfter(deadline: .now() + 1) { self?.restartAllSessions() }
        }
    }

    /// Releases every tap synchronously so apps are audible again before the
    /// process exits.
    public func shutdown() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        queue.sync {
            timer?.cancel()
            timer = nil
            stopAllSessions()
            if let savedAlertVolume {
                SystemSounds.writeRawAlertVolume(savedAlertVolume)
                self.savedAlertVolume = nil
            }
            processListeners.removeAll()
            deviceListeners.removeAll()
            systemListeners.removeAll()
        }
    }

    public func setSetting(_ setting: AppSetting, for id: String) {
        queue.async { [self] in
            settings[id] = setting
            if id == SystemSounds.id {
                applySystemSoundsAlertVolume()
            }
            // A direct adjustment is the user asking again; drop any backoff.
            retryAfter[id] = nil
            failureCount[id] = nil

            if !setting.isDefault {
                lastNonDefault[id] = Date()
                // Fast path for slider drags: only the gain moved.
                if let session = sessions[id], !needsRestart.contains(id) {
                    if id != SystemSounds.id || session.processObjects == catalog.systemSoundObjects(
                        from: latestProcesses,
                        includeAlertDaemon: setting.isMuted || setting.volume <= 0
                    ) {
                        session.gain = setting.gain
                        return
                    }
                }
            } else if let session = sessions[id] {
                session.gain = 1
                queue.asyncAfter(deadline: .now() + Self.releaseSeconds + 0.05) { [self] in
                    reconcile()
                }
                return
            }
            reconcile()
            publish()
        }
    }

    private func applySystemSoundsAlertVolume() {
        let setting = settings[SystemSounds.id] ?? .default
        if !setting.isDefault {
            if savedAlertVolume == nil {
                let current = SystemSounds.readRawAlertVolume() ?? 1
                savedAlertVolume = current > 0 ? current : 1
            }
            let target: Float = setting.isMuted ? 0 : SystemSounds.rawAlertVolume(forPosition: setting.volume)
            SystemSounds.writeRawAlertVolume(target)
        } else if savedAlertVolume != nil {
            SystemSounds.writeRawAlertVolume(1)
            savedAlertVolume = nil
        }
    }

    public func setMasterVolume(_ volume: Float) {
        queue.async { [self] in output?.setVolume(volume) }
    }

    public func setMasterMuted(_ muted: Bool) {
        queue.async { [self] in output?.setMuted(muted) }
    }

    /// While the panel is open the list refreshes faster and rows are never
    /// removed from under the pointer.
    public func setPanelVisible(_ visible: Bool) {
        queue.async { [self] in
            isPanelVisible = visible
            // Opening the panel is when a grant made in System Settings
            // should take effect.
            permissionCache = nil
            startTimer()
            refresh()
        }
    }

    /// Tries again after the user was told permission is missing.
    public func retryPermission() {
        queue.async { [self] in
            isPermissionBlocked = false
            permissionCache = nil
            retryAfter.removeAll()
            failureCount.removeAll()
            reconcile()
            publish()
        }
    }

    // MARK: Listeners and timing

    private func installSystemListeners() {
        let system = AudioObjectID.system
        systemListeners = [
            PropertyListener(object: system, selector: kAudioHardwarePropertyProcessObjectList, queue: queue) { [weak self] in
                self?.scheduleRefresh()
            },
            PropertyListener(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak self] in
                self?.outputDidChange()
            },
            PropertyListener(object: system, selector: kAudioHardwarePropertyServiceRestarted, queue: queue) { [weak self] in
                self?.audioServiceDidRestart()
            },
        ].compactMap { $0 }
    }

    private func installDeviceListeners() {
        deviceListeners.removeAll()
        guard let output else { return }
        var listeners: [PropertyListener?] = OutputDevice.volumeSelectors.map { selector, scope in
            PropertyListener(object: output.id, selector: selector, scope: scope, queue: queue) { [weak self] in
                self?.publish()
            }
        }
        // A sample rate change (Bluetooth switching between music and call
        // profiles, or Audio MIDI Setup) invalidates a running aggregate.
        // Changes arrive in bursts, so settle first.
        listeners.append(
            PropertyListener(object: output.id, selector: kAudioDevicePropertyNominalSampleRate, queue: queue) { [weak self] in
                self?.queue.asyncAfter(deadline: .now() + 0.3) { self?.restartAllSessions() }
            }
        )
        deviceListeners = listeners.compactMap { $0 }
    }

    private func updateProcessListeners(for processes: [AudioProcess]) {
        let current = Set(processes.map(\.objectID))
        processListeners = processListeners.filter { current.contains($0.key) }
        for objectID in current where processListeners[objectID] == nil {
            processListeners[objectID] = PropertyListener(
                object: objectID, selector: kAudioProcessPropertyIsRunningOutput, queue: queue
            ) { [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    /// HAL listeners are the primary signal; the timer is a safety net for
    /// missed notifications and drives row expiry and the session watchdog.
    private func startTimer() {
        timer?.cancel()
        let interval: TimeInterval = isPanelVisible ? 1 : 3
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.checkSessionHealth()
            self?.refresh()
        }
        timer.resume()
        self.timer = timer
    }

    /// Coalesces bursts of HAL notifications into one scan.
    private func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            isRefreshScheduled = false
            refresh()
        }
    }

    // MARK: Device changes

    private func outputDidChange() {
        let newOutput = OutputDevice.current()
        if newOutput != output {
            output = newOutput
            installDeviceListeners()
            // A different device is a clean slate for failures.
            retryAfter.removeAll()
            failureCount.removeAll()
        }
        // Sessions built on the old device are replaced by `reconcile`.
        refresh()
    }

    private func audioServiceDidRestart() {
        log.notice("coreaudiod restarted; rebuilding")
        // Every object ID is now invalid; destroying them is a harmless error.
        stopAllSessions()
        processListeners.removeAll()
        output = nil
        installSystemListeners()
        outputDidChange()
    }

    private func restartAllSessions() {
        needsRestart = Set(sessions.keys)
        retryAfter.removeAll()
        failureCount.removeAll()
        refresh()
    }

    // MARK: Scan, reconcile, publish

    private func refresh() {
        let processes = catalog.processes()
        latestProcesses = processes
        updateProcessListeners(for: processes)
        groups = catalog.groups(from: processes)
        reconcile()
        updateSiteLabels()
        publish()
    }

    /// Keeps the "which sites" label of a playing browser fresh while the
    /// panel is open. Nothing is asked of the browser otherwise.
    private func updateSiteLabels() {
        let now = Date()
        for group in groups where BrowserSites.safariBundleIDs.contains(group.identity.id) {
            let id = group.identity.id
            guard group.isPlaying else {
                siteLabels[id] = nil
                continue
            }
            guard isPanelVisible, !siteQueriesInFlight.contains(id),
                  now >= (nextSiteQuery[id] ?? .distantPast) else { continue }

            siteQueriesInFlight.insert(id)
            siteQueue.async { [weak self] in
                let result = BrowserSites.playingSites(in: id)
                self?.queue.async {
                    guard let self else { return }
                    self.siteQueriesInFlight.remove(id)
                    var delay: TimeInterval = 1.5
                    switch result {
                    case .sites(let names):
                        self.siteLabels[id] = names.isEmpty ? nil : names.joined(separator: ", ")
                    case .notPermitted:
                        // The user said no. Check back rarely in case that changes.
                        self.siteLabels[id] = nil
                        delay = 60
                    case .unavailable:
                        delay = 5
                    }
                    self.nextSiteQuery[id] = Date().addingTimeInterval(delay)
                    self.publish()
                }
            }
        }
    }

    /// Makes the set of running sessions match the settings: one session per
    /// running app whose setting is not the default, none for anything else.
    private func reconcile() {
        let now = Date()
        var effectiveGroups = groups
        let sysSetting = settings[SystemSounds.id] ?? .default
        if !sysSetting.isDefault {
            let sysObjects = catalog.systemSoundObjects(
                from: latestProcesses,
                includeAlertDaemon: sysSetting.isMuted || sysSetting.volume <= 0
            )
            if !sysObjects.isEmpty {
                let sysPlaying = latestProcesses.contains { sysObjects.contains($0.objectID) && $0.isRunningOutput }
                effectiveGroups.append(AudioAppGroup(
                    identity: SystemSounds.identity,
                    processObjects: sysObjects,
                    isPlaying: sysPlaying
                ))
            }
        }

        let wanted = effectiveGroups.filter { !(settings[$0.identity.id] ?? .default).isDefault }
        let mayTap = wanted.isEmpty ? false : checkPermission()
        if !sessions.isEmpty, output == nil || (!mayTap && isPermissionBlocked) {
            // Nothing to play through, or no right to tap: let apps play
            // normally rather than hold them muted.
            stopAllSessions()
        }

        var liveIDs: Set<String> = []
        for group in effectiveGroups {
            let id = group.identity.id
            liveIDs.insert(id)
            let setting = settings[id] ?? .default

            if setting.isDefault {
                guard let session = sessions[id] else { continue }
                let idle = now.timeIntervalSince(lastNonDefault[id] ?? .distantPast)
                if idle >= Self.releaseSeconds {
                    removeSession(id)
                } else {
                    session.gain = 1
                }
                continue
            }

            lastNonDefault[id] = now
            guard mayTap, let output else { continue }

            let objectsMatch = id == SystemSounds.id
                ? sessions[id]?.processObjects == group.processObjects
                : sessions[id]?.covers(group.processObjects) == true

            if let session = sessions[id],
               objectsMatch,
               session.outputUID == output.uid,
               !needsRestart.contains(id) {
                session.gain = setting.gain
                continue
            }
            if let retry = retryAfter[id], now < retry { continue }
            startSession(for: group, output: output, gain: setting.gain)
        }

        for id in sessions.keys where !liveIDs.contains(id) {
            removeSession(id)
        }
        lastNonDefault = lastNonDefault.filter { liveIDs.contains($0.key) }
        needsRestart.formIntersection(sessions.keys)
    }

    private func startSession(for group: AudioAppGroup, output: OutputDevice, gain: Float) {
        let id = group.identity.id
        let old = sessions[id]
        do {
            // Replacing a live session: bring the new one up silent, stop the
            // old one, then fade in. Both taps mute the app, so the handover
            // is a few milliseconds of dip instead of a burst at full volume.
            let session = try TapSession(
                processObjects: group.processObjects,
                output: output,
                gain: old == nil ? gain : 0
            )
            old?.stop()
            session.gain = gain
            sessions[id] = session
            heartbeat[id] = nil
            needsRestart.remove(id)
            // The failure count is cleared by the health check, once the
            // session is seen rendering, not merely because it started.
        } catch {
            log.error("Tap for \(group.identity.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            // The old session is on a stale device or process list. Dropping
            // it returns the app to normal playback.
            removeSession(id)
            noteFailure(id)
        }
    }

    /// Backs off so a session that cannot work is not rebuilt in a tight loop.
    private func noteFailure(_ id: String) {
        let failures = (failureCount[id] ?? 0) + 1
        failureCount[id] = failures
        let backoff: TimeInterval = failures == 1 ? 1 : (failures == 2 ? 5 : 30)
        retryAfter[id] = Date().addingTimeInterval(backoff)
    }

    private func removeSession(_ id: String) {
        sessions.removeValue(forKey: id)?.stop()
        heartbeat[id] = nil
        needsRestart.remove(id)
    }

    private func stopAllSessions() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        heartbeat.removeAll()
        needsRestart.removeAll()
    }

    /// Restarts sessions whose IOProc stopped being called, and, when TCC
    /// cannot be queried, notices taps that deliver nothing.
    private func checkSessionHealth() {
        let now = Date()
        var silentWhilePlaying = false

        for (id, session) in sessions {
            let age = now.timeIntervalSince(session.createdAt)
            let callbacks = session.callbackCount
            let isPlaying: Bool = if id == SystemSounds.id {
                latestProcesses.contains { session.processObjects.contains($0.objectID) && $0.isRunningOutput }
            } else {
                groups.first(where: { $0.identity.id == id })?.isPlaying == true
            }

            if age > 2 {
                if heartbeat[id] == callbacks, callbacks > 0 || isPlaying {
                    // Not rendering, so the app is muted with nothing playing
                    // in its place. Release it now and rebuild after a pause.
                    log.notice("Session \(id, privacy: .public) stalled; releasing")
                    removeSession(id)
                    noteFailure(id)
                    continue
                }
                if heartbeat[id] != nil { failureCount[id] = nil }
            }
            heartbeat[id] = callbacks

            if session.audibleFrames > 0 {
                hasHeardAudio = true
            } else if age > 3, isPlaying {
                silentWhilePlaying = true
            }
        }

        // A tap without permission is created fine, mutes the app, and yields
        // silence. Once any tap has carried audio this launch, permission is
        // evidently there and a silent tap is just a quiet app.
        if silentWhilePlaying, !hasHeardAudio, AudioCapturePermission.status == .unknown {
            log.error("Taps are silent while apps play; assuming permission is missing")
            isPermissionBlocked = true
            permissionCache = nil
            stopAllSessions()
        }
    }

    /// Whether taps may be created right now. Asks for permission the first
    /// time it is needed, which is the user's first adjustment.
    private func checkPermission() -> Bool {
        // Reconcile can run on every slider movement; asking TCC that often
        // is wasteful, and a granted answer does not go stale quickly.
        let now = Date()
        if let cached = permissionCache, now.timeIntervalSince(cached.at) < 0.5 {
            return cached.mayTap
        }
        let mayTap = queryPermission()
        permissionCache = (mayTap, now)
        return mayTap
    }

    private func queryPermission() -> Bool {
        switch AudioCapturePermission.status {
        case .granted:
            isPermissionBlocked = false
            return true
        case .denied:
            isPermissionBlocked = true
            return false
        case .undetermined:
            guard !isPermissionRequestInFlight else { return false }
            let asked = AudioCapturePermission.request { [weak self] granted in
                self?.queue.async {
                    guard let self else { return }
                    self.isPermissionRequestInFlight = false
                    self.permissionCache = nil
                    self.isPermissionBlocked = !granted
                    self.reconcile()
                    self.publish()
                }
            }
            isPermissionRequestInFlight = asked
            // If TCC cannot be asked, creating the tap shows the prompt.
            return !asked
        case .unknown:
            return !isPermissionBlocked
        }
    }

    private func publish() {
        let now = Date()
        var apps: [MixerApp] = []
        for group in groups {
            let id = group.identity.id
            if group.isPlaying { lastPlaying[id] = now }
            let recentlyPlayed = lastPlaying[id].map { now.timeIntervalSince($0) < Self.lingerSeconds } ?? false
            let pinned = isPanelVisible && shownIDs.contains(id)
            let hasCustomSetting = !(settings[id] ?? .default).isDefault
            guard group.isPlaying || recentlyPlayed || pinned || hasCustomSetting else { continue }
            apps.append(MixerApp(
                id: id,
                name: group.identity.name,
                bundlePath: group.identity.bundlePath,
                isPlaying: group.isPlaying,
                detail: siteLabels[id]
            ))
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        shownIDs = Set(apps.map(\.id))
        let liveIDs = Set(groups.map(\.identity.id))
        lastPlaying = lastPlaying.filter { liveIDs.contains($0.key) }

        let outputState = output.map { device in
            OutputState(
                name: device.name,
                volume: device.volume ?? 1,
                isMuted: device.isMuted,
                hasVolumeControl: device.hasVolumeControl
            )
        }
        let snapshot = MixerSnapshot(apps: apps, output: outputState, needsPermission: isPermissionBlocked)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshot(snapshot)
    }
}
