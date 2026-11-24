import Foundation

/// What the user chose for one app. Persisted by bundle identifier.
public struct AppSetting: Equatable, Codable, Sendable {
    /// Slider position, 0...1. Not the linear gain; see `VolumeTaper`.
    public var volume: Double
    public var isMuted: Bool
    /// Optional custom output device UID; `nil` follows the system default output.
    public var outputDeviceUID: String?

    public init(volume: Double = 1, isMuted: Bool = false, outputDeviceUID: String? = nil) {
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
        self.outputDeviceUID = outputDeviceUID
    }

    public static let `default` = AppSetting()

    /// Slider positions at or above this count as full volume.
    public static let fullVolume = 0.999

    /// An app left at full volume on the default output is never tapped:
    /// its audio stays bit-perfect and costs nothing.
    public var isDefault: Bool { !isMuted && volume >= Self.fullVolume && outputDeviceUID == nil }

    /// Linear gain the audio thread applies.
    public var gain: Float { isMuted ? 0 : VolumeTaper.gain(forPosition: volume) }
}

/// Maps slider position to linear gain.
///
/// Loudness is roughly logarithmic in amplitude, so a linear slider would do
/// almost nothing over its top half. Squaring the position puts half-way at
/// about -12 dB, which is close to "half as loud".
public enum VolumeTaper {
    public static func gain(forPosition position: Double) -> Float {
        let clamped = min(max(position, 0), 1)
        return Float(clamped * clamped)
    }
}

/// One row in the mixer.
public struct MixerApp: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    public let isPlaying: Bool
    /// For a browser, the sites that are playing: "youtube, roll20".
    public let detail: String?
    /// Live audio level (0...1) for the peak meter inside the slider.
    public let peak: Float

    public init(
        id: String,
        name: String,
        bundlePath: String?,
        isPlaying: Bool,
        detail: String? = nil,
        peak: Float = 0
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.isPlaying = isPlaying
        self.detail = detail
        self.peak = min(max(peak.isFinite ? peak : 0, 0), 1)
    }

    /// The permanent mixer row for macOS notification and alert sounds.
    public static let systemSounds = MixerApp(
        id: SystemSounds.id,
        name: SystemSounds.name,
        bundlePath: nil,
        isPlaying: false,
        detail: SystemSounds.detail
    )
}

/// An available output device for master switching or per-app routing.
public struct OutputDeviceInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// The default output device's master volume.
public struct OutputState: Equatable, Sendable {
    public let name: String
    public let volume: Float
    public let isMuted: Bool
    /// False for outputs with no software volume, such as HDMI.
    public let hasVolumeControl: Bool

    public init(name: String, volume: Float, isMuted: Bool, hasVolumeControl: Bool) {
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
        self.hasVolumeControl = hasVolumeControl
    }
}

/// Everything the panel shows that the engine knows.
public struct MixerSnapshot: Equatable, Sendable {
    public var apps: [MixerApp]
    public var output: OutputState?
    public var devices: [OutputDeviceInfo]
    public var systemSoundsPeak: Float
    /// True when per-app control is off because System Audio Recording
    /// permission is missing. Apps play at their normal volume meanwhile.
    public var needsPermission: Bool

    public init(
        apps: [MixerApp] = [],
        output: OutputState? = nil,
        devices: [OutputDeviceInfo] = [],
        systemSoundsPeak: Float = 0,
        needsPermission: Bool = false
    ) {
        self.apps = apps
        self.output = output
        self.devices = devices
        self.systemSoundsPeak = min(max(systemSoundsPeak.isFinite ? systemSoundsPeak : 0, 0), 1)
        self.needsPermission = needsPermission
    }
}
