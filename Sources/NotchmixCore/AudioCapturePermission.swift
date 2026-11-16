import Darwin
import Foundation

/// The state of the "System Audio Recording Only" privacy permission that
/// process taps require (`NSAudioCaptureUsageDescription`).
///
/// There is no public API to query it. A tap created without permission
/// succeeds, mutes the app, and then delivers silence, so knowing up front
/// matters. This asks TCC directly through the same private entry points the
/// system uses. They are resolved at runtime; if they ever disappear the
/// status is `.unknown` and the engine falls back to watching for silent taps.
public enum AudioCapturePermission {
    public enum Status: Equatable, Sendable {
        case granted
        case denied
        /// Never asked: the first tap (or `request`) shows the system prompt.
        case undetermined
        /// TCC could not be queried.
        case unknown
    }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: PreflightFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestAccess: RequestFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    public static var status: Status {
        guard let preflight else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt if the permission was never decided, then
    /// reports the outcome. Returns `false` when TCC cannot be asked, in
    /// which case creating a tap is what triggers the prompt.
    @discardableResult
    public static func request(completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let requestAccess else { return false }
        requestAccess(service, nil) { granted in completion(granted) }
        return true
    }
}
