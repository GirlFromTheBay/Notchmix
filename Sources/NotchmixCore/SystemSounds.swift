import AudioToolbox
import Foundation

/// Identification and alert-volume control for macOS notification and alert sounds.
///
/// macOS plays standard alert beeps through `systemsoundserverd` (scaled by
/// AudioServices's `'ssvl'` property) and notification sounds through
/// `NotificationCenter`, `UserNotificationCenter`, and `usernoted` (which may
/// play custom `NSSound` files that ignore alert volume). Controlling both lets
/// Notchmix mute or lower notification audio while leaving visual banners intact.
public enum SystemSounds {
    public static let id = "com.apple.system-sounds"
    public static let name = "System Sounds"
    public static let detail = "notifications"
    public static let identity = AppIdentity(id: id, name: name, bundlePath: nil)

    /// AudioServices property ID `'ssvl'` (System Sound Volume), the underlying
    /// scalar backing System Settings → Sound → Alert volume.
    private static let alertVolumeProperty = AudioServicesPropertyID(0x7373_766C)

    private static let alertBundleIDs: Set<String> = [
        "com.apple.systemsoundserverd",
        "com.apple.systemsound",
    ]

    private static let notificationBundleIDs: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.notificationcenter",
        "com.apple.usernotificationcenter",
        "com.apple.usernoted",
        "com.apple.usernotifications",
    ]

    public static func isAlertDaemon(bundleID: String?, executablePath: String?) -> Bool {
        if let bundleID = bundleID?.lowercased(), alertBundleIDs.contains(bundleID) {
            return true
        }
        if let executablePath {
            return executablePath.hasSuffix("/systemsoundserverd")
                || executablePath.hasSuffix("/systemsoundserv")
        }
        return false
    }

    public static func isNotificationProcess(bundleID: String?, executablePath: String?) -> Bool {
        if let bundleID = bundleID?.lowercased(), notificationBundleIDs.contains(bundleID) {
            return true
        }
        if let executablePath {
            return executablePath.contains("/NotificationCenter.app/")
                || executablePath.contains("/UserNotificationCenter.app/")
                || executablePath.hasSuffix("/usernoted")
        }
        return false
    }

    public static func isSystemSoundProcess(bundleID: String?, executablePath: String?) -> Bool {
        isAlertDaemon(bundleID: bundleID, executablePath: executablePath)
            || isNotificationProcess(bundleID: bundleID, executablePath: executablePath)
    }

    /// Maps a 0...1 slider position to the raw `'ssvl'` float scalar using
    /// the same exponential curve as `StandardAdditions.osax`.
    public static func rawAlertVolume(forPosition position: Double) -> Float {
        guard position.isFinite else { return 1 }
        let clamped = min(max(position, 0), 1)
        if clamped <= 0 { return 0 }
        if clamped >= 0.999 { return 1 }
        return Float(exp(clamped - 1.0))
    }

    /// Inverse of `rawAlertVolume(forPosition:)`.
    public static func position(forRawAlertVolume raw: Float) -> Double {
        guard raw.isFinite, raw > 0 else { return 0 }
        return min(max(Double(log(raw) + 1.0), 0), 1)
    }

    public static func readRawAlertVolume() -> Float? {
        var size = UInt32(MemoryLayout<Float32>.size)
        var value: Float32 = 1
        let status = AudioServicesGetProperty(alertVolumeProperty, 0, nil, &size, &value)
        guard status == kAudioServicesNoError else { return nil }
        return value
    }

    @discardableResult
    public static func writeRawAlertVolume(_ raw: Float) -> Bool {
        guard raw.isFinite else { return false }
        var value = Float32(min(max(raw, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioServicesSetProperty(alertVolumeProperty, 0, nil, size, &value) == kAudioServicesNoError
    }
}
