import Foundation

/// What the user chose for one app. Persisted by bundle identifier.
public struct AppSetting: Equatable, Codable, Sendable {
    /// Slider position, 0...1. Not the linear gain; see `VolumeTaper`.
    public var volume: Double
    public var isMuted: Bool

    public init(volume: Double = 1, isMuted: Bool = false) {
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
    }

    public static let `default` = AppSetting()

    /// An app left at full volume is never tapped: its audio stays
    /// bit-perfect and costs nothing.
    public var isDefault: Bool { !isMuted && volume >= 0.999 }

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

    public init(id: String, name: String, bundlePath: String?, isPlaying: Bool, detail: String? = nil) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.isPlaying = isPlaying
        self.detail = detail
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
    /// True when per-app control is off because System Audio Recording
    /// permission is missing. Apps play at their normal volume meanwhile.
    public var needsPermission: Bool

    public init(apps: [MixerApp] = [], output: OutputState? = nil, needsPermission: Bool = false) {
        self.apps = apps
        self.output = output
        self.needsPermission = needsPermission
    }
}
