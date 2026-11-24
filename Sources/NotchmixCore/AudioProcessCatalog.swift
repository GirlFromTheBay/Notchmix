import CoreAudio
import Darwin
import Foundation

/// One HAL process object: a process that has opened an audio client.
public struct AudioProcess: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    /// Read once per scan, so nothing downstream repeats the syscall.
    public let executablePath: String?
    public let isRunningOutput: Bool

    public init(
        objectID: AudioObjectID, pid: pid_t, bundleID: String? = nil,
        executablePath: String? = nil, isRunningOutput: Bool
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.isRunningOutput = isRunningOutput
    }
}

/// Every audio process that belongs to one app.
public struct AudioAppGroup: Equatable, Sendable {
    public let identity: AppIdentity
    /// Sorted, so two scans of the same processes compare equal.
    public let processObjects: [AudioObjectID]
    /// True while at least one process is sending audio to an output device.
    public let isPlaying: Bool
}

/// Reads `kAudioHardwarePropertyProcessObjectList` and groups it by app.
public final class AudioProcessCatalog {
    private let resolver: AppIdentityResolver
    private let ownPID = getpid()

    public init(resolver: AppIdentityResolver = AppIdentityResolver()) {
        self.resolver = resolver
    }

    /// The raw process objects, excluding this app itself.
    public func processes() -> [AudioProcess] {
        AudioObjectID.system
            .readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
            .compactMap { objectID in
                guard let pid: pid_t = objectID.read(kAudioProcessPropertyPID),
                      pid > 0, pid != ownPID else { return nil }
                let bundleID = objectID.readString(kAudioProcessPropertyBundleID)
                let running: UInt32 = objectID.read(kAudioProcessPropertyIsRunningOutput) ?? 0
                return AudioProcess(
                    objectID: objectID, pid: pid, bundleID: bundleID,
                    executablePath: ProcessInspector.executablePath(of: pid), isRunningOutput: running != 0
                )
            }
    }

    /// Groups processes by owning app. Idle processes stay in their group so a
    /// tap covers a helper before it starts playing.
    public func groups(from processes: [AudioProcess]) -> [AudioAppGroup] {
        var order: [String] = []
        var identities: [String: AppIdentity] = [:]
        var objects: [String: [AudioObjectID]] = [:]
        var playing: Set<String> = []

        for process in processes {
            if SystemSounds.isSystemSoundProcess(bundleID: process.bundleID, executablePath: process.executablePath) {
                continue
            }
            guard let identity = resolver.resolve(pid: process.pid, executablePath: process.executablePath) else { continue }
            if identities[identity.id] == nil {
                identities[identity.id] = identity
                order.append(identity.id)
            }
            objects[identity.id, default: []].append(process.objectID)
            if process.isRunningOutput { playing.insert(identity.id) }
        }
        resolver.retainOnly(pids: Set(processes.map(\.pid)))

        return order.compactMap { id in
            guard let identity = identities[id] else { return nil }
            return AudioAppGroup(
                identity: identity,
                processObjects: (objects[id] ?? []).sorted(),
                isPlaying: playing.contains(id)
            )
        }
    }

    public func systemSoundObjects(from processes: [AudioProcess], includeAlertDaemon: Bool) -> [AudioObjectID] {
        processes.compactMap { process in
            let execPath = process.executablePath
            let isNotification = SystemSounds.isNotificationProcess(bundleID: process.bundleID, executablePath: execPath)
            let isAlert = includeAlertDaemon && SystemSounds.isAlertDaemon(bundleID: process.bundleID, executablePath: execPath)
            return (isNotification || isAlert) ? process.objectID : nil
        }.sorted()
    }
}
